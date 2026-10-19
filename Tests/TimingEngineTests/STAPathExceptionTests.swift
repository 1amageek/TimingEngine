import Foundation
import STAEngine
import Testing
import TimingCore

@Suite(.timeLimit(.minutes(1)))
struct STAPathExceptionTests {
    private func execute(_ design: TimingDesign, _ sdc: String, library: String = TimingCoreTests.liberty,
                         limits: STAExecutionLimits? = nil) async throws -> STAExecutionResult {
        try await STAConnectivityTests().execute(JSONEncoder().encode(design), constraints: sdc, libraryText: library, limits: limits)
    }
    private func aliases() -> TimingDesign {
        .init(topDesignName: "top", ports: [.init(name: "a", direction: .input),
            .init(name: "y", direction: .output, net: "a"), .init(name: "z", direction: .output, net: "a")], instances: [])
    }
    private let sdc = """
    create_clock -name clk -period 10ns [get_ports a]
    set_input_delay 1ns -clock clk [get_ports a]
    set_output_delay 2ns -clock clk [get_ports y]
    set_output_delay 4ns -clock clk [get_ports z]
    """
    @Test func falseAliasIsExcludedWithoutBecomingStaticOrUnconstrained() async throws {
        let result = try await execute(aliases(), sdc + "\nset_false_path -to [get_ports y]")
        #expect(result.status == .completed)
        let y = try #require(result.payload.endpoints.first { $0.endpoint == "y" })
        #expect(y.excludedChecks == [.setup, .hold] && y.staticChecks == nil && y.staticValue == nil)
        #expect(y.setupSlack == nil && y.holdSlack == nil)
        #expect(result.payload.unconstrainedEndpoints.isEmpty)
        #expect(!result.payload.criticalPaths.contains { $0.endpoint == "y" })
        #expect(abs(try #require(result.payload.worstSetupSlack) - 5e-9) < 1e-20)
        #expect(try JSONDecoder().decode(STAPayload.self, from: JSONEncoder().encode(result.payload)) == result.payload)
    }
    @Test func setupFalsePathDoesNotHideMinDelayOrOtherAlias() async throws {
        let result = try await execute(aliases(), sdc + "\nset_false_path -setup -to [get_ports y]\nset_min_delay 5ns -to [get_ports y]")
        let y = try #require(result.payload.endpoints.first { $0.endpoint == "y" })
        #expect(y.excludedChecks == [.setup] && y.setupSlack == nil)
        #expect(abs(try #require(y.holdSlack) + 2e-9) < 1e-20)
        let path = try #require(result.payload.criticalPaths.first { $0.endpoint == "y" })
        #expect(path.analysisKind == .hold && path.slack == y.holdSlack)
        #expect(result.payload.violations.contains { $0.endpoint == "y" && $0.kind == .hold })
    }
    @Test func multicycleHoldRestorationAndPrecedenceAreOrderIndependent() async throws {
        let clauses = ["set_multicycle_path 3 -setup -to [get_ports y]",
                       "set_multicycle_path -hold 2 -to [get_ports y]",
                       "set_max_delay -to [get_ports y] 5ns"]
        for ordered in [clauses, Array(clauses.reversed())] {
            let result = try await execute(aliases(), sdc + "\n" + ordered.joined(separator: "\n"))
            #expect(result.status == .completed)
            let y = try #require(result.payload.endpoints.first { $0.endpoint == "y" })
            #expect(abs(try #require(y.setupSlack) - 2e-9) < 1e-20)
            #expect(abs(try #require(y.holdSlack) - 3e-9) < 1e-20)
        }
        let shifted = try await execute(aliases(), sdc + "\nset_multicycle_path 3 -to [get_ports y]")
        let y = try #require(shifted.payload.endpoints.first { $0.endpoint == "y" })
        #expect(abs(try #require(y.setupSlack) - 27e-9) < 1e-20)
        #expect(abs(try #require(y.holdSlack) + 17e-9) < 1e-20)
    }
    @Test func falsePathAtReconvergenceRetainsOtherLaunchAndOrderedThroughRoutes() async throws {
        var library = TimingCoreTests.liberty
        let gate = """
        cell (OR) { pin(A){direction:input;} pin(B){direction:input;}
          pin(Y){direction:output;function:"A|B";
            timing(){related_pin:"A";timing_sense:positive_unate;cell_rise(t){values("1");}cell_fall(t){values("1");}}
            timing(){related_pin:"B";timing_sense:positive_unate;cell_rise(t){values("1");}cell_fall(t){values("1");}}
          }}
        """
        library.insert(contentsOf: gate, at: try #require(library.lastIndex(of: "}")))
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "a", direction: .input), .init(name: "b", direction: .input),
            .init(name: "y", direction: .output, net: "join"), .init(name: "z", direction: .output, net: "join")],
            instances: [.init(name: "I", cell: "INV", connections: ["A":"a","Y":"branch"]),
                        .init(name: "U", cell: "OR", connections: ["A":"branch","B":"b","Y":"join"])],
            nets: [.init(name: "branch"), .init(name: "join")])
        let base = """
        create_clock -name clk -period 10ns [get_ports a]
        set_input_delay 4ns -clock clk [get_ports a]
        set_input_delay 1ns -clock clk [get_ports b]
        set_output_delay -max 2ns -clock clk [get_ports y]
        set_output_delay -max 2ns -clock clk [get_ports z]
        """
        for clause in ["set_false_path -from [get_ports a] -to [get_ports y]",
                       "set_false_path -through [get_pins I/Y] -through [get_pins U/A] -to [get_ports y]"] {
            let result = try await execute(design, base + "\n" + clause, library: library)
            #expect(result.status == .completed, "\(result.diagnostics)")
            #expect(abs(try #require(result.payload.endpoints.first { $0.endpoint == "y" }?.setupSlack) - 6e-9) < 1e-20)
            #expect(abs(try #require(result.payload.endpoints.first { $0.endpoint == "z" }?.setupSlack) - 2e-9) < 1e-20)
            #expect(result.payload.criticalPaths.first { $0.endpoint == "y" }?.startpoint == "b")
        }
        let wrongOrder = try await execute(design, base + "\nset_false_path -through [get_pins U/A] -through [get_pins I/Y] -to [get_ports y]", library: library)
        #expect(abs(try #require(wrongOrder.payload.endpoints.first { $0.endpoint == "y" }?.setupSlack) - 2e-9) < 1e-20)
    }
    @Test func ffPinChecksRetainSetupHoldAndIndependentControls() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "a", direction: .input), .init(name: "q", direction: .output)],
            instances: [.init(name: "FF", cell: "DFF", connections: ["D":"a","CLK":"a","Q":"q"])])
        let base = "create_clock -name clk -period 10ns [get_ports a]\nset_input_delay 1ns -clock clk [get_ports a]\nset_output_delay -max 2ns -clock clk [get_ports q]"
        let result = try await execute(design, base + "\nset_max_delay 5ns -to [get_pins FF/D]\nset_min_delay 0.5ns -to [get_pins FF/D]")
        let ff = try #require(result.payload.endpoints.first { $0.endpoint == "FF/D" })
        #expect(abs(try #require(ff.setupSlack) - 3.8e-9) < 1e-20)
        #expect(abs(try #require(ff.holdSlack) - 0.5e-9) < 1e-20)
        let disabled = try await execute(design, base + "\nset_false_path -to [get_pins FF/D]")
        #expect(disabled.payload.endpoints.first { $0.endpoint == "FF/D" }?.excludedChecks == [.setup, .hold])
        let pulse = try await STAConnectivityTests().execute(JSONEncoder().encode(design),
            constraints: base + "\nset_false_path -to [get_pins FF/D]", kinds: [.setup, .pulseWidth])
        #expect(pulse.status != .completed)
    }
    @Test func strictParserAndConflictingSelectorsCannotSilentlyPass() async throws {
        for command in ["set_multicycle_path -setup 0 -to [get_ports y]", "set_multicycle_path nope -to [get_ports y]",
                        "set_max_delay nan -to [get_ports y]", "set_min_delay -1ns -to [get_ports y]",
                        "set_false_path -rise_to [get_ports y]", "set_multicycle_path -start -end 2 -to [get_ports y]",
                        "set_false_path -through [get_pins -hierarchical U/*]"] {
            #expect(throws: TimingError.self) { _ = try SDCParser().parse(Data(command.utf8)) }
        }
        for command in ["set_false_path -to [get_ports absent]", "set_false_path -from [get_nets a] -to [get_ports y]",
                        "set_max_delay 3ns -to [get_ports y]\nset_max_delay 4ns -to [get_ports y]"] {
            let result = try await execute(aliases(), sdc + "\n" + command)
            #expect(result.status != .completed)
        }
        let parsed = try SDCParser().parse(Data("set_multicycle_path -hold 0 -to [get_ports y]\nset_output_delay -min -1ns -clock clk [get_ports y]".utf8))
        #expect(parsed.exceptions[0].cycles == 0 && parsed.exceptions[0].scope == .hold && parsed.outputDelays[0].rise == -1e-9)
        #expect(try JSONDecoder().decode(TimingConstraintSet.self, from: JSONEncoder().encode(parsed)) == parsed)
    }
    @Test func routeCapacityIsFailureAndNotReportTruncation() async throws {
        for limits in [try STAExecutionLimits(maximumPathStates: 1), try STAExecutionLimits(maximumPathWorkUnits: 1)] {
            do { _ = try await execute(aliases(), sdc, limits: limits); Issue.record("Path capacity unexpectedly completed") }
            catch let error as STAExecutionError {
                if case .underlying(let cause) = error { #expect(cause is STAPathAnalysisError) }
                else { Issue.record("Wrong path capacity failure") }
            }
        }
        let result = try await execute(aliases(), sdc + "\nset_false_path -to [get_ports y]")
        #expect(result.status == .completed && result.payload.endpoints.count == 2)
        let limited = try await STAConnectivityTests().execute(JSONEncoder().encode(aliases()), constraints: sdc, maximumPaths: 1)
        #expect(limited.payload.endpoints.count == 2 && limited.payload.criticalPaths.count == 1)
        let oneScenario = try await execute(aliases(), sdc, limits: try STAExecutionLimits(maximumPathWorkUnits: 35))
        #expect(oneScenario.status == .completed)
        do {
            _ = try await STAConnectivityTests().execute(JSONEncoder().encode(aliases()), constraints: sdc,
                limits: try STAExecutionLimits(maximumPathWorkUnits: 35), modes: ["first", "second"])
            Issue.record("Scenario work was reset")
        } catch let error as STAExecutionError {
            if case .underlying(let cause) = error { #expect(cause is STAPathAnalysisError) }
            else { Issue.record("Wrong cumulative capacity failure") }
        }
    }
    @Test func aClockNameCannotReplaceThePhysicalSequentialClockSource() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "a", direction: .input), .init(name: "q", direction: .output)],
            instances: [.init(name: "I", cell: "INV", connections: ["A":"a","Y":"derived"]),
                        .init(name: "FF", cell: "DFF", connections: ["D":"a","CLK":"derived","Q":"q"])], nets: [.init(name: "derived")])
        let result = try await execute(design, "create_clock -name derived -period 10ns [get_ports a]\nset_output_delay -max 2ns -clock derived [get_ports q]\nset_multicycle_path 2 -to [get_pins FF/D]")
        #expect(result.status != .completed)
    }

    @Test func multipleIOClockReferencesCannotCollapseToTheFirstRecord() async throws {
        var design = aliases(); design.ports.append(.init(name: "b", direction: .input))
        let result = try await execute(design, sdc + "\ncreate_clock -name other -period 10ns [get_ports b]\nset_input_delay -min 0ns -clock other [get_ports a]\nset_false_path -hold -from [get_clocks clk] -to [get_ports y]")
        #expect(result.status != .completed)
    }

}

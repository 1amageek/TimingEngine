import Foundation
import STAEngine
import Testing
import TimingCore

@Suite(.timeLimit(.minutes(1)))
struct STATieCellTests {
    static func library(function: String = "0", highFunction: String = "1", modifier: String = "", withFlipFlop: Bool = false) -> String {
        let tie = """
        cell(DUAL_TIE) { area:2;
            pin(LO) { direction:output; function:"\(function)"; \(modifier) }
            pin(HI) { direction:output; function:"\(highFunction)"; }
        }
        """
        if withFlipFlop { return String(TimingCoreTests.liberty.dropLast()) + tie + "}" }
        return "library(L) { time_unit:\"1ns\"; capacitive_load_unit(1,pf); " + tie + "}"
    }
    static func design(withFlipFlop: Bool = false) -> TimingDesign {
        var ports: [TimingDesign.Port] = [.init(name: "p0_0", direction: .input)]
        for bit in 0..<4 { ports.append(.init(name: "p1_\(bit)", direction: .output, net: "n\(bit % 2)")) }
        var instances: [TimingDesign.Instance] = [.init(name: "i0", cell: "DUAL_TIE", connections: ["LO": "n0", "HI": "n1"])]
        var nets: [TimingDesign.Net] = [.init(name: "p0_0"), .init(name: "n0"), .init(name: "n1")]
        if withFlipFlop {
            ports.append(.init(name: "q", direction: .output))
            nets.append(.init(name: "q"))
            instances.append(.init(name: "FF", cell: "DFF", connections: ["D": "n0", "CLK": "p0_0", "Q": "q"]))
        }
        return .init(topDesignName: "top", ports: ports, instances: instances, nets: nets)
    }
    static func constraints(withFlipFlop: Bool = false) -> String {
        var lines = ["create_clock -name clk -period 10ns [get_ports p0_0]"]
        for bit in 0..<4 {
            lines.append("set_output_delay -max \(bit + 1)ns -clock clk [get_ports p1_\(bit)]")
            lines.append("set_output_delay -min 0ns -clock clk [get_ports p1_\(bit)]")
        }
        if withFlipFlop { lines.append("set_output_delay -max 2ns -clock clk [get_ports q]") }
        return lines.joined(separator: "\n")
    }
    static func assertLiteralAliases(_ result: STAExecutionResult) throws {
        #expect(result.status == .completed, "\(result.diagnostics)")
        for bit in 0..<4 {
            let endpoint = try #require(result.payload.endpoints.first { $0.endpoint == "p1_\(bit)" })
            #expect(endpoint.staticValue == (bit % 2 == 0 ? .zero : .one))
            #expect(endpoint.staticChecks == [.setup, .hold])
            #expect(endpoint.setupSlack == nil && endpoint.holdSlack == nil && endpoint.dataArrival == nil)
            #expect(!result.payload.criticalPaths.contains { $0.endpoint == endpoint.endpoint })
        }
        #expect(result.payload.libraryConsumption.first?.cellNames.contains("DUAL_TIE") == true)
        #expect(result.payload.libraryConsumption.first?.pinNames.contains("DUAL_TIE.LO") == true)
        #expect(result.payload.libraryConsumption.first?.pinNames.contains("DUAL_TIE.HI") == true)
    }
    @Test func dualLiteralOutputsPreservePhysicalInstanceAndAliasedStaticChecks() async throws {
        let design = Self.design()
        #expect(design.instances.count == 1 && design.nets.allSatisfy { $0.constant == nil })
        let result = try await STAConnectivityTests().execute(JSONEncoder().encode(design), constraints: Self.constraints(), libraryText: Self.library())
        try Self.assertLiteralAliases(result)
        #expect(result.payload.worstSetupSlack == nil && result.payload.worstHoldSlack == nil)
        #expect(result.payload.criticalPaths.isEmpty)
    }
    @Test func symbolFreeConstantDAGUsesSharedTruthSemantics() async throws {
        let result = try await STAConnectivityTests().execute(JSONEncoder().encode(Self.design()), constraints: Self.constraints(),
            libraryText: Self.library(function: "(1 & !1) | (0 ^ 0)", highFunction: "!0"))
        try Self.assertLiteralAliases(result)
        #expect(result.payload.criticalPaths.isEmpty)
    }
    @Test func staticFunctionSlotsAreAdmittedBeforeAllocation() async throws {
        do {
            _ = try await STAConnectivityTests().execute(JSONEncoder().encode(Self.design()), constraints: Self.constraints(),
                libraryText: Self.library(highFunction: "!0"), limits: .init(maximumPathStates: 2))
            Issue.record("Static function slots exceeded the caller workspace bound")
        } catch let failure as STAExecutionError {
            guard case .underlying(let cause) = failure,
                  let capacity = cause as? STAPathAnalysisError else { throw failure }
            #expect(capacity == .capacity(resource: "path states including static function slots", limit: 2))
        }
    }
    @Test func literalTieDataDoesNotInitializeFlipFlopQ() async throws {
        let result = try await STAConnectivityTests().execute(JSONEncoder().encode(Self.design(withFlipFlop: true)),
            constraints: Self.constraints(withFlipFlop: true), libraryText: Self.library(withFlipFlop: true))
        try Self.assertLiteralAliases(result)
        let data = try #require(result.payload.endpoints.first { $0.endpoint == "FF/D" })
        #expect(data.staticValue == .zero && data.staticChecks == [.setup, .hold])
        #expect(data.setupSlack == nil && data.holdSlack == nil)
        let q = try #require(result.payload.endpoints.first { $0.endpoint == "q" })
        #expect(q.staticValue == nil && q.staticChecks == nil)
        #expect(abs(try #require(q.setupSlack) - 7.5e-9) < 1e-20)
        #expect(result.payload.criticalPaths.contains { $0.endpoint == "q" && $0.startpoint == "FF/Q" })
    }
    @Test(arguments: ["missing", "symbol", "three-state"])
    func unusedIneligibleOutputCannotAdmitTheCell(_ scenario: String) async throws {
        var design = Self.design()
        design.ports.removeAll { $0.direction == .output && $0.netName == "n0" }
        design.instances[0].connections.removeValue(forKey: "LO")
        var library = Self.library(function: scenario == "symbol" ? "A" : "0",
            modifier: scenario == "three-state" ? "three_state:\"1\";" : "")
        if scenario == "missing" { library = library.replacingOccurrences(of: "function:\"0\";", with: "") }
        let result = try await STAConnectivityTests().execute(JSONEncoder().encode(design), constraints: """
        create_clock -name clk -period 10ns [get_ports p0_0]
        set_output_delay -max 2ns -clock clk [get_ports p1_1]
        set_output_delay -min 0ns -clock clk [get_ports p1_1]
        set_output_delay -max 2ns -clock clk [get_ports p1_3]
        set_output_delay -min 0ns -clock clk [get_ports p1_3]
        """, libraryText: library)
        #expect(result.status == .blocked)
        #expect(result.payload.endpoints.isEmpty)
    }
    @Test(arguments: ["missing", "symbol", "three-state"])
    func unadmittedFunctionsCannotBecomeStatic(_ scenario: String) async throws {
        var library = Self.library(function: scenario == "symbol" ? "A" : "0",
            modifier: scenario == "three-state" ? "three_state:\"1\";" : "")
        if scenario == "missing" { library = library.replacingOccurrences(of: "function:\"0\";", with: "") }
        let result = try await STAConnectivityTests().execute(JSONEncoder().encode(Self.design()), constraints: Self.constraints(), libraryText: library)
        #expect(result.status == .blocked)
        #expect(result.artifactBindings.isEmpty)
    }
}

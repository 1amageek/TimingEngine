import Foundation
import STAEngine
import Testing
import TimingCore

@Suite(.timeLimit(.minutes(1)))
struct STANumericalModelTests {
    static let sdc = """
    create_clock -name clk -period 10ns [get_ports clk]
    set_input_delay 1ns -clock clk [get_ports d]
    set_output_delay -max 0ns -clock clk [get_ports q]
    set_input_transition 0.2ns [all_inputs]
    """
    static var design: TimingDesign {
        .init(topDesignName: "top", ports: [.init(name: "clk", direction: .input),
            .init(name: "d", direction: .input), .init(name: "q", direction: .output)],
            instances: [.init(name: "FF", cell: "DFF", connections: ["D":"d", "CLK":"clk", "Q":"q"])])
    }
    static var completeLibrary: String {
        TimingCoreTests.liberty
    }
    static var slewLibrary: String {
        completeLibrary
            .replacingOccurrences(of: "rise_constraint (t) { index_1 (\"0.1\"); index_2 (\"0.0\"); values (\"0.2\"); }",
                with: "rise_constraint (t) { index_1 (\"0.1,0.3\"); index_2 (\"0.1,0.3\"); values (\"0.1,0.3\",\"0.5,0.7\"); }")
            .replacingOccurrences(of: "fall_constraint (t) { index_1 (\"0.1\"); index_2 (\"0.0\"); values (\"0.2\"); }",
                with: "fall_constraint (t) { values (\"0.05\"); }")
    }
    static func execute(_ library: String, design: TimingDesign = design, sdc: String = sdc,
                        kinds: [STAAnalysisKind] = [.setup, .hold], variation: STAVariation = .init()) async throws -> STAExecutionResult {
        try await STAConnectivityTests().execute(JSONEncoder().encode(design), constraints: sdc,
            kinds: kinds, libraryText: library, variation: variation)
    }
    @Test func absentHoldCannotBecomeMeasuredZero() async throws {
        let missing = try await Self.execute(Self.completeLibrary.replacingOccurrences(of: "timing_type : hold_rising;", with: "timing_type : unsupported_hold;"))
        #expect(missing.status == .blocked)
        #expect(missing.artifactBindings.isEmpty)
        let explicit = try await Self.execute(Self.completeLibrary)
        #expect(explicit.status == .completed)
        #expect(abs(try #require(explicit.payload.endpoints.first { $0.endpoint == "FF/D" }?.holdSlack) - 1e-9) < 1e-20)
    }
    @Test func conditionalArcCannotBecomeUnconditional() async throws {
        let source = Self.completeLibrary.replacingOccurrences(of: "timing_sense : negative_unate;", with: "timing_sense : negative_unate; when : \"A\";")
        let result = try await Self.execute(source)
        #expect(result.status == .blocked)
    }
    @Test func sequentialChecksConsumeBothSlewAxesAndTransition() async throws {
        let source = Self.slewLibrary
        let result = try await Self.execute(source)
        #expect(result.status == .completed)
        #expect(abs(try #require(result.payload.endpoints.first { $0.endpoint == "FF/D" }?.setupSlack) - 8.6e-9) < 1e-20)
    }
    @Test func ownedConditionalRefusalRetainsMeaningAndPhysicalLine() throws {
        let source = Self.completeLibrary.replacingOccurrences(of: "timing_sense : negative_unate;",
            with: "timing_sense : negative_unate; when : \"A\";")
        let line = try #require(source.split(separator: "\n", omittingEmptySubsequences: false).firstIndex { $0.contains("when :") }) + 1
        let bytes = Array(source.utf8)
        do {
            _ = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 64), resources: STALibertyResources())
            Issue.record("Conditional source was admitted")
        } catch LibertySourceError.unsupportedSemantics(let semantic) {
            #expect(semantic == "conditional timing arc: when at line " + String(line))
        }
    }
    @Test func scalarAndDeclaredOneDimensionalChecksRemainSupportedAndThreeDimensionsRefuse() async throws {
        var design = Self.design
        design.instances[0].connections["D"] = "n"
        design.nets.append(.init(name: "n"))
        design.instances.append(.init(name: "U", cell: "INV", connections: ["A":"d","Y":"n"]))
        for variable in ["constrained_pin_transition", "related_pin_transition"] {
            let template = "lu_table_template(C) { variable_1:" + variable + "; index_1(\"0.1,0.3\"); }"
            let source = Self.completeLibrary.replacingOccurrences(of: "library (test) {", with: "library (test) {" + template)
                .replacingOccurrences(of: "rise_constraint (t) { index_1 (\"0.1\"); index_2 (\"0.0\"); values (\"0.2\"); }",
                    with: "rise_constraint(C) { values(\"0.1,0.5\"); }")
                .replacingOccurrences(of: "fall_constraint (t) { index_1 (\"0.1\"); index_2 (\"0.0\"); values (\"0.2\"); }",
                    with: "fall_constraint(C) { values(\"0.1,0.5\"); }")
            let result = try await Self.execute(source, design: design)
            #expect(result.status == .completed, "\(result.diagnostics)")
            let expected = variable == "constrained_pin_transition" ? 7.9e-9 : 7.7e-9
            #expect(abs(try #require(result.payload.endpoints.first { $0.endpoint == "FF/D" }?.setupSlack) - expected) < 1e-20)
        }
        let third = Self.completeLibrary.replacingOccurrences(of: "library (test) {",
            with: "library (test) { lu_table_template(C) { variable_1:constrained_pin_transition; variable_2:related_pin_transition; variable_3:constrained_pin_transition; index_3(\"0.1\"); }")
            .replacingOccurrences(of: "rise_constraint (t)", with: "rise_constraint(C)")
        let refused = try await Self.execute(third)
        #expect(refused.status == .blocked)
    }
    @Test func wireDeratesDoNotScaleCellDelay() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [.init(name:"clk", direction:.input),
            .init(name:"d", direction:.input), .init(name:"q", direction:.output)],
            instances:[.init(name:"U", cell:"INV", connections:["A":"d","Y":"q"])])
        let result = try await Self.execute(Self.completeLibrary, design: design,
            variation: .init(lateCellDelayScale: 2, earlyCellDelayScale: 0.5,
                lateInterconnectDelayScale: 3, earlyInterconnectDelayScale: 4))
        #expect(result.status == .completed)
        #expect(abs(try #require(result.payload.worstSetupSlack) - 7e-9) < 1e-20)
    }
    @Test func recoveryAndRemovalUseActualControlArrivalAndClockEdge() async throws {
        var design = Self.design
        design.ports.append(.init(name:"rn", direction:.input))
        design.instances[0].connections["RN"] = "rn"
        let checks = """
        pin (RN) { direction: input;
          timing () { related_pin:"CLK"; timing_type:recovery_falling;
            rise_constraint (t) { values ("0.2"); } }
          timing () { related_pin:"CLK"; timing_type:removal_falling;
            rise_constraint (t) { values ("0.3"); } }
        }
        """
        let source = Self.completeLibrary.replacingOccurrences(of: "pin (CLK) {", with: checks + "\npin (CLK) {")
        let result = try await Self.execute(source, design: design,
            sdc: Self.sdc + "\nset_input_delay -max 9ns -clock clk [get_ports rn]\nset_input_delay -min 5.1ns -clock clk [get_ports rn]",
            kinds: [.setup,.hold,.recovery,.removal])
        #expect(result.status == .completed)
        let endpoint = try #require(result.payload.endpoints.first { $0.endpoint == "FF/D" })
        #expect(abs(try #require(endpoint.recoverySlack) - 5.8e-9) < 1e-20)
        #expect(abs(try #require(endpoint.removalSlack) + 0.2e-9) < 1e-20)
        #expect(result.payload.violations.contains { $0.kind == .removal })
        let missing = try await Self.execute(source, design: design, kinds: [.recovery])
        #expect(missing.status == .blocked)
    }
}

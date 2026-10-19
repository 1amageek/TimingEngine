import Foundation
import Testing
import TimingCore
import TimingEngine
@testable import STAEngine

@Suite(.timeLimit(.minutes(1)))
struct ScalarReferenceSequentialTests {
    private func owned(_ text: String) throws -> OwnedLibertySource {
        let bytes = Array(text.utf8)
        return try LibertyParser().parseSource(bytes.span,
            limits: .init(maximumNestingDepth: 64), resources: STALibertyResources())
    }

    @Test func simpleSourceFlipFlopPreservesIndependentScalarNumbers() throws {
        let source = try owned(TimingCoreTests.liberty)
        let design = TimingDesign(topDesignName: "top", ports: [
            .init(name: "d", direction: .input), .init(name: "clk", direction: .input),
            .init(name: "q", direction: .output)], instances: [
                .init(name: "FF", cell: "DFF", connections: ["D": "d", "CLK": "clk", "Q": "q"])])
        let constraints = try SDCParser().parse(Data("""
        create_clock -name clk -period 10ns [get_ports clk]
        set_input_delay 1ns -clock clk [get_ports d]
        set_output_delay 2ns -clock clk [get_ports q]
        """.utf8))
        let ordinary = try LibertyParser().parse(Data(TimingCoreTests.liberty.utf8))
        for library in [source.library, ordinary] {
            let model = try #require(try library.cell(named: "DFF").sequentialModel)
            guard case .source = model.definition else {
                Issue.record("Real Liberty source must retain its source-defined state kind")
                continue
            }
            let result = try TimingReferenceAnalyzer().analyze(design: design,
                library: library, constraints: constraints)
            #expect(abs(try #require(result.worstSetupSlack) - 7.5e-9) < 1e-20)
        }
    }

    @Test(arguments: [
        "ff(IQ,IQN){next_state:\"D EN + IQ EN'\";clocked_on:\"CLK\";}",
        "ff(IQ,IQN){next_state:\"D\";clocked_on:\"CLK\";clear:\"!RN\";}",
        "latch(IQ,IQN){data_in:\"D\";enable:\"GATE\";}"
    ])
    func complexSourceStateCannotFallThroughToScalarCombinationalEvaluation(_ declaration: String) throws {
        let text = """
        library(L){cell(S){\(declaration)
          pin(D){direction:input;} pin(EN){direction:input;}
          pin(CLK){direction:input;} pin(RN){direction:input;}
          pin(GATE){direction:input;} pin(Q){direction:output;function:"IQ";}
        }}
        """
        let source = try owned(text)
        let original = source.library
        let decoded = try JSONDecoder().decode(TimingLibrary.self,
            from: JSONEncoder().encode(original))
        let ordinary = try LibertyParser().parse(Data(text.utf8))
        let decodedOrdinary = try JSONDecoder().decode(TimingLibrary.self,
            from: JSONEncoder().encode(ordinary))
        for library in [original, decoded, ordinary, decodedOrdinary] {
            let model = try #require(try library.cell(named: "S").sequentialModel)
            guard case .source = model.definition else {
                Issue.record("Ordinary and owned Liberty paths must preserve the source state kind")
                continue
            }
            #expect(model.simpleEdgeTriggeredPins == nil)
            let design = TimingDesign(topDesignName: "top", ports: [], instances: [
                .init(name: "state", cell: "S", connections: [:])])
            do {
                _ = try TimingReferenceAnalyzer().analyze(design: design, library: library,
                    constraints: .init(modeID: "functional"))
                Issue.record("A complex source-defined state cell must be refused by the scalar profile")
            } catch let error as TimingError {
                guard case .unsupportedSemantic(let format, let semantic) = error else { throw error }
                #expect(format == "Reference STA")
                #expect(semantic.contains("simple edge-flip-flop profile"))
            }
        }
    }
}

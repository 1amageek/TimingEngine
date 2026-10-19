import Foundation
import Testing
@testable import TimingCore

@Suite("Actual checked source numerical receipts", .timeLimit(.minutes(1)))
struct LibertySourceSampleTests {
    @Test func actualPropagationOperandsAndBothDomainBoundaries() throws {
        let library = try characterize()
        let value = try library.evaluatePropagation(cell: "FF", fromPin: "C", toPin: "Q", edge: .rise,
            inputSlew: 2e-9, outputLoad: 4e-12)
        #expect(abs(value.delay.result - 7e-9) < 1e-22)
        #expect(abs(value.outputSlew.result - 6e-9) < 1e-22)
        #expect(value.delay.firstInput == 2e-9 && value.delay.secondInput == 4e-12)
        #expect(value.delay.source.cell == "FF" && value.delay.source.pin == "Q")
        #expect(value.delay.table.name == "cell_rise" && value.outputSlew.table.name == "rise_transition")
        for (slew, load) in [(1e-9, 2e-12), (3e-9, 6e-12)] {
            let sample = try library.evaluatePropagation(cell: "FF", fromPin: "C", toPin: "Q", edge: .fall,
                inputSlew: slew, outputLoad: load)
            try library.validate(sample.delay); try library.validate(sample.outputSlew)
        }
        for (slew, load) in [(0.0, 4e-12), (4e-9, 4e-12), (2e-9, 1e-12), (2e-9, 7e-12), (.infinity, 4e-12), (.nan, 4e-12)] {
            #expect(throws: TimingCharacterizationError.self) {
                _ = try library.evaluatePropagation(cell: "FF", fromPin: "C", toPin: "Q", edge: .rise,
                    inputSlew: slew, outputLoad: load)
            }
        }
    }

    @Test func sharedConstraintGroupKeepsBothEdgesSignedAndExplicitZero() throws {
        let library = try characterize()
        let rise = try library.evaluateCheck(cell: "FF", kind: .setup, constrainedPin: "D", relatedPin: "C",
            constrainedEdge: .rise, relatedEdge: .rise, constrainedSlew: 2e-9, relatedSlew: 2e-9)
        let fall = try library.evaluateCheck(cell: "FF", kind: .setup, constrainedPin: "D", relatedPin: "C",
            constrainedEdge: .fall, relatedEdge: .rise, constrainedSlew: 2e-9, relatedSlew: 2e-9)
        #expect(rise.result == -2e-9 && fall.result == -1e-9)
        #expect(rise.source == fall.source && rise.table != fall.table)
        try library.validate(rise); try library.validate(fall)
        let zero = try library.evaluateCheck(cell: "FF", kind: .hold, constrainedPin: "D", relatedPin: "C",
            constrainedEdge: .rise, relatedEdge: .rise, constrainedSlew: 2e-9, relatedSlew: 2e-9)
        #expect(zero.result == 0)
        try library.validate(zero)
        #expect(throws: TimingCharacterizationError.self) {
            _ = try library.evaluateCheck(cell: "FF", kind: .setup, constrainedPin: "D", relatedPin: "C",
                constrainedEdge: .rise, relatedEdge: .rise, constrainedSlew: 4e-9, relatedSlew: 2e-9)
        }
    }

    @Test func decodedReceiptsNeedExactRetainedSourceRevalidation() throws {
        let library = try characterize()
        let original = try library.evaluatePropagation(cell: "FF", fromPin: "C", toPin: "Q", edge: .rise,
            inputSlew: 2e-9, outputLoad: 4e-12).delay
        let bytes = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimingSourceEvaluationSample.self, from: bytes)
        try library.validate(decoded)
        for field in ["result", "firstInput", "firstMinimum"] {
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object[field] = field == "result" ? 999.0 : 0.0
            let edited = try JSONDecoder().decode(TimingSourceEvaluationSample.self,
                from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: TimingCharacterizationError.self) { try library.validate(edited) }
        }
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var identity = try #require(object["source"] as? [String: Any])
        identity["ordinal"] = 999
        object["source"] = identity
        let forged = try JSONDecoder().decode(TimingSourceEvaluationSample.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: TimingCharacterizationError.self) { try library.validate(forged) }
    }

    private func characterize() throws -> CharacterizedTimingLibrary {
        let text = """
        library(L) { time_unit:"1ns"; capacitive_load_unit(1,pf);
          lu_table_template(t) { variable_1:input_net_transition; variable_2:total_output_net_capacitance; index_1("1,3"); index_2("2,6"); }
          lu_table_template(c) { variable_1:constrained_pin_transition; variable_2:related_pin_transition; index_1("1,3"); index_2("1,3"); }
          cell(FF) { ff(S,SN) { clocked_on:C; next_state:D; }
            pin(C) { direction:input; capacitance:0.1; clock:true; }
            pin(D) { direction:input; capacitance:0.1;
              timing() { related_pin:C; timing_type:setup_rising;
                rise_constraint(c) { values("-2,-2","-2,-2"); } fall_constraint(c) { values("-1,-1","-1,-1"); } }
              timing() { related_pin:C; timing_type:hold_rising;
                rise_constraint(c) { values("0,0","0,0"); } fall_constraint(c) { values("0,0","0,0"); } }
            }
            pin(Q) { direction:output; function:S;
              timing() { related_pin:C; timing_type:rising_edge; timing_sense:non_unate;
                cell_rise(t) { values("2,6","8,12"); } cell_fall(t) { values("10,30","40,60"); }
                rise_transition(t) { values("1,5","7,11"); } fall_transition(t) { values("2,6","8,12"); } }
            }
          }
        }
        """
        let bytes = Array(text.utf8)
        return try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["FF"],
            propagationCellNames: [], sequentialPropagationCellNames: ["FF"],
            limits: .init(maximumNestingDepth: 64), resources: LibertyCodecTestResources())
    }
}

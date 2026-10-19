import Foundation
import Testing
@testable import TimingCore

@Suite("Source-qualified whole-rectangle ranges", .timeLimit(.minutes(1)))
struct CharacterizedRangeEvaluationTests {
    private var source: String {
        """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;
            index_1("1,2,4");index_2("1,2,4");}
          lu_table_template(c){variable_1:constrained_pin_transition;variable_2:related_pin_transition;
            index_1("1,2,4");index_2("1,2,4");}
          lu_table_template(p){variable_1:related_pin_transition;index_1("1,2,4");}
          cell(CELL){pin(A){direction:input;capacitance:0.1;}
            pin(Y){direction:output;function:A;
              timing(){related_pin:A;timing_sense:positive_unate;
                cell_rise(t){values("1,2,1","2,9,2","1,2,1");}
                cell_fall(t){values("10,11,10","11,12,11","10,11,10");}
                rise_transition(t){values("8,7,8","7,0.5,7","8,7,8");}
                fall_transition(t){values("10,11,10","11,12,11","10,11,10");}}}}
          cell(FF){ff(S,SN){next_state:D;clocked_on:C;clear:"!R";}
            pin(C){direction:input;capacitance:0.1;
              timing(){related_pin:C;related_output_pin:Q;timing_type:min_pulse_width;
                rise_constraint(p){values("1,7,2");}}}
            pin(D){direction:input;capacitance:0.1;
              timing(){related_pin:C;timing_type:setup_rising;
                rise_constraint(c){values("1,2,1","2,-9,2","1,2,1");}
                fall_constraint(c){values("0,0,0","0,0,0","0,0,0");}}}
            pin(R){direction:input;capacitance:0.1;min_pulse_width_low:0.5;}
            pin(Q){direction:output;function:S;
              timing(){related_pin:R;timing_type:clear;timing_sense:positive_unate;
                cell_fall(t){values("1,2,1","2,9,2","1,2,1");}
                fall_transition(t){values("8,7,8","7,0.5,7","8,7,8");}}}}
        }
        """
    }

    private func characterize(_ text: String? = nil, resources: LibertyCodecTestResources = .init()) throws -> CharacterizedTimingLibrary {
        let bytes = Array((text ?? source).utf8)
        return try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["CELL", "FF"],
            propagationCellNames: ["CELL"], sequentialPropagationCellNames: ["FF"],
            limits: .init(maximumNestingDepth: 64), resources: resources)
    }

    @Test func interiorKnotsAndClippedVerticesSetIndependentExtrema() throws {
        let library = try characterize()
        let sample = try library.evaluatePropagation(cell: "CELL", fromPin: "A", toPin: "Y", edge: .rise,
            inputSlew: 1.5e-9...3e-9, outputLoad: 1.5e-12...3e-12)
        #expect(abs(sample.delay.result.lowerBound - 3.5e-9) < 1e-22)
        #expect(abs(sample.delay.result.upperBound - 9e-9) < 1e-22)
        #expect(abs(sample.outputSlew.result.lowerBound - 0.5e-9) < 1e-22)
        #expect(abs(sample.outputSlew.result.upperBound - 5.625e-9) < 1e-22)
        for i in 0...24 {
            for j in 0...24 {
                let x = 1.5e-9 + Double(i) * 1.5e-9 / 24
                let y = 1.5e-12 + Double(j) * 1.5e-12 / 24
                let point = try library.evaluatePropagation(cell: "CELL", fromPin: "A", toPin: "Y", edge: .rise,
                    inputSlew: x, outputLoad: y)
                #expect(sample.delay.result.contains(point.delay.result))
                #expect(sample.outputSlew.result.contains(point.outputSlew.result))
            }
        }
        try library.validate(sample)
        let floor = try library.fullDomainOutputSlew(cell: "CELL", fromPin: "A", toPin: "Y")
        #expect(abs(floor.lowerBound - 0.5e-9) < 1e-22 && abs(floor.upperBound - 12e-9) < 1e-22)
    }

    @Test func signedChecksPulseAndDirectionalRangesKeepActualSourceTables() throws {
        let library = try characterize()
        let check = try library.evaluateCheck(cell: "FF", kind: .setup, constrainedPin: "D", relatedPin: "C",
            constrainedEdge: .rise, relatedEdge: .rise, constrainedSlew: 1e-9...4e-9, relatedSlew: 1e-9...4e-9)
        #expect(abs(check.result.lowerBound + 9e-9) < 1e-22 && check.result.upperBound > 0)
        try library.validate(check)
        let law = try #require(try library.pulseWidthConstraints(cell: "FF").first { $0.pin == "C" })
        let pulse = try library.evaluatePulseWidth(cell: "FF", pin: "C", openingEdge: .rise,
            sourceIdentity: #require(law.sourceIdentity), inputSlew: 1.5e-9...3e-9)
        #expect(abs(pulse.result.lowerBound - 4e-9) < 1e-22 && abs(pulse.result.upperBound - 7e-9) < 1e-22)
        try library.validate(pulse)
        let scalarLaw = try #require(try library.pulseWidthConstraints(cell: "FF").first { $0.pin == "R" })
        let scalar = try library.evaluatePulseWidth(cell: "FF", pin: "R", openingEdge: .fall,
            sourceIdentity: #require(scalarLaw.sourceIdentity), inputSlew: 0...100)
        #expect(scalar.inputSlew == nil && scalar.slewDomain == nil && scalar.result.lowerBound == scalar.result.upperBound)
        try library.validate(scalar)
        let arc = try #require(try library.directionalControlArcs(cell: "FF").first)
        let identity = arc.sourceIdentity
        let control = try library.evaluateDirectionalControl(cell: "FF", fromPin: "R", toPin: "Q", kind: .clear,
            outputEdge: .fall, sourceIdentity: identity, inputSlew: 1.5e-9...3e-9, outputLoad: 1.5e-12...3e-12)
        #expect(abs(control.delay.result.upperBound - 9e-9) < 1e-22)
        #expect(abs(control.outputSlew.result.lowerBound - 0.5e-9) < 1e-22)
        try library.validate(control)
        let floor = try library.fullDomainOutputSlew(cell: "FF", fromPin: "R", toPin: "Q", kind: .clear, sourceIdentity: identity)
        #expect(abs(floor.lowerBound - 0.5e-9) < 1e-22)
        #expect(throws: TimingCharacterizationError.self) {
            _ = try library.evaluateDirectionalControl(cell: "FF", fromPin: "R", toPin: "Q", kind: .clear,
                outputEdge: .rise, sourceIdentity: identity, inputSlew: 1e-9...2e-9, outputLoad: 1e-12...2e-12)
        }
    }

    @Test func sourceDomainsRevalidationAndNonpositiveFloorCannotBeForged() throws {
        let library = try characterize()
        for range in [0...2e-9, 1e-9...5e-9, 1e-9...Double.infinity] {
            #expect(throws: TimingCharacterizationError.self) {
                _ = try library.evaluatePropagation(cell: "CELL", fromPin: "A", toPin: "Y", edge: .rise,
                    inputSlew: range, outputLoad: 1e-12...2e-12)
            }
        }
        let original = try library.evaluatePropagation(cell: "CELL", fromPin: "A", toPin: "Y", edge: .rise,
            inputSlew: 1e-9...4e-9, outputLoad: 1e-12...4e-12).delay
        try library.validate(JSONDecoder().decode(TimingSourceEvaluationRangeSample.self, from: JSONEncoder().encode(original)))
        let forged = TimingSourceEvaluationRangeSample(source: original.source, table: original.table,
            quantity: original.quantity, firstInput: original.firstInput, secondInput: original.secondInput,
            firstDomain: original.firstDomain, secondDomain: original.secondDomain, result: 0...0)
        #expect(throws: TimingCharacterizationError.self) { try library.validate(forged) }
        let altered = try characterize(source.replacingOccurrences(of: "7,0.5,7", with: "7,0,7"))
        #expect(throws: TimingCharacterizationError.self) {
            _ = try altered.fullDomainOutputSlew(cell: "CELL", fromPin: "A", toPin: "Y")
        }
        // The pre-existing point API still admits a real zero source transition.
        #expect(try altered.evaluatePropagation(cell: "CELL", fromPin: "A", toPin: "Y", edge: .rise,
            inputSlew: 2e-9, outputLoad: 2e-12).outputSlew.result == 0)
    }
}

import Foundation
import Testing
@testable import TimingCore

@Suite("Positioned source pulse-width laws", .timeLimit(.minutes(1)))
struct LibertyPulseWidthTests {
    private let cells = ["LATCH", "FF", "RESET", "SCALAR", "NONE"]
    private var source: String {
        """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(pulse){variable_1:related_pin_transition;index_1("0.01,0.5,1.5");}
          cell(LATCH){latch(S,SN){data_in:D;enable:GATE;}
            pin(D){direction:input;capacitance:0.1;}
            pin(GATE){direction:input;capacitance:0.1;
              timing(){related_pin:GATE;related_output_pin:Q;timing_type:min_pulse_width;
                rise_constraint(pulse){values("0.17,0.83,2.5");}}}
            pin(Q){direction:output;function:S;}}
          cell(FF){ff(S,SN){next_state:D;clocked_on:CLK;}
            pin(D){direction:input;capacitance:0.1;}
            pin(CLK){direction:input;capacitance:0.1;
              timing(){related_pin:CLK;related_output_pin:Q;timing_type:min_pulse_width;
                rise_constraint(pulse){values("0.15,0.8,2.5");}
                fall_constraint(pulse){values("0.2,0.9,2.6");}}}
            pin(Q){direction:output;function:S;}}
          cell(RESET){ff(S,SN){next_state:D;clocked_on:CLK;clear:"!RESET_B";}
            pin(D){direction:input;capacitance:0.1;}
            pin(CLK){direction:input;capacitance:0.1;
              timing(){related_pin:CLK;related_output_pin:Q;timing_type:min_pulse_width;
                rise_constraint(pulse){values("0.16,0.84,2.5");}
                fall_constraint(pulse){values("0.21,0.84,2.5");}}}
            pin(RESET_B){direction:input;capacitance:0.1;
              timing(){related_pin:RESET_B;related_output_pin:Q;timing_type:min_pulse_width;
                fall_constraint(pulse){values("0.18,0.85,2.55");}}}
            pin(Q){direction:output;function:S;}}
          cell(SCALAR){pin(CLK){direction:input;capacitance:0.1;
            min_pulse_width_high:0.5;min_pulse_width_low:0.7;}}
          cell(NONE){pin(CLK){direction:input;capacitance:0.1;}}
        }
        """
    }

    private func characterize(_ text: String, resources: LibertyCodecTestResources = .init(), selected: [String]? = nil) throws -> CharacterizedTimingLibrary {
        let bytes = Array(text.utf8)
        return try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: selected ?? cells,
            propagationCellNames: [], limits: .init(maximumNestingDepth: 32), resources: resources)
    }

    @Test func actualPinsEdgesAndSourcePositionsAreIndependent() throws {
        let library = try characterize(source)
        let latch = try library.pulseWidthConstraints(cell: "LATCH")
        let ff = try library.pulseWidthConstraints(cell: "FF")
        let reset = try library.pulseWidthConstraints(cell: "RESET")
        #expect(latch.count == 1 && latch[0].pin == "GATE" && latch[0].openingEdge == .rise)
        #expect(ff.map(\.openingEdge) == [.rise, .fall])
        #expect(reset.count == 3)
        #expect(reset.filter { $0.pin == "CLK" }.map(\.openingEdge) == [.rise, .fall])
        #expect(reset.filter { $0.pin == "RESET_B" }.map(\.openingEdge) == [.fall])
        #expect(try library.pulseWidthConstraints(cell: "NONE").isEmpty)
        #expect(ff[0].sourceIdentity == ff[1].sourceIdentity)
        for law in latch + ff + reset {
            let identity = try #require(law.sourceIdentity)
            #expect(law.relatedPin == law.pin && law.relatedOutputPin == "Q")
            #expect(identity.pin == law.pin && identity.timingType == "min_pulse_width")
            #expect(String(decoding: Array(source.utf8).dropFirst(identity.byteOffset), as: UTF8.self).hasPrefix("timing"))
            for table in identity.tables {
                #expect(String(decoding: Array(source.utf8).dropFirst(table.byteOffset), as: UTF8.self).hasPrefix(table.name))
            }
        }
    }

    @Test func actualSlewInterpolatesEachLawWithoutFirstValueOrOppositeEdgeSubstitution() throws {
        let library = try characterize(source)
        let laws = try library.pulseWidthConstraints(cell: "FF")
        for (law, expected) in zip(laws, [1.65e-9, 1.75e-9]) {
            let identity = try #require(law.sourceIdentity)
            let sample = try library.evaluatePulseWidth(cell: "FF", pin: "CLK", openingEdge: law.openingEdge,
                sourceIdentity: identity, inputSlew: 1e-9)
            #expect(abs(sample.result - expected) < 1e-23)
            #expect(sample.inputSlew == 1e-9 && sample.minimumSlew != nil && sample.maximumSlew != nil)
            #expect(sample.table.name == (law.openingEdge == .rise ? "rise_constraint" : "fall_constraint"))
            try library.validate(sample)
            guard case .relatedPinTransition(let table) = law.limit else { Issue.record("Expected actual one-axis law"); continue }
            for boundary in [table.inputSlews[0], table.inputSlews[2]] {
                try library.validate(library.evaluatePulseWidth(cell: "FF", pin: "CLK", openingEdge: law.openingEdge,
                    sourceIdentity: identity, inputSlew: boundary))
            }
            for outside in [0.0, 2e-9, Double.infinity, Double.nan] {
                #expect(throws: TimingCharacterizationError.self) {
                    _ = try library.evaluatePulseWidth(cell: "FF", pin: "CLK", openingEdge: law.openingEdge,
                        sourceIdentity: identity, inputSlew: outside)
                }
            }
        }
        let latch = try #require(try library.pulseWidthConstraints(cell: "LATCH").first)
        #expect(throws: TimingCharacterizationError.self) {
            _ = try library.evaluatePulseWidth(cell: "LATCH", pin: "GATE", openingEdge: .fall,
                sourceIdentity: #require(latch.sourceIdentity), inputSlew: 1e-9)
        }
    }

    @Test func scalarAttributesRemainDistinctAndTransportCannotForgeQualification() throws {
        let library = try characterize(source)
        let scalar = try library.pulseWidthConstraints(cell: "SCALAR")
        #expect(scalar.count == 2 && scalar[0].sourceIdentity != scalar[1].sourceIdentity)
        for (law, expected) in zip(scalar, [5e-10, 7e-10]) {
            let sample = try library.evaluatePulseWidth(cell: "SCALAR", pin: "CLK", openingEdge: law.openingEdge,
                sourceIdentity: #require(law.sourceIdentity), inputSlew: 1e-9)
            #expect(abs(sample.result - expected) < 1e-23)
            #expect(sample.inputSlew == nil && sample.minimumSlew == nil && sample.maximumSlew == nil)
            try library.validate(sample)
        }
        let ordinary = try LibertyParser().parse(Data(source.utf8))
        let bytes = Array(source.utf8)
        let owned = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 32), resources: LibertyCodecTestResources())
        let decoded = try JSONDecoder().decode(TimingLibrary.self, from: JSONEncoder().encode(ordinary))
        for name in cells {
            #expect(try ordinary.cell(named: name).pulseWidthConstraints == owned.library.cell(named: name).pulseWidthConstraints)
            #expect(try ordinary.cell(named: name).pulseWidthConstraints == decoded.cell(named: name).pulseWidthConstraints)
        }
        #expect(try ordinary.cell(named: "FF").sequentialModel?.minPulseWidth == nil)
        let law = try #require(try library.pulseWidthConstraints(cell: "FF").first)
        let sample = try library.evaluatePulseWidth(cell: "FF", pin: "CLK", openingEdge: .rise,
            sourceIdentity: #require(law.sourceIdentity), inputSlew: 1e-9)
        let encoded = try JSONEncoder().encode(sample)
        try library.validate(JSONDecoder().decode(TimingPulseWidthSample.self, from: encoded))
        for field in ["result", "inputSlew", "minimumSlew"] {
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object[field] = 999.0
            let forged = try JSONDecoder().decode(TimingPulseWidthSample.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: TimingCharacterizationError.self) { try library.validate(forged) }
        }
    }

    @Test func malformedLawsAndResourceFailuresCannotPublishPartialSuccess() throws {
        for mutation in [
            ("variable_1:related_pin_transition", "variable_1:input_net_transition"),
            ("variable_1:related_pin_transition", "variable_1:related_pin_transition;variable_2:constrained_pin_transition"),
            ("rise_constraint(pulse)", "rise_constraint(missing)"),
            ("0.15,0.8,2.5", "0.15,0.8"),
            ("0.15,0.8,2.5", "-0.15,0.8,2.5"),
            ("related_pin:GATE;", "related_pin:UNDECLARED;"),
            ("timing_type:min_pulse_width;", "timing_type:min_pulse_width;when:\"D\";")
        ] {
            #expect(throws: LibertySourceError.self) { _ = try characterize(source.replacingOccurrences(of: mutation.0, with: mutation.1)) }
        }
        for resource in [LibertyCodecTestResources(maximumWork: 0), .init(maximumLiveBytes: 0), .init(refuseAfterChecks: 20)] {
            #expect(throws: LibertySourceError.self) { _ = try characterize(source, resources: resource) }
            #expect(resource.liveBytes == 0 && resource.temporaryBytes == 0 && resource.reservationCount == resource.releaseCount)
        }
    }

    @Test func explicitScalarTableIsExactAndNeverAnAbsentTemplateFallback() throws {
        let scalarSource = source.replacingOccurrences(of: "min_pulse_width_high:0.5;", with:
            "timing(){related_pin:CLK;timing_type:min_pulse_width;rise_constraint(scalar){values(\"0.5\");}}")
        let library = try characterize(scalarSource)
        let law = try #require(try library.pulseWidthConstraints(cell: "SCALAR").first { $0.openingEdge == .rise })
        let sample = try library.evaluatePulseWidth(cell: "SCALAR", pin: "CLK", openingEdge: .rise,
            sourceIdentity: #require(law.sourceIdentity), inputSlew: 1e-9)
        #expect(sample.result == 5e-10 && sample.inputSlew == nil && sample.table.name == "rise_constraint")
        try library.validate(sample)
        #expect(throws: LibertySourceError.self) {
            _ = try characterize(scalarSource.replacingOccurrences(of: "rise_constraint(scalar)", with: "rise_constraint(missing)"))
        }
    }

    @Test func actualDirectionalClearAndPresetRemainSourceOnlyWithMissingEdgeRefusal() throws {
        let text = """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;index_1("1,3");index_2("2,6");}
          cell(RESET){ff(S,SN){next_state:D;clocked_on:CLK;clear:"!RESET_B";preset:"!PRESET_B";}
            pin(D){direction:input;capacitance:0.1;}pin(CLK){direction:input;capacitance:0.1;}
            pin(RESET_B){direction:input;capacitance:0.1;}pin(PRESET_B){direction:input;capacitance:0.1;}
            pin(Q){direction:output;function:S;
              timing(){related_pin:RESET_B;timing_type:clear;timing_sense:positive_unate;
                cell_fall(t){values("2,6","8,12");}fall_transition(t){values("1,5","7,11");}}
              timing(){related_pin:PRESET_B;timing_type:preset;timing_sense:negative_unate;
                cell_rise(t){values("4,8","10,14");}rise_transition(t){values("2,6","8,12");}}}
          }
        }
        """
        let library = try characterize(text, selected: ["RESET"])
        let arcs = try library.directionalControlArcs(cell: "RESET")
        #expect(arcs.count == 2 && arcs[0].kind == .clear && arcs[1].kind == .preset)
        #expect(arcs[0].delayRise == nil && arcs[0].transitionRise == nil)
        #expect(arcs[0].delayFall != nil && arcs[0].transitionFall != nil)
        #expect(arcs[1].delayFall == nil && arcs[1].transitionFall == nil)
        #expect(arcs[0].sourceIdentity.tables.map(\.name) == ["cell_fall", "fall_transition"])
        let ordinary = try LibertyParser().parse(Data(text.utf8)).cell(named: "RESET")
        #expect(ordinary.arcs.isEmpty && ordinary.directionalControlArcs == arcs)
        #expect(throws: TimingCharacterizationError.self) {
            _ = try library.evaluatePropagation(cell: "RESET", fromPin: "RESET_B", toPin: "Q", edge: .fall,
                inputSlew: 2e-9, outputLoad: 4e-12)
        }
        for (arc, edge, expected) in [(arcs[0], TimingEdge.fall, 7e-9), (arcs[1], .rise, 9e-9)] {
            let sample = try library.evaluateDirectionalControl(cell: "RESET", fromPin: arc.fromPin, toPin: arc.toPin,
                kind: arc.kind, outputEdge: edge, sourceIdentity: arc.sourceIdentity, inputSlew: 2e-9, outputLoad: 4e-12)
            #expect(abs(sample.delay.result - expected) < 1e-23)
            try library.validate(sample.delay); try library.validate(sample.outputSlew)
            #expect(throws: TimingCharacterizationError.self) {
                _ = try library.evaluateDirectionalControl(cell: "RESET", fromPin: arc.fromPin, toPin: arc.toPin,
                    kind: arc.kind, outputEdge: edge == .rise ? .fall : .rise, sourceIdentity: arc.sourceIdentity,
                    inputSlew: 2e-9, outputLoad: 4e-12)
            }
            #expect(throws: TimingCharacterizationError.self) {
                _ = try library.evaluateDirectionalControl(cell: "RESET", fromPin: arc.fromPin, toPin: arc.toPin,
                    kind: arc.kind, outputEdge: edge, sourceIdentity: arc.sourceIdentity, inputSlew: 4e-9, outputLoad: 4e-12)
            }
        }
    }
}

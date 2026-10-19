import Foundation
import Testing
@testable import TimingCore

@Suite("Accounted strict source characterization")
struct LibertyCharacterizedSourceTests {
    private static func source(sequential: Bool = false) -> String {
        let declaration = sequential ? "ff (IQ, IQN) { clocked_on : A; next_state : D; } pin (D) { direction : input; capacitance : 0.1; }" : ""
        let timingType = sequential ? "timing_type : rising_edge;" : ""
        return """
        library (checked) { time_unit : "1ns"; capacitive_load_unit (1, pf);
          lu_table_template (table) { variable_1 : input_net_transition; variable_2 : total_output_net_capacitance;
            index_1 ("1, 3"); index_2 ("2, 6"); }
          cell (CELL) { \(declaration)
            pin (A) { direction : input; capacitance : 0.25; }
            pin (Y) { direction : output; function : "A";
              timing () { related_pin : "A"; timing_sense : positive_unate; \(timingType)
                cell_rise (table) { values ("2, 6", "8, 12"); }
                cell_fall (table) { values ("10, 30", "40, 60"); }
                rise_transition (table) { values ("1, 5", "7, 11"); }
                fall_transition (table) { values ("2, 6", "8, 12"); }
              }
            }
          }
        }
        """
    }
    private func parse(_ source: String, resources: LibertyCodecTestResources, sequential: Bool = false) throws -> CharacterizedTimingLibrary {
        let parser: any LibertySourceCharacterizationParsing = LibertyParser()
        let bytes = Array(source.utf8)
        return try parser.parseCharacterizedSource(bytes.span, cellNames: ["CELL"],
            propagationCellNames: sequential ? [] : ["CELL"], sequentialPropagationCellNames: sequential ? ["CELL"] : [],
            limits: .init(maximumNestingDepth: 8), resources: resources)
    }

    @Test("actual interpolation, checked domain and retained receipts", .timeLimit(.minutes(1)))
    func retainedInterpolation() throws {
        let resources = LibertyCodecTestResources()
        do {
            let library = try parse(Self.source(), resources: resources)
            #expect(resources.liveBytes > 0)
            #expect(resources.temporaryBytes == 0)
            #expect(try library.pinCapacitanceSource(cell: "CELL", pin: "A") == .pinAttribute)
            let value = try library.evaluate(cell: "CELL", fromPin: "A", toPin: "Y", edge: .rise, inputSlew: 2e-9, outputLoad: 4e-12)
            #expect(abs(value.delay - 7e-9) < 1e-22)
            #expect(abs(value.outputSlew - 6e-9) < 1e-22)
            #expect(library.standardDefaultAttributes.contains("input_threshold_pct_rise"))
            #expect(throws: TimingCharacterizationError.self) {
                _ = try library.evaluate(cell: "CELL", fromPin: "A", toPin: "Y", edge: .rise, inputSlew: 4e-9, outputLoad: 4e-12)
            }
            let copy = library
            #expect(copy.name == "checked")
        }
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test("sequential opt-in requires actual four clock-to-Q tables", .timeLimit(.minutes(1)))
    func sequentialOptIn() throws {
        let resources = LibertyCodecTestResources()
        let library = try parse(Self.source(sequential: true), resources: resources, sequential: true)
        #expect(try library.evaluate(cell: "CELL", fromPin: "A", toPin: "Y", edge: .fall, inputSlew: 2e-9, outputLoad: 4e-12).delay > 0)
        #expect(throws: TimingCharacterizationError.self) {
            _ = try LibertyParser().parseCharacterized(Data(Self.source(sequential: true).utf8), cellNames: ["CELL"], propagationCellNames: ["CELL"])
        }
        let missing = Self.source(sequential: true).replacingOccurrences(of: "rise_transition (table)", with: "unused_transition (table)")
        #expect(throws: LibertySourceError.self) { _ = try parse(missing, resources: LibertyCodecTestResources(), sequential: true) }
    }

    @Test("cumulative work, storage, cancellation and deadline preserve typed refusal", .timeLimit(.minutes(1)))
    func resourceFailures() throws {
        let cases: [(LibertyCodecTestResources, LibertyCodecTestResources.Failure)] = [
            (.init(maximumWork: 0), .work), (.init(maximumLiveBytes: 0), .quota(.liveOwnedBytes)),
            (.init(maximumTemporaryBytes: 0), .quota(.temporaryBytes)),
            (.init(refuseAfterChecks: 5), .cancelled), (.init(refuseAfterChecks: 5, checkFailure: .deadline), .deadline)]
        for (resources, expected) in cases {
            do { _ = try parse(Self.source(), resources: resources); Issue.record("Resource refusal was lost") }
            catch LibertySourceError.resource(let cause) { #expect(cause as? LibertyCodecTestResources.Failure == expected) }
            #expect(resources.liveBytes == 0); #expect(resources.temporaryBytes == 0)
            #expect(resources.reservationCount == resources.releaseCount)
        }
        let resources = LibertyCodecTestResources(maximumWork: 1)
        try resources.chargeWork(1)
        #expect(throws: LibertySourceError.self) { _ = try parse(Self.source(), resources: resources) }
        #expect(resources.work == 1)
    }

    @Test("source semantic refusal cannot become ordinary table fallback", .timeLimit(.minutes(1)), arguments: [
        ("rise_transition (table)", "unused_transition (table)"),
        ("timing_sense : positive_unate;", ""),
        ("variable_1 : input_net_transition;", "variable_1 : related_pin_transition;")])
    func sourceFailures(_ mutation: (String, String)) throws {
        let resources = LibertyCodecTestResources()
        do { _ = try parse(Self.source().replacingOccurrences(of: mutation.0, with: mutation.1), resources: resources); Issue.record("Unsupported source was admitted") }
        catch LibertySourceError.conversion(let cause) { #expect(cause is TimingCharacterizationError) }
        #expect(resources.liveBytes == 0); #expect(resources.temporaryBytes == 0)
    }
}

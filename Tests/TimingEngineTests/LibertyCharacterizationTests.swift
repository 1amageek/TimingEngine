import Foundation
import Testing
@testable import TimingCore

@Suite("Strict Liberty characterization")
struct LibertyCharacterizationTests {
    @Test("Sky130 numeric rows accept quoted and unquoted line continuation", arguments: ["\n", "\r\n"])
    func numericLineContinuation(_ newline: String) throws {
        let continuation = "\\" + newline
        let source = Self.source
            .replacingOccurrences(of: "time_unit : \"1ns\";", with: "time_unit : " + continuation + "\"1ns\";")
            .replacingOccurrences(of: "values (\"2, 4\", \"6, 8\");", with:
                "values (\"0.1836933000," + continuation + " 0.2005383000\", " + continuation
                + "\"0.1901908000, 0.2070675000\");")
        let ordinary = try LibertyParser().parse(Data(source.utf8))
        let table = try #require(ordinary.cells["BUF"]?.arcs.first?.delayRise)
        #expect(abs(table.values[0][0] - 0.1836933000e-9) < 1e-22)
        #expect(abs(table.values[1][1] - 0.2070675000e-9) < 1e-22)
        let strict = try characterized(source)
        let value = try strict.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .rise,
            inputSlew: 2e-9, outputLoad: 2e-12)
        #expect(abs(value.delay - 0.195372475e-9) < 1e-22)
    }

    @Test("a lone backslash remains an invalid numeric source token")
    func rejectsNonContinuationBackslash() {
        let source = Self.source.replacingOccurrences(of: "values (\"2, 4\", \"6, 8\");",
            with: "values (\"2, 4\", \\ \"6, 8\");")
        #expect(throws: TimingError.self) { _ = try LibertyParser().parse(Data(source.utf8)) }
    }

    @Test("continued quoted strings retain physical diagnostic lines")
    func continuedStringDiagnosticLine() {
        let source = "library (x) {\n time_unit : \"1\\\nns\";\n cell (BUF) { pin (A) { capacitance : bad; } }\n}"
        do {
            _ = try LibertyParser().parse(Data(source.utf8))
            Issue.record("Invalid capacitance must fail admission.")
        } catch TimingError.parseFailure(_, let line, let message) {
            #expect(line == 4)
            #expect(message.contains("capacitance"))
        } catch {
            Issue.record("Unexpected parse error: \(error)")
        }
    }

    @Test("Liberty template axes preserve their actual dimensions")
    func templateDimensions() throws {
        let source = Self.source.replacingOccurrences(
            of: "variable_1 : input_net_transition; variable_2 : total_output_net_capacitance;",
            with: "variable_1 : total_output_net_capacitance; variable_2 : input_net_transition;"
        )
        let library = try LibertyParser().parse(Data(source.utf8))
        let cell = try library.cell(named: "BUF")
        let table = try #require(cell.arcs.first?.delayRise)
        #expect(zip(table.inputSlews, [1e-9, 3e-9]).allSatisfy { abs($0 - $1) < 1e-20 })
        #expect(table.outputLoads == [1e-12, 3e-12])
        #expect(abs(table.lookup(inputSlew: 2e-9, outputLoad: 2e-12) - 5e-9) < 1e-20)
    }

    @Test("strict characterization evaluates independent literal rise/fall delay and slew")
    func evaluatesRiseFall() throws {
        let library = try characterized(Self.source)
        let rise = try library.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .rise, inputSlew: 2e-9, outputLoad: 2e-12)
        let fall = try library.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .fall, inputSlew: 2e-9, outputLoad: 2e-12)
        #expect(abs(rise.delay - 5e-9) < 1e-20)
        #expect(abs(fall.delay - 16e-9) < 1e-20)
        #expect(abs(rise.outputSlew - 4e-9) < 1e-20)
        #expect(abs(fall.outputSlew - 8e-9) < 1e-20)
        #expect(try library.pinCapacitance(cell: "SINK", pin: "CLK") == 0.5e-12)
        #expect(try library.pinIsClock(cell: "SINK", pin: "CLK"))
        #expect(try library.pinCapacitanceSource(cell: "BUF", pin: "A") == .pinAttribute)
        #expect(library.thresholds.inputRise == 50)
        #expect(library.thresholds.slewLowerFall == 20)
        #expect(library.standardDefaultAttributes.contains("input_threshold_pct_rise"))
        #expect(!library.standardDefaultAttributes.contains("time_unit"))
        #expect(throws: TimingCharacterizationError.self) {
            _ = try library.evaluate(cell: "SINK", fromPin: "CLK", toPin: "Q", edge: .rise, inputSlew: 2e-9, outputLoad: 2e-12)
        }
    }

    @Test("legitimate standard defaults and explicit library pin defaults retain their source")
    func normativeDefaults() throws {
        let source = Self.source.replacingOccurrences(of: "time_unit : \"1ns\";", with: "input_threshold_pct_rise : 45; default_input_pin_cap : 0.125;")
            .replacingOccurrences(of: "capacitance : 0.25;", with: "")
        let library = try characterized(source)
        #expect(library.standardDefaultAttributes.contains("time_unit"))
        #expect(!library.standardDefaultAttributes.contains("input_threshold_pct_rise"))
        #expect(library.thresholds.inputRise == 45)
        #expect(try library.pinCapacitance(cell: "BUF", pin: "A") == 0.125e-12)
        #expect(try library.pinCapacitanceSource(cell: "BUF", pin: "A") == .libraryDefaultInputPinCap)
        let ordinary = try LibertyParser().parse(Data(source.utf8))
        #expect(ordinary.timeUnitScale == 1e-9)
        let arc = try #require(ordinary.cells["BUF"]?.arcs.first)
        #expect(abs(arc.delayRise.lookup(inputSlew: 2e-9, outputLoad: 2e-12) - 5e-9) < 1e-20)
    }

    @Test("template inheritance, local override and transposition keep dimensions and values")
    func indexesAndTranspose() throws {
        let transposed = try characterized(Self.source.replacingOccurrences(
            of: "variable_1 : input_net_transition; variable_2 : total_output_net_capacitance;",
            with: "variable_1 : total_output_net_capacitance; variable_2 : input_net_transition;"))
        let atCorner = try transposed.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .rise, inputSlew: 3e-9, outputLoad: 1e-12)
        #expect(abs(atCorner.delay - 4e-9) < 1e-20)
        let overridden = try characterized(Self.source.replacingOccurrences(of: "(table) { values", with: "(table) { index_1 (\"2, 4\"); index_2 (\"2, 4\"); values"))
        #expect(throws: TimingCharacterizationError.self) {
            _ = try overridden.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .rise, inputSlew: 1e-9, outputLoad: 1e-12)
        }
        let sample = try overridden.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .rise, inputSlew: 3e-9, outputLoad: 3e-12)
        #expect(abs(sample.delay - 5e-9) < 1e-20)
    }

    @Test("all edge tables enforce exact boundaries and reject extrapolation", arguments: [
        (0.5e-9, 2e-12), (4e-9, 2e-12), (2e-9, 0.5e-12), (2e-9, 4e-12),
        (Double.nan, 2e-12), (2e-9, Double.infinity), (-1.0, 2e-12)
    ])
    func rangeFailures(_ point: (Double, Double)) throws {
        let library = try characterized(Self.source)
        #expect(throws: TimingCharacterizationError.self) {
            _ = try library.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .rise, inputSlew: point.0, outputLoad: point.1)
        }
        let boundary = try library.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .fall, inputSlew: 1e-9, outputLoad: 1e-12)
        #expect(abs(boundary.delay - 10e-9) < 1e-20)
    }

    @Test("missing source facts, unsupported semantics and ambiguous source fail admission", arguments: [
        ("capacitive_load_unit (1, pf);", ""),
        ("capacitance : 0.25;", ""),
        ("rise_transition (table) { values (\"1, 3\", \"5, 7\"); }", ""),
        ("cell_fall (table) { values (\"10, 14\", \"18, 22\"); }", ""),
        ("timing_sense : positive_unate;", "timing_sense : unknown;"),
        ("timing_sense : positive_unate;", "timing_sense : positive_unate; when : EN;"),
        ("timing_sense : positive_unate;", "timing_sense : positive_unate; timing_type : rising_edge;"),
        ("variable_1 : input_net_transition;", "variable_1 : related_pin_transition;"),
        ("variable_1 : input_net_transition;", "variable_1 : input_net_transition; variable_3 : time;"),
        ("index_1 (\"1, 3\");", "index_1 (\"3, 1\");"),
        ("index_1 (\"1, 3\");", "index_1 (\"1, 1\");"),
        ("index_1 (\"1, 3\");", ""),
        ("values (\"2, 4\", \"6, 8\");", "values (\"2\", \"4, 6, 8\");"),
        ("capacitance : 0.25;", "capacitance : -1;"),
        ("capacitance : 0.25;", "capacitance : 1ns;"),
        ("direction : input; capacitance : 0.25;", "direction : input; capacitance : 0.25; slew_lower_threshold_pct_rise : 10;"),
        ("time_unit : \"1ns\";", "time_unit : \"1ns\"; slew_derate_from_library : 0.5;"),
        ("time_unit : \"1ns\";", "time_unit : \"1ns\"; slew_lower_threshold_pct_rise : 90;"),
        ("cell (SINK) {", "cell (BUF) {"),
        ("direction : input; capacitance : 0.25;", "direction : input; capacitance : 0.25; capacitance : 0.5;")
    ])
    func rejectsSource(_ mutation: (String, String)) {
        let source = Self.source.replacingOccurrences(of: mutation.0, with: mutation.1)
        #expect(throws: (any Error).self) { _ = try characterized(source) }
    }

    @Test("capacitance-only sequential sink and unselected cells do not require unused tables")
    func selectedRoles() throws {
        let source = Self.source.replacingOccurrences(of: "cell (SINK) { pin (CLK) { direction : input; clock : true; capacitance : 0.5; } }", with: """
        cell (SINK) {
          ff (IQ, IQN) { clocked_on : CLK; next_state : D; }
          pin (D) { direction : input; capacitance : 0.1; }
          pin (CLK) { direction : input; clock : true; capacitance : 0.5; }
          pin (Q) { direction : output; timing () { related_pin : CLK; timing_type : rising_edge; cell_rise (scalar) { values (\"1\"); } } }
        }
        cell (UNUSED) { pin (A) { direction : input; } }
        """)
        let library = try characterized(source)
        #expect(try library.pinIsClock(cell: "SINK", pin: "CLK"))
        #expect(try library.pinCapacitance(cell: "SINK", pin: "CLK") == 0.5e-12)
        #expect(throws: TimingCharacterizationError.self) {
            _ = try LibertyParser().parseCharacterized(Data(source.utf8), cellNames: ["BUF"], propagationCellNames: ["SINK"])
        }
        #expect(throws: TimingCharacterizationError.self) {
            _ = try LibertyParser().parseCharacterized(Data("{}".utf8), cellNames: ["BUF"], propagationCellNames: ["BUF"])
        }
    }

    @Test("a narrower opposite-edge transition domain blocks the shared operating point")
    func allTableDomains() throws {
        let library = try characterized(Self.source.replacingOccurrences(
            of: "fall_transition (table) { values",
            with: "fall_transition (table) { index_1 (\"1.5, 2.5\"); values"))
        #expect(throws: TimingCharacterizationError.self) {
            _ = try library.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .rise, inputSlew: 1e-9, outputLoad: 2e-12)
        }
        let missingTransition = Self.source.replacingOccurrences(of: "rise_transition (table) { values (\"1, 3\", \"5, 7\"); }", with: "")
        #expect(throws: TimingCharacterizationError.missingSourceFact("rise_transition")) {
            _ = try characterized(missingTransition)
        }
    }

    @Test("singleton tables permit only the exact characterized operating point")
    func singleton() throws {
        let lut = try TimingLUT(inputSlews: [1e-9], outputLoads: [1e-12], values: [[2e-9]])
        #expect(try lut.lookupChecked(inputSlew: 1e-9, outputLoad: 1e-12) == 2e-9)
        #expect(throws: TimingCharacterizationError.self) {
            _ = try lut.lookupChecked(inputSlew: 1e-9, outputLoad: 2e-12)
        }
    }

    private func characterized(_ source: String) throws -> CharacterizedTimingLibrary {
        try LibertyParser().parseCharacterized(Data(source.utf8), cellNames: ["BUF", "SINK"], propagationCellNames: ["BUF"])
    }

    static let source = """
    library (characterized) {
      time_unit : "1ns";
      capacitive_load_unit (1, pf);
      lu_table_template (table) {
        variable_1 : input_net_transition; variable_2 : total_output_net_capacitance;
        index_1 ("1, 3"); index_2 ("1, 3");
      }
      cell (BUF) {
        pin (A) { direction : input; capacitance : 0.25; }
        pin (Y) {
          direction : output;
          timing () {
            related_pin : "A"; timing_sense : positive_unate;
            cell_rise (table) { values ("2, 4", "6, 8"); }
            cell_fall (table) { values ("10, 14", "18, 22"); }
            rise_transition (table) { values ("1, 3", "5, 7"); }
            fall_transition (table) { values ("2, 6", "10, 14"); }
          }
        }
      }
      cell (SINK) { pin (CLK) { direction : input; clock : true; capacitance : 0.5; } }
    }
    """
}

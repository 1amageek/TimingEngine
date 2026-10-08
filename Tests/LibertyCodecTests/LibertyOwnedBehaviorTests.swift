import Foundation
import Testing
import TimingCore

@Suite("Public owned Liberty behavior")
struct LibertyOwnedBehaviorTests {
    @Test("owned conversion equals ordinary parsing with real rectangular and transposed tables",
          .timeLimit(.minutes(1)), arguments: [false, true], ["\n", "\r\n"])
    func axesAndMatrix(_ transposed: Bool, _ newline: String) throws {
        let source = Self.tableSource(transposed: transposed, newline: newline, numericSuffixes: true)
        let ordinary = try LibertyParser().parse(Data(source.utf8))
        let owned = try parseOwned(source)
        #expect(owned.library == ordinary)
        #expect(owned.library.timeUnitScale == 1e-9)
        #expect(owned.library.capacitanceUnitScale == 1e-12)
        #expect(owned.library.powerUnitScale == 1e-3)
        let cell = try owned.library.cell(named: "BUF")
        #expect(cell.area == 7.5)
        #expect(cell.powerModel?.leakagePower == 0.125e-3)
        #expect(cell.pins.map(\.name) == ["A", "Y"])
        #expect(try #require(cell.pin(named: "A")).capacitance == 0.25e-12)
        #expect(try #require(cell.pin(named: "Y")).maxCapacitance == 2e-12)
        let arc = try #require(cell.arcs.first)
        #expect(arc.fromPin == "A")
        #expect(arc.toPin == "Y")
        #expect(arc.sense == .positiveUnate)
        #expect(arc.delayRise.inputSlews.count == 2)
        #expect(arc.delayRise.outputLoads.count == 3)
        for (actual, expected) in zip(arc.delayRise.inputSlews, [1e-9, 3e-9]) {
            #expect(abs(actual - expected) < 1e-22)
        }
        for (actual, expected) in zip(arc.delayRise.outputLoads, [2e-12, 4e-12, 6e-12]) {
            #expect(abs(actual - expected) < 1e-25)
        }
        let expectedRise = [[2.0, 4, 6], [8, 10, 12]]
        #expect(arc.delayRise.values.count == 2)
        for row in expectedRise.indices {
            #expect(arc.delayRise.values[row].count == 3)
            for column in expectedRise[row].indices {
                #expect(abs(arc.delayRise.values[row][column] - expectedRise[row][column] * 1e-9) < 1e-22)
            }
        }
        #expect(abs(arc.delayRise.lookup(inputSlew: 2e-9, outputLoad: 4e-12) - 7e-9) < 1e-22)
        #expect(abs(arc.delayFall.lookup(inputSlew: 2e-9, outputLoad: 4e-12) - 35e-9) < 1e-22)
        #expect(owned.byteCount == source.utf8.count)
    }

    @Test("raw numeric PVT and ordered cell/pin facts retain physical CRLF origins",
          .timeLimit(.minutes(1)))
    func rawFactsAndOrigins() throws {
        let source = [
            "library (facts) {",
            "  operating_conditions (raw) {",
            "    process : 1.100e+0;",
            "    voltage : 0.95;",
            "    temperature : -40;",
            "  }",
            "  operating_conditions (voltage_only) { voltage : 1.2; }",
            "  /* physical origin marker */",
            "  cell",
            "  (BUF) {",
            "    pin",
            "    (A) { direction : input; capacitance : 0.25; }",
            "    pin (Y) { direction : output; }",
            "  }",
            "  cell (SINK) { pin (CLK) { direction : input; clock : true; } }",
            "}"
        ].joined(separator: "\r\n")
        let owned = try parseOwned(source)
        #expect(try owned.library == LibertyParser().parse(Data(source.utf8)))
        #expect(owned.cells.map(\.name) == ["BUF", "SINK"])
        let buffer = try #require(owned.cells.first)
        #expect(buffer.line == 9)
        #expect(try buffer.byteOffset == Self.byteOffset(of: "cell\r\n", in: source))
        #expect(buffer.pins.map(\.name) == ["A", "Y"])
        #expect(buffer.pins.map(\.line) == [11, 13])
        #expect(try buffer.pins[0].byteOffset == Self.byteOffset(of: "pin\r\n", in: source))
        #expect(try buffer.pins[1].byteOffset == Self.byteOffset(of: "pin (Y)", in: source))
        #expect(owned.cells[1].line == 15)
        #expect(owned.cells[1].pins.first?.name == "CLK")
        #expect(owned.operatingConditions.map(\.name) == ["raw", "voltage_only"])
        let raw = try #require(owned.operatingConditions.first)
        #expect(raw.line == 2)
        #expect(try raw.byteOffset == Self.byteOffset(of: "operating_conditions (raw)", in: source))
        #expect(raw.process == 1.1)
        #expect(raw.voltage == 0.95)
        #expect(raw.temperature == -40)
        #expect(owned.operatingConditions[1].process == nil)
        #expect(owned.operatingConditions[1].voltage == 1.2)
        #expect(owned.operatingConditions[1].temperature == nil)
    }

    @Test("owned source refuses canonical JSON accepted by the ordinary API",
          .timeLimit(.minutes(1)))
    func rejectsCanonicalJSON() throws {
        let source = Self.tableSource(transposed: false, newline: "\n", numericSuffixes: false)
        let ordinary = try LibertyParser().parse(Data(source.utf8))
        let json = try JSONEncoder().encode(ordinary)
        #expect(try LibertyParser().parse(json) == ordinary)
        let bytes = Array(json)
        do {
            _ = try LibertyParser().parseSource(bytes.span,
                limits: LibertySourceParseLimits(maximumNestingDepth: 8), resources: LibertyCodecTestResources())
            Issue.record("Canonical JSON must not establish owned Liberty source admission.")
        } catch LibertySourceError.syntax {
        } catch LibertySourceError.unsupportedSemantics {
        } catch {
            Issue.record("Unexpected JSON refusal: \(error)")
        }
    }

    @Test("active dependency and section syntax is refused at each relevant nesting boundary",
          .timeLimit(.minutes(1)), arguments: [
            "include (\"external.lib\");",
            "include_file : \"external.lib\";",
            "library_file (\"external.lib\");",
            "section (FAST) { cell (EXTRA) { pin (A) { direction : input; } } }",
            "lib (\"external.lib\", FAST);",
            "cell (EXTRA) { include (\"external.lib\"); }"
          ])
    func rejectsDependencyAndSection(_ declaration: String) throws {
        let source = "library (x) { cell (BUF) { pin (A) { direction : input; } } " + declaration + " }"
        do {
            _ = try parseOwned(source)
            Issue.record("Active dependency/section syntax must be refused.")
        } catch LibertySourceError.unsupportedSemantics(let context) {
            #expect(!context.isEmpty)
        } catch {
            Issue.record("Unexpected dependency refusal: \(error)")
        }
    }

    @Test("unsupported numeric suffixes fail actual ordinary and owned conversion",
          .timeLimit(.minutes(1)), arguments: [
            ("capacitance : 0.25pf;", "capacitance : 0.25bogus;"),
            ("\"2,", "\"2ns,")
          ])
    func numericSuffixFailures(_ replacement: (String, String)) throws {
        let source = Self.tableSource(transposed: false, newline: "\n", numericSuffixes: true)
            .replacingOccurrences(of: replacement.0, with: replacement.1)
        #expect(throws: TimingError.self) { _ = try LibertyParser().parse(Data(source.utf8)) }
        do {
            _ = try parseOwned(source)
            Issue.record("Unsupported numeric suffix must fail source conversion.")
        } catch LibertySourceError.syntax {
        } catch {
            Issue.record("Unexpected numeric refusal: \(error)")
        }
    }

    @Test("ordinary CTS characterization retains real interpolation and all explicit thresholds",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func characterizedRegression(_ transposed: Bool) throws {
        let source = Self.tableSource(transposed: transposed, newline: "\r\n", numericSuffixes: false)
        let characterized = try LibertyParser().parseCharacterized(Data(source.utf8),
            cellNames: ["BUF"], propagationCellNames: ["BUF"])
        let thresholds = characterized.thresholds
        #expect(thresholds.inputRise == 40)
        #expect(thresholds.inputFall == 45)
        #expect(thresholds.outputRise == 55)
        #expect(thresholds.outputFall == 60)
        #expect(thresholds.slewLowerRise == 20)
        #expect(thresholds.slewUpperRise == 80)
        #expect(thresholds.slewLowerFall == 25)
        #expect(thresholds.slewUpperFall == 75)
        #expect(characterized.standardDefaultAttributes.isEmpty)
        #expect(try characterized.pinCapacitance(cell: "BUF", pin: "A") == 0.25e-12)
        let rise = try characterized.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .rise,
            inputSlew: 2e-9, outputLoad: 4e-12)
        let fall = try characterized.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .fall,
            inputSlew: 2e-9, outputLoad: 4e-12)
        #expect(abs(rise.delay - 7e-9) < 1e-22)
        #expect(abs(rise.outputSlew - 6e-9) < 1e-22)
        #expect(abs(fall.delay - 35e-9) < 1e-22)
        #expect(abs(fall.outputSlew - 7e-9) < 1e-22)
        #expect(throws: TimingCharacterizationError.self) {
            _ = try characterized.evaluate(cell: "BUF", fromPin: "A", toPin: "Y", edge: .rise,
                inputSlew: 4e-9, outputLoad: 4e-12)
        }
    }

    private func parseOwned(_ source: String) throws -> OwnedLibertySource {
        let bytes = Array(source.utf8)
        return try LibertyParser().parseSource(bytes.span,
            limits: LibertySourceParseLimits(maximumNestingDepth: 8), resources: LibertyCodecTestResources())
    }

    private static func byteOffset(of token: String, in source: String) throws -> Int {
        let range = try #require(source.range(of: token))
        return source[..<range.lowerBound].utf8.count
    }

    private static func tableSource(transposed: Bool, newline: String, numericSuffixes: Bool) -> String {
        let axis1 = transposed ? "total_output_net_capacitance" : "input_net_transition"
        let axis2 = transposed ? "input_net_transition" : "total_output_net_capacitance"
        let index1 = transposed ? "2, 4, 6" : "1, 3"
        let index2 = transposed ? "1, 3" : "2, 4, 6"
        let continuation = "\\" + newline
        let rise = transposed ? ["2, 8", "4, 10", "6, 12"] : ["2, 4, 6", "8, 10, 12"]
        let fall = transposed ? ["10, 40", "20, 50", "30, 60"] : ["10, 20, 30", "40, 50, 60"]
        let riseSlew = transposed ? ["1, 7", "3, 9", "5, 11"] : ["1, 3, 5", "7, 9, 11"]
        let fallSlew = transposed ? ["2, 8", "4, 10", "6, 12"] : ["2, 4, 6", "8, 10, 12"]
        func values(_ rows: [String]) -> String {
            rows.map { "\"" + $0.replacingOccurrences(of: ", ", with: "," + continuation + " ") + "\"" }
                .joined(separator: ", " + continuation)
        }
        let capacitance = numericSuffixes ? "0.25pf" : "0.25"
        let maximum = numericSuffixes ? "2pf" : "2"
        return [
            "library (rectangular) {",
            "  time_unit : " + continuation + "\"1ns\";",
            "  capacitive_load_unit (1, pf); power_unit : \"1mW\";",
            "  input_threshold_pct_rise : 40; input_threshold_pct_fall : 45;",
            "  output_threshold_pct_rise : 55; output_threshold_pct_fall : 60;",
            "  slew_lower_threshold_pct_rise : 20; slew_upper_threshold_pct_rise : 80;",
            "  slew_lower_threshold_pct_fall : 25; slew_upper_threshold_pct_fall : 75;",
            "  slew_derate_from_library : 1;",
            "  lu_table_template (table) {",
            "    variable_1 : " + axis1 + "; variable_2 : " + axis2 + ";",
            "    index_1 (\"" + index1 + "\"); index_2 (\"" + index2 + "\");",
            "  }",
            "  cell (BUF) { area : 7.5; cell_leakage_power : 0.125;",
            "    pin (A) { direction : input; capacitance : " + capacitance + "; }",
            "    pin (Y) { direction : output; function : \"A\"; max_capacitance : " + maximum + ";",
            "      timing () { related_pin : \"A\"; timing_sense : positive_unate;",
            "        cell_rise (table) { values (" + values(rise) + "); }",
            "        cell_fall (table) { values (" + values(fall) + "); }",
            "        rise_transition (table) { values (" + values(riseSlew) + "); }",
            "        fall_transition (table) { values (" + values(fallSlew) + "); }",
            "      }",
            "    }",
            "  }",
            "}"
        ].joined(separator: newline)
    }
}

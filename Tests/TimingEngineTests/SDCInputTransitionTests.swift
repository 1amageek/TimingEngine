import Foundation
import Testing
import TimingCore

struct SDCInputTransitionTests {
    @Test("Standard global input transition preserves its SI value and mode")
    func globalTransition() throws {
        let constraints = try SDCParser().parse(Data("set_input_transition 0.45 [all_inputs]".utf8), modeID: "functional")
        #expect(abs(constraints.defaultInputSlew - 0.45e-9) < 1e-22)
        #expect(constraints.modeID == "functional")
    }
    @Test("Global transition time units and last assignment preserve one existing IR value")
    func unitsAndLastAssignment() throws {
        for token in ["450ps", "0.45ns", "4.5e-10s", "450000fs"] {
            let value = try SDCParser().parse(Data("set_input_transition \(token) [ all_inputs ]".utf8))
            #expect(abs(value.defaultInputSlew - 0.45e-9) < 1e-22)
        }
        let custom = try SDCParser(defaultTimeUnit: 1e-12).parse(Data("set_input_transition 450 [all_inputs]".utf8))
        #expect(abs(custom.defaultInputSlew - 0.45e-9) < 1e-22)
        let repeated = try SDCParser().parse(Data("set_input_transition 0.1 [all_inputs]\nset_input_transition 0.45 [all_inputs]".utf8))
        #expect(abs(repeated.defaultInputSlew - 0.45e-9) < 1e-22)
        let decoded = try JSONDecoder().decode(TimingConstraintSet.self, from: JSONEncoder().encode(repeated))
        #expect(decoded == repeated)
    }

    @Test("Transition options, subsets, collection options and extra arguments are typed unsupported")
    func unsupportedProfiles() {
        for source in [
            "set_input_transition -rise 0.45 [all_inputs]",
            "set_input_transition -fall 0.45 [all_inputs]",
            "set_input_transition -min 0.45 [all_inputs]",
            "set_input_transition -max 0.45 [all_inputs]",
            "set_input_transition -clock clk 0.45 [all_inputs]",
            "set_input_transition 0.45 [get_ports in]",
            "set_input_transition 0.45 [get_ports {in io}]",
            "set_input_transition 0.45 [all_inputs -no_clocks]",
            "set_input_transition 0.45 [all_inputs] extra",
            "set_input_transition 0.45 in",
            "set_input_transition 0.45",
            "set_input_transition -rise [all_inputs]"
        ] {
            #expect(throws: TimingError.unsupportedSemantic(format: "SDC",
                semantic: "set_input_transition supports only a global value and [all_inputs] without options")) {
                _ = try SDCParser().parse(Data(source.utf8))
            }
        }
    }

    @Test("Transition zero, negative, nonfinite and underflow cannot become a default slew")
    func numericAdmission() {
        for token in ["0", "0e-999", "-1", "-1ns", "nan", "inf", "1e309", "1e-999", "1e-310fs"] {
            #expect(throws: TimingError.parseFailure(format: "SDC", line: 1,
                message: "Input transition must remain finite and positive in SI units.")) {
                _ = try SDCParser().parse(Data("set_input_transition \(token) [all_inputs]".utf8))
            }
        }
        for unit in [Double.nan, .infinity, 0, -1] {
            #expect(throws: TimingError.parseFailure(format: "SDC", line: 1,
                message: "Input transition requires a finite positive default time unit.")) {
                _ = try SDCParser(defaultTimeUnit: unit).parse(Data("set_input_transition 0.45 [all_inputs]".utf8))
            }
        }
    }

}

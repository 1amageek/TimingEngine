import Foundation
import Testing
import TimingCore

@Suite("Explicit complete SDC primary transition facts", .timeLimit(.minutes(1)))
struct SDCExplicitSourceTransitionTests {
    @Test func numericDefaultNeverBecomesAnExplicitSourceDeclaration() throws {
        let defaults = try SDCParser().parse(Data())
        #expect(defaults.defaultInputSlew == 1e-10 && defaults.inputTransition == nil)
        let numericOnly = TimingConstraintSet(defaultInputSlew: 4.5e-10)
        #expect(numericOnly.inputTransition == nil)
        let explicit = TimingConstraintSet(defaultInputSlew: 4.5e-10,
            inputTransition: .allInputsBothEdges(slew: 4.5e-10))
        #expect(explicit.inputTransition == .allInputsBothEdges(slew: explicit.defaultInputSlew))
    }

    @Test func strictGlobalCommandKeepsValueScopeBothEdgesAndLastAssignment() throws {
        let parsed = try SDCParser().parse(Data("""
        set_input_transition 100ps [all_inputs]
        set_input_transition 450ps [ all_inputs ]
        """.utf8), modeID: "functional")
        #expect(parsed.modeID == "functional")
        #expect(abs(parsed.defaultInputSlew - 4.5e-10) < 1e-23)
        #expect(parsed.inputTransition == .allInputsBothEdges(slew: parsed.defaultInputSlew))
        let decoded = try JSONDecoder().decode(TimingConstraintSet.self, from: JSONEncoder().encode(parsed))
        #expect(decoded == parsed && decoded.schemaVersion == TimingConstraintSet.currentSchemaVersion)
    }

    @Test func oldJSONDoesNotInferAuthorityEvenWhenItsNumericSlewMatches() throws {
        let explicit = TimingConstraintSet(defaultInputSlew: 4.5e-10,
            inputTransition: .allInputsBothEdges(slew: 4.5e-10))
        let bytes = try JSONEncoder().encode(explicit)
        for version in [1, 2] {
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object.removeValue(forKey: "inputTransition")
            object["schemaVersion"] = version
            let decoded = try JSONDecoder().decode(TimingConstraintSet.self,
                from: JSONSerialization.data(withJSONObject: object))
            #expect(decoded.inputTransition == nil && decoded.defaultInputSlew == explicit.defaultInputSlew)
        }
    }

    @Test func partialEdgeMinMaxOrNamedScopeCannotAcquireTheGlobalFact() {
        for command in [
            "set_input_transition -rise 0.45 [all_inputs]",
            "set_input_transition -fall 0.45 [all_inputs]",
            "set_input_transition -min 0.45 [all_inputs]",
            "set_input_transition -max 0.45 [all_inputs]",
            "set_input_transition 0.45 [get_ports in]",
            "set_input_transition 0.45 [all_inputs -no_clocks]"
        ] {
            #expect(throws: TimingError.unsupportedSemantic(format: "SDC",
                semantic: "set_input_transition supports only a global value and [all_inputs] without options")) {
                _ = try SDCParser().parse(Data(("set_input_transition 0.1 [all_inputs]\n" + command).utf8))
            }
        }
    }
}

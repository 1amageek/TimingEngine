import Foundation
import Testing
import TimingCore
import LogicIR
import LogicKernelCore

@Suite(.timeLimit(.minutes(1)))
struct LibertyFunctionalSourceTests {
    private struct Control: LogicRunControlling { func checkpoint() throws(LogicKernelError) {} }
    private func parse(_ source: String, resources: LibertyCodecTestResources = LibertyCodecTestResources(), nesting: Int = 64)
        throws -> OwnedLibertySource {
        let bytes = Array(source.utf8)
        return try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: nesting), resources: resources)
    }
    private func source(_ function: String) -> String {
        "library(L) { cell(C) { pin(A) {direction:input;} pin(B) {direction:input;} pin(C) {direction:input;} pin(Y) {direction:output;function:\"\(function)\";} } }"
    }
    @available(macOS 26.0, *)
    private func evaluate(_ function: LibertySourceFunction, inputs: [String: Bool]) throws -> Bool {
        guard case .normalized(let facts) = function.content else { throw LogicKernelError.invalidModel("Expected normalized source function") }
        var context = LogicKernelContext(limits: try .init(maximums: Dictionary(uniqueKeysWithValues:
            LogicResource.allCases.map { ($0, UInt64(1_000_000)) })), control: Control())
        var builder = try LogicBooleanFunctionBuilder(inputCount: facts.symbols.count, nodeCapacity: facts.operations.count, context: &context)
        for operation in facts.operations { _ = try builder.append(operation, context: &context) }
        let published = try builder.finish(output: facts.output, context: &context)
        return try published.withOperations { operations throws in
            var values = [Bool](repeating: false, count: operations.count)
            for index in operations.indices {
                switch operations[index] {
                case .constant(let value): values[index] = value
                case .input(let slot): values[index] = try #require(inputs[facts.symbols[slot]])
                case .invert(let node): values[index] = !values[node.rawValue]
                case .and(let a, let b): values[index] = values[a.rawValue] && values[b.rawValue]
                case .or(let a, let b): values[index] = values[a.rawValue] || values[b.rawValue]
                case .xor(let a, let b): values[index] = values[a.rawValue] != values[b.rawValue]
                }
            }
            return values[published.output.rawValue]
        }
    }
    @Test func booleanPrecedencePolarityAndConstantsMatchIndependentTruthFunctions() throws {
        guard #available(macOS 26.0, *) else { Issue.record("Requires macOS 26"); return }
        let expressions = ["A * B ^ C", "A ^ B & C", "A + B C", "!(A * B)", "(A | B)'", "A' B + A B'", "!!A", "0", "1", "A ^ B ^ C", "A & !B", " ( A + B ) * C "]
        for index in expressions.indices {
            let owner = try parse(source(expressions[index]))
            let function = try #require(owner.cells[0].pins[3].function)
            for input in 0..<8 {
                let a = input & 1 != 0; let b = input & 2 != 0; let c = input & 4 != 0
                let expected = [a && (b != c), (a != b) && c, a || (b && c), !(a && b), !(a || b),
                                (!a && b) || (a && !b), a, false, true, (a != b) != c, a && !b, (a || b) && c][index]
                #expect(try evaluate(function, inputs: ["A": a, "B": b, "C": c]) == expected)
            }
        }
    }
    @Test func originalPinOrderAreaDontUseAndPhysicalFunctionPositionArePreserved() throws {
        let text = """
        library(L) {
          cell(NAND) { area:2.5; dont_use:true;
            pin(Y) { direction:output;
              function : "!(B A)";
            }
            pin(A) {direction:input;}
            pin(B) {direction:input;}
          }
          cell(CONST) {pin(Y) {direction:output; function:"1";}}
        }
        """
        let owner = try parse(text)
        #expect(owner.cells.map(\.name) == ["NAND", "CONST"])
        let cell = owner.cells[0]
        #expect(cell.pins.map(\.name) == ["Y", "A", "B"])
        #expect(cell.pins.map(\.direction) == [.output, .input, .input])
        #expect(cell.area == 2.5 && cell.dontUse == true)
        let function = try #require(cell.pins[0].function)
        #expect(function.line == 4)
        let range = try #require(text.range(of: "function :"))
        #expect(function.byteOffset == text[..<range.lowerBound].utf8.count)
        guard case .normalized(let facts) = function.content else { Issue.record("Expected normalized function"); return }
        #expect(facts.symbols == ["B", "A"])
        #expect(owner.cells[1].area == nil && owner.cells[1].dontUse == nil)
    }
    @Test func sequentialFactsKeepRealStateDataClockResetAndLatchDefinitions() throws {
        guard #available(macOS 26.0, *) else { Issue.record("Requires macOS 26"); return }
        let text = """
        library(L) {
          cell(FF) {
            ff(IQ,IQN) { next_state:"D EN + IQ EN'"; clocked_on:"!CLK"; clear:"!RN"; preset:"SN"; clear_preset_var1:L; clear_preset_var2:H; power_down_function:"SLEEP"; }
            pin(CLK){direction:input;} pin(D){direction:input;} pin(EN){direction:input;}
            pin(RN){direction:input;} pin(SN){direction:input;}
            pin(SLEEP){direction:input;}
            pin(Q){direction:output;function:"IQ";} pin(QN){direction:output;function:"IQN";}
          }
          cell(LATCH) { latch(S,SN) {data_in:"D";enable:"G'";enable_also:"G2";power_down_function:"!PWR";}
            pg_pin(PWR){pg_type:primary_power;voltage_name:VDD;}
            pin(G){direction:input;} pin(G2){direction:input;} pin(D){direction:input;}
            pin(Q){direction:output;function:"S";}
          }
        }
        """
        let owner = try parse(text)
        let ff = try #require(owner.cells[0].sequential.first)
        #expect(ff.kind == .flipFlop && ff.variables == ["IQ", "IQN"])
        #expect(ff.additionalControl == nil)
        #expect(try evaluate(#require(ff.powerDownFunction), inputs: ["SLEEP":true]))
        #expect(try evaluate(#require(ff.powerDownFunction), inputs: ["SLEEP":false]) == false)
        #expect(ff.clearPresetVariable1 == "L" && ff.clearPresetVariable2 == "H")
        let timingModel = try #require(try owner.library.cell(named: "FF").sequentialModel)
        guard case .source(let compiled) = timingModel.definition else { Issue.record("Source FF became a legacy scalar"); return }
        #expect(compiled.declarations == [ff])
        _ = try compiled.requireBindings()
        let boundData = try #require(compiled.function(for: .data))
        #expect(boundData.symbols == [.inputPin("D"), .inputPin("EN"), .stateVariable("IQ")])
        #expect(boundData.function == ff.data)
        let data = boundData.function
        let clock = try #require(compiled.function(for: .control)).function
        let clear = try #require(compiled.function(for: .clear)).function
        let preset = try #require(compiled.function(for: .preset)).function
        for pattern in 0..<8 {
            let d = pattern & 1 != 0; let en = pattern & 2 != 0; let q = pattern & 4 != 0
            #expect(try evaluate(data, inputs: ["D":d,"EN":en,"IQ":q]) == (en ? d : q))
        }
        #expect(timingModel.dataPin == nil && timingModel.simpleEdgeTriggeredPins == nil)
        #expect(timingModel.clockPin == "CLK" && timingModel.outputPin == nil)
        #expect(compiled.function(for: .output(pin: "Q"))?.symbols == [.stateVariable("IQ")])
        #expect(compiled.function(for: .output(pin: "QN"))?.symbols == [.stateVariable("IQN")])
        #expect(try evaluate(clock, inputs: ["CLK":false]))
        #expect(try evaluate(clear, inputs: ["RN":true]) == false)
        #expect(try evaluate(preset, inputs: ["SN":true]))
        let latch = try #require(owner.cells[1].sequential.first)
        #expect(latch.kind == .latch && latch.variables == ["S", "SN"])
        #expect(latch.additionalControl != nil)
        #expect(try evaluate(#require(latch.powerDownFunction), inputs: ["PWR":false]))
        #expect(try evaluate(#require(latch.control), inputs: ["G":false]))
        let latchModel = try #require(try owner.library.cell(named: "LATCH").sequentialModel)
        guard case .source(let compiledLatch) = latchModel.definition else { Issue.record("Source latch became combinational"); return }
        #expect(compiledLatch.declarations == [latch])
        _ = try compiledLatch.requireBindings()
        #expect(latchModel.clockPin == nil && latchModel.simpleEdgeTriggeredPins == nil)
        #expect(compiledLatch.function(for: .powerDown)?.symbols == [.powerPin("PWR")])
        for d in [false, true] { for gate in [false, true] {
            #expect(try evaluate(#require(compiledLatch.function(for: .data)).function, inputs: ["D":d]) == d)
            #expect(try evaluate(#require(compiledLatch.function(for: .control)).function, inputs: ["G":gate]) == !gate)
        } }
        let reloaded = try JSONDecoder().decode(TimingSequentialModel.self, from: JSONEncoder().encode(timingModel))
        #expect(reloaded == timingModel && reloaded.dataPin == nil)
    }
    @Test func missingMalformedAndUnsupportedFunctionsNeverBecomeApproximateGates() throws {
        let missing = try parse("library(L){cell(C){pin(Y){direction:output;}}}")
        #expect(missing.cells[0].pins[0].function == nil)
        for expression in ["", "A +", "()", "(A", "A)", "A && B", "A B +", "A?B:C", "A[0]", "2", "01", "A(B)"] {
            let owner = try parse(source(expression))
            let function = try #require(owner.cells[0].pins[3].function)
            guard case .unsupported = function.content else { Issue.record("Malformed/unsupported function was normalized: \(expression)"); continue }
        }
        let special = try parse("library(L){cell(C){pin(Y){direction:output; function:\"A\"; three_state:\"!EN\";state_function:\"A EN\";x_function:\"XEN\";}pin(A){direction:input;}pin(EN){direction:input;}pin(XEN){direction:input;}}}")
        let pin = special.cells[0].pins[0]
        #expect(pin.threeState != nil && pin.stateFunction != nil && pin.xFunction != nil)
        let unsupported = try parse("library(L){cell(C){bus(B){} bundle(B2){} ff_bank(S,SN,2){} latch_bank(T,TN,2){} statetable(\"A\",\"S\"){} memory(M){} pin(A,B){direction:input;}}}")
        #expect(unsupported.cells[0].unsupportedFunctionalGroups == ["bus","bundle","ff_bank","latch_bank","statetable","memory","multiple_pin_names"])
    }
    @Test func unavailableBindingRetainsStatefulDefinitionsAndNeverBecomesCombinational() throws {
        let sources = [
            "library(L){cell(C){ff(S,SN){next_state:D;clocked_on:C;clear:RESET;}pin(D){direction:input;}pin(C){direction:input;}pin(Q){direction:output;function:S;}}}",
            "library(L){cell(C){ff(S,SN){next_state:D;clocked_on:C;}pin(D){direction:input;}pin(C){direction:input;}pin(Q){direction:output;}}}",
            "library(L){cell(C){ff(S,SN){next_state:D;clocked_on:C;}latch(T,TN){data_in:D;enable:C;}pin(D){direction:input;}pin(C){direction:input;}pin(Q){direction:output;function:S;}}}",
            "library(L){cell(C){ff(S,SN){next_state:\"D?E:S\";clocked_on:C;}pin(D){direction:input;}pin(C){direction:input;}pin(Q){direction:output;function:S;}}}"
        ]
        for text in sources {
            let owner = try parse(text)
            let model = try #require(try owner.library.cell(named: "C").sequentialModel)
            guard case .source(let source) = model.definition else { Issue.record("Stateful source was discarded"); continue }
            #expect(!source.declarations.isEmpty)
            guard case .unavailable = source.binding else { Issue.record("Incomplete binding was published"); continue }
            #expect(throws: TimingSequentialBindingError.self) { _ = try source.requireBindings() }
            #expect(model.simpleEdgeTriggeredPins == nil)
        }
    }
    @Test func actualPowerPinRelationsRemainUnmeasuredSourceFacts() throws {
        let owner = try parse("""
        library(L){cell(C){
          pg_pin(VPWR){pg_type:primary_power;voltage_name:VDD;}
          pg_pin(VGND){pg_type:primary_ground;voltage_name:VSS;}
          ff(S,SN){next_state:D;clocked_on:C;}
          pin(D){direction:input;}pin(C){direction:input;}
          pin(Q){direction:output;function:S;power_down_function:"!VPWR + VGND";related_power_pin:VPWR;related_ground_pin:VGND;}
        }}
        """)
        let cell = owner.cells[0], pin = try #require(cell.pins.first { $0.name == "Q" })
        #expect(cell.powerPins.map(\.name) == ["VPWR", "VGND"])
        #expect(cell.powerPins.map(\.pgType) == ["primary_power", "primary_ground"])
        #expect(pin.relatedPowerPin == "VPWR" && pin.relatedGroundPin == "VGND")
        let model = try #require(try owner.library.cell(named: "C").sequentialModel)
        guard case .source(let source) = model.definition else { Issue.record("PG-bound stateful source was lost"); return }
        _ = try source.requireBindings()
        #expect(source.function(for: .outputPowerDown(pin: "Q"))?.symbols == [.powerPin("VPWR"), .powerPin("VGND")])
        #expect(model.simpleEdgeTriggeredPins == nil)
    }
    @Test func latchChecksAndPropagationKeepActualGroupAndTablePositions() throws {
        let text = """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          cell(LATCH){latch(S,SN){data_in:D;enable:G;}
            pin(D){direction:input;
              timing(){related_pin:G;timing_type:setup_falling;rise_constraint(t){values("-0.1");}}
              timing(){related_pin:G;timing_type:hold_falling;rise_constraint(t){values("0.2");}}
            }
            pin(G){direction:input;}
            pin(Q){direction:output;function:S;
              timing(){related_pin:D;timing_type:combinational;timing_sense:positive_unate;
                cell_rise(t){values("1");}cell_fall(t){values("2");}rise_transition(t){values("0.3");}fall_transition(t){values("0.4");}}
              timing(){related_pin:G;timing_type:rising_edge;timing_sense:non_unate;
                cell_rise(t){values("3");}cell_fall(t){values("4");}rise_transition(t){values("0.5");}fall_transition(t){values("0.6");}}
            }
          }
        }
        """
        let owner = try parse(text), cell = try owner.library.cell(named: "LATCH")
        let model = try #require(cell.sequentialModel)
        #expect(model.clockPin == nil)
        let checks = try #require(model.timingChecks)
        #expect(checks.count == 2 && checks[0].kind == .setup && checks[1].kind == .hold)
        // Decimal seconds are independent references; parsing and scaling may round by one ULP.
        func withinOneULP(_ actual: Double, of seconds: Double) -> Bool {
            actual >= seconds.nextDown && actual <= seconds.nextUp
        }
        #expect(try withinOneULP(checks[0].value(constrainedSlew: 0, relatedSlew: 0), of: -1e-10))
        #expect(cell.arcs.count == 2)
        let identities = try checks.map { try #require($0.sourceIdentity) } + cell.arcs.map { try #require($0.sourceIdentity) }
        #expect(identities.map(\.ordinal) == [0, 1, 2, 3])
        #expect(identities.map(\.timingType) == ["setup_falling", "hold_falling", "combinational", "rising_edge"])
        for identity in identities {
            #expect(identity.cell == "LATCH" && identity.line > 0)
            let suffix = String(decoding: Array(text.utf8).dropFirst(identity.byteOffset), as: UTF8.self)
            #expect(suffix.hasPrefix("timing"))
            #expect(!identity.tables.isEmpty)
            for table in identity.tables {
                let suffix = String(decoding: Array(text.utf8).dropFirst(table.byteOffset), as: UTF8.self)
                #expect(suffix.hasPrefix(table.name) && table.line > 0)
            }
        }
        let strictText = text
            .replacingOccurrences(of: "capacitive_load_unit(1,pf);", with: """
            capacitive_load_unit(1,pf);
            lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;index_1("0");index_2("0");}
            lu_table_template(c){variable_1:constrained_pin_transition;variable_2:related_pin_transition;index_1("0");index_2("0");}
            """)
            .replacingOccurrences(of: "direction:input;", with: "direction:input;capacitance:0.1;")
            .replacingOccurrences(of: "rise_constraint(t)", with: "rise_constraint(c)")
        func characterize(_ source: String) throws -> CharacterizedTimingLibrary {
            let bytes = Array(source.utf8)
            return try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["LATCH"],
                propagationCellNames: [], sequentialPropagationCellNames: ["LATCH"],
                limits: .init(maximumNestingDepth: 64), resources: LibertyCodecTestResources())
        }
        let strict = try characterize(strictText)
        let signed = try strict.evaluateCheck(cell: "LATCH", kind: .setup, constrainedPin: "D", relatedPin: "G",
            constrainedEdge: .rise, relatedEdge: .fall, constrainedSlew: 0, relatedSlew: 0)
        #expect(signed.result < 0 && withinOneULP(signed.result, of: -1e-10))
        try strict.validate(signed)
        #expect(try strict.evaluatePropagation(cell: "LATCH", fromPin: "D", toPin: "Q", edge: .rise,
            inputSlew: 0, outputLoad: 0).delay.result == 1e-9)
        #expect(try withinOneULP(strict.evaluatePropagation(cell: "LATCH", fromPin: "G", toPin: "Q", edge: .rise,
            inputSlew: 0, outputLoad: 0).delay.result, of: 3e-9))
        #expect(throws: LibertySourceError.self) {
            _ = try characterize(strictText.replacingOccurrences(of: "rise_constraint(c)", with: "rise_constraint(missing)"))
        }
    }
    @Test func duplicateFunctionalAttributesAndInvalidFlagsFailOwnedAdmission() throws {
        for text in [
            "library(L){cell(C){dont_use:maybe;}}",
            "library(L){cell(C){dont_use:true;dont_use:false;}}",
            "library(L){cell(C){pin(Y){direction:output;function:\"A\";function:\"B\";}}}",
            "library(L){cell(C){ff(Q,QN){power_down_function:\"A\";power_down_function:\"B\";}}}",
            "library(L){cell(C){ff(S,SN){clocked_on:\"C\";next_state:\"A\";next_state:\"B\";}}}"
        ] {
            #expect(throws: LibertySourceError.self) { try parse(text) }
        }
    }
    @Test func iterativeNestingAndCumulativeResourcesRefuseWithoutPartialPublication() throws {
        let nested = source(String(repeating: "(", count: 65) + "A" + String(repeating: ")", count: 65))
        #expect(throws: LibertySourceError.self) { try parse(nested, nesting: 64) }
        let prefixes = source(String(repeating: "!", count: 65) + "A")
        #expect(throws: LibertySourceError.self) { try parse(prefixes, nesting: 64) }
        let flat = source(Array(repeating: "A", count: 2000).joined(separator: " * "))
        let baseline = LibertyCodecTestResources()
        var owner: OwnedLibertySource? = try parse(flat, resources: baseline)
        let function = try #require(owner?.cells[0].pins[3].function)
        guard case .normalized(let facts) = function.content else { Issue.record("Flat function was not normalized"); return }
        #expect(facts.symbols == ["A"] && facts.operations.count == 3999)
        let work = baseline.work
        owner = nil
        #expect(baseline.liveBytes == 0 && baseline.temporaryBytes == 0)
        let limited = LibertyCodecTestResources(maximumWork: work - 1)
        do {
            _ = try parse(flat, resources: limited)
            Issue.record("Work exhaustion became an owned success")
        } catch LibertySourceError.resource(let cause) {
            #expect(cause as? LibertyCodecTestResources.Failure == .work)
        }
        #expect(limited.liveBytes == 0 && limited.temporaryBytes == 0)
        #expect(limited.reservationCount == limited.releaseCount)
    }
    @Test func functionalOwnersRetainReceiptsUntilLastCopy() throws {
        let resources = LibertyCodecTestResources()
        var owner: OwnedLibertySource? = try parse(source("!(A B)"), resources: resources)
        let retained = resources.liveBytes
        var copy = owner
        owner = nil
        #expect(resources.liveBytes == retained)
        #expect(copy?.cells[0].pins[3].function != nil)
        copy = nil
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }
}

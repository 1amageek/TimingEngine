import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import Testing
@testable import STAEngine
import TimingCore

@Suite("Source sequential execution helper", .timeLimit(.minutes(1)))
struct STASequentialExecutionTests: Sendable {
    private typealias Helper = NativeSTASequentialExecution
    private func owner(_ text: String) throws -> OwnedLibertySource {
        let bytes = Array(text.utf8)
        return try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 64), resources: STALibertyResources())
    }
    private func reference(_ character: String = "a") throws -> ArtifactReference {
        try .init(digest: .init(algorithm: .sha256, hexadecimalValue: String(repeating: character, count: 64)),
                  byteCount: 1, descriptor: .init(role: .input, kind: .netlist, format: .liberty))
    }
    private func plan(_ owner: OwnedLibertySource, name: String, work: inout UInt64,
                      limits: STAExecutionLimits? = nil, stateLimit: Int = 100_000) throws -> Helper.Plan {
        let cell = try owner.library.cell(named: name)
        return try Helper.compile(model: #require(cell.sequentialModel), source: owner.cells.first { $0.name == name },
                                  work: &work, limits: limits ?? .init(), stateBudget: .init(maximum: stateLimit))
    }
    private let enabledFF = """
    library(L){cell(FF){ff(IQ,IQN){next_state:"EN D + EN' IQ";clocked_on:"!CLK";clear:"!RN";preset:SN;}
      pin(CLK){direction:input;}pin(D){direction:input;}pin(EN){direction:input;}
      pin(RN){direction:input;}pin(SN){direction:input;}
      pin(Q){direction:output;function:IQ;}pin(QN){direction:output;function:IQN;}}}
    """
    @Test func enabledFFPreservesAllReferencedInputsAndExplicitFeedbackState() throws {
        let source = try owner(enabledFF)
        var work: UInt64 = 0
        let compiled = try plan(source, name: "FF", work: &work)
        #expect(compiled.kind == .flipFlop && compiled.clockPin == "CLK" && compiled.activeEdge == .fall)
        #expect(compiled.dataPins == ["EN", "D"] && compiled.controlPins == ["RN", "SN"])
        #expect(compiled.outputs.map(\.stateVariable) == ["IQ", "IQN"])
        for enabled in [false, true] { for data in [false, true] { for prior in [false, true] {
            let result = try Helper.evaluateNextState(plan: compiled,
                inputs: ["EN":enabled, "D":data, "RN":true, "SN":false], states: ["IQ":prior],
                work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
            #expect(result["IQ"] == (enabled ? data : prior))
            #expect(result["IQN"] == !(enabled ? data : prior))
        } } }
        #expect(throws: Helper.Failure.self) {
            _ = try Helper.evaluateNextState(plan: compiled, inputs: ["EN":true,"D":true,"RN":true,"SN":false],
                states: [:], work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        }
        #expect(throws: Helper.Failure.self) {
            _ = try Helper.requiredChecks(plan: compiled, pin: "EN", edge: .rise, work: &work, limits: .init())
        }
    }
    @Test func allDeclarationAndPinPowerDownFunctionsRequireExactExplicitFacts() throws {
        let parsed = try owner("""
        library(L){cell(FF){pg_pin(VPWR){pg_type:primary_power;}pg_pin(VGND){pg_type:primary_ground;}
          ff(S,SN){next_state:D;clocked_on:C;power_down_function:"!VPWR";}
          pin(C){direction:input;}pin(D){direction:input;}pin(Q){direction:output;function:S;power_down_function:"!VPWR + VGND";}}}
        """)
        let source = parsed.cells[0], artifact = try reference()
        let supplies = try [("VPWR","primary_power",TimingDesign.Constant.one), ("VGND","primary_ground",.zero)].map {
            try STAOperatingSupplyAssumption(instance: "u", cell: "FF", cornerID: "tt", library: artifact,
                                            pin: $0.0, sourcePGType: $0.1, value: $0.2)
        }
        var work: UInt64 = 0
        func validate(_ assumptions: [STAOperatingSupplyAssumption], _ library: ArtifactReference) throws -> Helper.NormalPowerReceipt {
            try Helper.validateNormalPower(source: parsed, cell: "FF", instance: "u", cornerID: "tt", library: library,
                assumptions: assumptions, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        }
        let receipt = try validate(supplies, artifact)
        #expect(receipt.functions.count == 2 && receipt.functions.allSatisfy { !$0.value })
        #expect(receipt.functions.map(\.byteOffset) == [source.sequential[0].powerDownFunction!.byteOffset, source.pins[2].powerDownFunction!.byteOffset])
        #expect(receipt.assumptions == supplies)
        #expect(throws: LibertyNormalPowerError.self) { _ = try validate([], artifact) }
        #expect(throws: LibertyNormalPowerError.self) { _ = try validate([supplies[0]], artifact) }
        #expect(throws: LibertyNormalPowerError.self) { _ = try validate(supplies + [supplies[0]], artifact) }
        #expect(throws: Helper.Failure.self) { _ = try validate(supplies, reference("b")) }
        let wrongKind = try STAOperatingSupplyAssumption(instance: "u", cell: "FF", cornerID: "tt", library: artifact,
            pin: "VPWR", sourcePGType: "primary_ground", value: .one)
        #expect(throws: LibertyNormalPowerError.self) { _ = try validate([wrongKind, supplies[1]], artifact) }
        let off = try STAOperatingSupplyAssumption(instance: "u", cell: "FF", cornerID: "tt", library: artifact,
            pin: "VPWR", sourcePGType: "primary_power", value: .zero)
        #expect(throws: LibertyNormalPowerError.self) { _ = try validate([off, supplies[1]], artifact) }
    }
    private var latchText: String {
        """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;index_1("0");index_2("0");}
          lu_table_template(c){variable_1:constrained_pin_transition;variable_2:related_pin_transition;index_1("0");index_2("0");}
          cell(LATCH){latch(S,SN){data_in:D;enable:G;}
            pin(D){direction:input;capacitance:0.1;
              timing(){related_pin:G;timing_type:setup_falling;rise_constraint(c){values("-0.1");}}
              timing(){related_pin:G;timing_type:hold_falling;rise_constraint(c){values("0.2");}}}
            pin(G){direction:input;capacitance:0.1;}
            pin(Q){direction:output;function:S;
              timing(){related_pin:D;timing_type:combinational;timing_sense:positive_unate;
                cell_rise(t){values("1");}cell_fall(t){values("2");}rise_transition(t){values("0.3");}fall_transition(t){values("0.4");}}
              timing(){related_pin:G;timing_type:rising_edge;timing_sense:non_unate;
                cell_rise(t){values("3");}cell_fall(t){values("4");}rise_transition(t){values("0.5");}fall_transition(t){values("0.6");}}}}}
        """
    }
    @Test func latchUsesActualDataAndGateArcsAcrossOpeningBorrowingAndDeferredWindows() throws {
        let text = latchText, parsed = try owner(text), bytes = Array(text.utf8)
        let characterized = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["LATCH"],
            propagationCellNames: [], sequentialPropagationCellNames: ["LATCH"],
            limits: .init(maximumNestingDepth: 64), resources: STALibertyResources())
        var work: UInt64 = 0
        let compiled = try plan(parsed, name: "LATCH", work: &work), cell = try parsed.library.cell(named: "LATCH")
        #expect(compiled.kind == .latch && compiled.clockPin == "G" && compiled.closeEdge == .fall)
        let window = Helper.Window(open: .init(edge: .rise, early: 2e-9, late: 2e-9, earlySlew: 0, lateSlew: 0),
            close: .init(edge: .fall, early: 7e-9, late: 7e-9, earlySlew: 0, lateSlew: 0), period: 10e-9)
        let cases: [(Double, String, Double, Double, Int)] = [(1e-9,"G",5e-9,0.0,0),
            (4e-9,"D",5e-9,2e-9,0), (8e-9,"G",15e-9,0.0,1)]
        for (time, pin, expectedArrival, borrow, cycle) in cases {
            let input = Helper.Transition(pin: "D", edge: .rise, early: time, late: time,
                                          earlySlew: 0, lateSlew: 0, parentRouteIndex: 17)
            let request = try Helper.requestLatch(plan: compiled, cell: cell, output: "Q", outputEdge: .rise,
                input: input, window: window, outputLoad: 0, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
            #expect(request.earlyCandidates[0].pin == pin && request.lateCandidates[0].pin == pin)
            #expect(abs(request.lateCandidates[0].borrowedTime - borrow) < 1e-23 && request.lateCandidates[0].cycle == cycle)
            let sample = try characterized.evaluatePropagation(cell: "LATCH", fromPin: pin, toPin: "Q", edge: .rise,
                                                               inputSlew: 0, outputLoad: 0)
            let result = try Helper.complete(request, earlySamples: [sample], lateSamples: [sample],
                earlyReceiptIndices: [9], lateReceiptIndices: [10], characterized: characterized,
                work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
            #expect(abs(result.late.arrival - expectedArrival) < 1e-23)
            #expect(result.causalInput.pin == "D" && result.late.request.parentRouteIndex == 17)
            #expect(result.early.receiptIndex == 9 && result.late.receiptIndex == 10)
        }
        let checks = try Helper.requiredChecks(plan: compiled, pin: "D", edge: .rise, work: &work, limits: .init())
        #expect(checks.map(\.kind) == [.setup, .hold] && checks.allSatisfy { $0.relatedEdge == .fall })
        let setup = try checks[0].value(constrainedSlew: 0, relatedSlew: 0)
        let expectedSetup = -0.1e-9
        #expect(setup < 0 && abs(setup - expectedSetup) <= expectedSetup.ulp)
        let data = try characterized.evaluatePropagation(cell: "LATCH", fromPin: "D", toPin: "Q", edge: .rise, inputSlew: 0, outputLoad: 0)
        let input = Helper.Transition(pin: "D", edge: .rise, early: 1e-9, late: 1e-9, earlySlew: 0, lateSlew: 0, parentRouteIndex: 0)
        let gateRequest = try Helper.requestLatch(plan: compiled, cell: cell, output: "Q", outputEdge: .rise,
            input: input, window: window, outputLoad: 0, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        #expect(throws: Helper.Failure.self) {
            _ = try Helper.complete(gateRequest, earlySamples: [data], lateSamples: [data], earlyReceiptIndices: [0],
                lateReceiptIndices: [1], characterized: characterized, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        }
    }
    @Test func enabledDataAndAsynchronousControlsRequireTheirOwnSourceCheckPairs() throws {
        var text = enabledFF
        for pin in ["D", "EN", "RN", "SN"] {
            let kinds = ["D", "EN"].contains(pin) ? ["setup_falling", "hold_falling"] : ["recovery_falling", "removal_falling"]
            let groups = kinds.map { "timing(){related_pin:CLK;timing_type:" + $0 + ";rise_constraint(c){values(\"0.1\");}}" }.joined()
            text = text.replacingOccurrences(of: "pin(" + pin + "){direction:input;}",
                with: "pin(" + pin + "){direction:input;" + groups + "}")
        }
        let parsed = try owner(text)
        var work: UInt64 = 0
        let compiled = try plan(parsed, name: "FF", work: &work)
        for pin in ["D", "EN", "RN", "SN"] {
            let checks = try Helper.requiredChecks(plan: compiled, pin: pin, edge: .rise, work: &work, limits: .init())
            #expect(checks.count == 2 && checks.allSatisfy { $0.constrainedPin == pin && $0.relatedPin == "CLK" })
            #expect(checks.map(\.kind) == (["D","EN"].contains(pin) ? [.setup,.hold] : [.recovery,.removal]))
        }
    }
    @Test func latchIntervalBoundsIncludeActualInteriorDataBranch() throws {
        let text = latchText, parsed = try owner(text), bytes = Array(text.utf8)
        let characterized = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["LATCH"],
            propagationCellNames: [], sequentialPropagationCellNames: ["LATCH"],
            limits: .init(maximumNestingDepth: 64), resources: STALibertyResources())
        var work: UInt64 = 0
        let compiled = try plan(parsed, name: "LATCH", work: &work), cell = try parsed.library.cell(named: "LATCH")
        let window = Helper.Window(open: .init(edge: .rise, early: 2e-9, late: 2e-9, earlySlew: 0, lateSlew: 0),
            close: .init(edge: .fall, early: 7e-9, late: 7e-9, earlySlew: 0, lateSlew: 0), period: 10e-9)
        let interval = Helper.Transition(pin: "D", edge: .rise, early: 1e-9, late: 6e-9,
            earlySlew: 0, lateSlew: 0, parentRouteIndex: 1)
        let request = try Helper.requestLatch(plan: compiled, cell: cell, output: "Q", outputEdge: .rise,
            input: interval, window: window, outputLoad: 0, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        let early = try request.earlyCandidates.map {
            try characterized.evaluatePropagation(cell: "LATCH", fromPin: $0.pin, toPin: "Q",
                edge: .rise, inputSlew: $0.inputSlew, outputLoad: 0)
        }
        let late = try request.lateCandidates.map {
            try characterized.evaluatePropagation(cell: "LATCH", fromPin: $0.pin, toPin: "Q",
                edge: .rise, inputSlew: $0.inputSlew, outputLoad: 0)
        }
        let result = try Helper.complete(request, earlySamples: early, lateSamples: late,
            earlyReceiptIndices: Array(early.indices), lateReceiptIndices: Array(late.indices),
            characterized: characterized, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        // Independent source-fixture arithmetic: 3 ns is inside the transparent window,
        // and its actual D-to-Q delay is 1 ns, so Q arrives at 4 ns.
        let interiorArrival = 3e-9 + 1e-9
        #expect(result.early.arrival <= interiorArrival)
        #expect(result.late.arrival >= interiorArrival)
        #expect(result.late.arrival >= 6e-9 + 1e-9)
    }
    @Test func overlappingDataAndAsyncControlConsumesTheUnionOfAllRequiredChecks() throws {
        var text = enabledFF.replacingOccurrences(of: "clear:\"!RN\"", with: "clear:\"!EN\"")
        let groups = ["setup_falling", "hold_falling", "recovery_falling", "removal_falling"].map {
            "timing(){related_pin:CLK;timing_type:" + $0 + ";rise_constraint(c){values(\"0.1\");}}"
        }.joined()
        text = text.replacingOccurrences(of: "pin(EN){direction:input;}", with: "pin(EN){direction:input;" + groups + "}")
        let parsed = try owner(text)
        var work: UInt64 = 0
        let compiled = try plan(parsed, name: "FF", work: &work)
        #expect(compiled.dataPins.contains("EN") && compiled.controlPins.contains("EN"))
        let checks = try Helper.requiredChecks(plan: compiled, pin: "EN", edge: .rise, work: &work, limits: .init())
        #expect(checks.map(\.kind) == [.setup,.hold,.recovery,.removal])
        #expect(checks.allSatisfy { $0.constrainedPin == "EN" && $0.relatedPin == "CLK" && $0.relatedEdge == .fall })
    }
    @Test func stateSlotsCannotBeSuppliedThroughThePhysicalInputCompartment() throws {
        let parsed = try owner(enabledFF)
        var work: UInt64 = 0
        let compiled = try plan(parsed, name: "FF", work: &work)
        #expect(throws: Helper.Failure.self) {
            _ = try Helper.evaluateNextState(plan: compiled,
                inputs: ["EN":false,"D":true,"RN":true,"SN":false,"IQ":false], states: [:],
                work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        }
        #expect(throws: Helper.Failure.self) {
            _ = try Helper.evaluateNextState(plan: compiled,
                inputs: ["EN":false,"D":true,"RN":true,"SN":false,"UNKNOWN":true], states: ["IQ":false],
                work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        }
        #expect(throws: Helper.Failure.self) {
            _ = try Helper.evaluateNextState(plan: compiled,
                inputs: ["EN":false,"D":true,"RN":true,"SN":false], states: ["IQ":false,"D":true],
                work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        }
    }
    @Test func signedPeriodicEnvelopesUseConstantCandidatesAndExplicitBoundaryLimits() throws {
        let text = latchText, parsed = try owner(text), bytes = Array(text.utf8)
        let characterized = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["LATCH"],
            propagationCellNames: [], sequentialPropagationCellNames: ["LATCH"],
            limits: .init(maximumNestingDepth: 64), resources: STALibertyResources())
        var work: UInt64 = 0
        let compiled = try plan(parsed, name: "LATCH", work: &work), cell = try parsed.library.cell(named: "LATCH")
        let window = Helper.Window(open: .init(edge: .rise, early: 2e-9, late: 2e-9, earlySlew: 0, lateSlew: 0),
            close: .init(edge: .fall, early: 7e-9, late: 7e-9, earlySlew: 0, lateSlew: 0), period: 10e-9)
        var requestWork: UInt64?
        for (a,b,expectedEarly,expectedLate) in [(-9e-9,-4e-9,-7e-9,-3e-9),
            (1e-9,6e-9,3e-9,7e-9), (-9e-9,1_000_000.0 * 10e-9 + 6e-9,-7e-9,1_000_000.0 * 10e-9 + 7e-9)] {
            let before = work
            let input = Helper.Transition(pin: "D", edge: .rise, early: a, late: b,
                earlySlew: 0, lateSlew: 0, parentRouteIndex: 3)
            let request = try Helper.requestLatch(plan: compiled, cell: cell, output: "Q", outputEdge: .rise,
                input: input, window: window, outputLoad: 0, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
            let used = work - before
            if let requestWork { #expect(used == requestWork) } else { requestWork = used }
            #expect(request.earlyCandidates.count == 2 && request.lateCandidates.count == 2)
            let early = try request.earlyCandidates.map { candidate in
                try characterized.evaluatePropagation(cell: "LATCH", fromPin: candidate.pin, toPin: "Q", edge: .rise,
                    inputSlew: candidate.inputSlew, outputLoad: candidate.outputLoad)
            }
            let late = try request.lateCandidates.map { candidate in
                try characterized.evaluatePropagation(cell: "LATCH", fromPin: candidate.pin, toPin: "Q", edge: .rise,
                    inputSlew: candidate.inputSlew, outputLoad: candidate.outputLoad)
            }
            let result = try Helper.complete(request, earlySamples: early, lateSamples: late,
                earlyReceiptIndices: [10,11], lateReceiptIndices: [12,13], characterized: characterized,
                work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
            #expect(abs(result.early.arrival - expectedEarly) < 1e-15)
            #expect(abs(result.late.arrival - expectedLate) < 1e-15)
            #expect(result.early.request.branch == .data && result.early.request.coordinateMeaning == .infimum)
            #expect(abs(result.early.appliedDelay - (result.early.arrival - a)) < 1e-23)
            #expect(abs(result.late.appliedDelay - (result.late.arrival - b)) < 1e-23)
            if a < 0 { #expect(result.early.request.cycle == -1) }
            if b > 1e-3 { #expect(result.late.request.cycle == 1_000_000) }
            #expect(throws: Helper.Failure.self) {
                _ = try Helper.complete(request, earlySamples: Array(early.prefix(1)), lateSamples: late,
                    earlyReceiptIndices: [10], lateReceiptIndices: [12,13], characterized: characterized,
                    work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
            }
        }
        let atClose = Helper.Transition(pin: "D", edge: .rise, early: 6e-9, late: 7e-9,
            earlySlew: 0, lateSlew: 0, parentRouteIndex: 3)
        let closeRequest = try Helper.requestLatch(plan: compiled, cell: cell, output: "Q", outputEdge: .rise,
            input: atClose, window: window, outputLoad: 0, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        let supremum = try #require(closeRequest.lateCandidates.first { $0.branch == .data })
        #expect(supremum.coordinateMeaning == .supremum && supremum.selectedInputCoordinate == 7e-9)
        #expect(closeRequest.lateCandidates.contains { $0.branch == .gate && $0.cycle == 1 })
        let preOpen = Helper.Transition(pin: "D", edge: .rise, early: 8e-9, late: 8e-9,
            earlySlew: 0, lateSlew: 0, parentRouteIndex: 3)
        let scaleRequest = try Helper.requestLatch(plan: compiled, cell: cell, output: "Q", outputEdge: .rise,
            input: preOpen, window: window, outputLoad: 0, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        let sample = try characterized.evaluatePropagation(cell: "LATCH", fromPin: "G", toPin: "Q", edge: .rise,
            inputSlew: 0, outputLoad: 0)
        let scaled = try Helper.complete(scaleRequest, earlySamples: [sample], lateSamples: [sample],
            earlyReceiptIndices: [0], lateReceiptIndices: [1], characterized: characterized, earlyCellScale: 2, lateCellScale: 2,
            work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        #expect(abs(scaled.late.arrival - 18e-9) < 1e-23)
        #expect(abs(scaled.late.request.waiting - 4e-9) < 1e-23)
        #expect(abs(scaled.late.rawDelay - 3e-9) < 1e-23)
    }
    @Test func explicitPGSlotsCannotBeInjectedThroughInputsOrStates() throws {
        let text = enabledFF.replacingOccurrences(of: "cell(FF){", with: "cell(FF){pg_pin(VPWR){pg_type:primary_power;}")
            .replacingOccurrences(of: "EN D + EN' IQ", with: "D VPWR + IQ VPWR'")
        let parsed = try owner(text)
        var work: UInt64 = 0
        let compiled = try plan(parsed, name: "FF", work: &work)
        let inputs = ["D":true,"EN":false,"RN":true,"SN":false]
        let result = try Helper.evaluateNextState(plan: compiled, inputs: inputs, states: ["IQ":false],
            powerValues: ["VPWR":true], work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        #expect(result["IQ"] == true)
        for (physical,states,power) in [(inputs.merging(["VPWR":true]) { _,new in new },["IQ":false],[:]),
            (inputs,["IQ":false,"VPWR":true],[:]), (inputs,["IQ":false],["D":true]),
            (inputs,["IQ":false],["VPWR":true,"UNKNOWN":false])] {
            #expect(throws: Helper.Failure.self) {
                _ = try Helper.evaluateNextState(plan: compiled, inputs: physical, states: states, powerValues: power,
                    work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
            }
        }
    }
    @Test func invertedLatchPolarityCloseBoundaryAndNonfiniteInputsAreExplicit() throws {
        let text = latchText.replacingOccurrences(of: "enable:G;", with: "enable:\"!G\";")
            .replacingOccurrences(of: "rising_edge", with: "falling_edge")
            .replacingOccurrences(of: "setup_falling", with: "setup_rising")
            .replacingOccurrences(of: "hold_falling", with: "hold_rising")
        let parsed = try owner(text), cell = try parsed.library.cell(named: "LATCH")
        var work: UInt64 = 0
        let compiled = try plan(parsed, name: "LATCH", work: &work)
        #expect(compiled.activeEdge == .fall && compiled.closeEdge == .rise)
        let window = Helper.Window(open: .init(edge: .fall, early: 2, late: 2, earlySlew: 0, lateSlew: 0),
            close: .init(edge: .rise, early: 7, late: 7, earlySlew: 0, lateSlew: 0), period: 10)
        let boundary = Helper.Transition(pin: "D", edge: .rise, early: 7, late: 7, earlySlew: 0, lateSlew: 0, parentRouteIndex: 1)
        let request = try Helper.requestLatch(plan: compiled, cell: cell, output: "Q", outputEdge: .rise,
            input: boundary, window: window, outputLoad: 0, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        #expect(request.lateCandidates[0].pin == "G" && request.lateCandidates[0].inputEdge == .fall && request.lateCandidates[0].releaseTime == 12)
        #expect(request.lateCandidates[0].waiting == 5 && request.lateCandidates[0].cycle == 1)
        let invalid = Helper.Transition(pin: "D", edge: .rise, early: .nan, late: 7, earlySlew: 0, lateSlew: 0, parentRouteIndex: 1)
        #expect(throws: Helper.Failure.self) {
            _ = try Helper.requestLatch(plan: compiled, cell: cell, output: "Q", outputEdge: .rise,
                input: invalid, window: window, outputLoad: 0, work: &work, limits: .init(), stateBudget: .init(maximum: 100_000))
        }
    }
    @Test func exactWorkLimitStateRefusalAndUnavailableSourceRemainFailures() throws {
        let parsed = try owner(enabledFF)
        var observed: UInt64 = 0
        _ = try plan(parsed, name: "FF", work: &observed)
        var exact: UInt64 = 0
        _ = try plan(parsed, name: "FF", work: &exact, limits: .init(maximumPathWorkUnits: observed))
        #expect(exact == observed)
        var short: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) {
            _ = try plan(parsed, name: "FF", work: &short, limits: .init(maximumPathWorkUnits: observed - 1))
        }
        var work: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) { _ = try plan(parsed, name: "FF", work: &work, stateLimit: 1) }
        let unsupported = try owner(enabledFF.replacingOccurrences(of: "clocked_on:\"!CLK\"", with: "clocked_on:\"CLK EN\""))
        #expect(throws: Helper.Failure.self) { _ = try plan(unsupported, name: "FF", work: &work) }
    }
    @Test func cancellationIsCheckedBeforePlanAdmission() async throws {
        let parsed = try owner(enabledFF)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var work: UInt64 = 0
            #expect(throws: CancellationError.self) { _ = try plan(parsed, name: "FF", work: &work) }
            #expect(work == 0)
        }
        await task.value
    }
}

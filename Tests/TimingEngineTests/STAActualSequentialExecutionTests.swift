import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import Testing
@testable import STAEngine
import TimingCore

/// This suite requires the original source path. It never reports an absent source as a pass.
@Suite("Actual Sky130 sequential helper", .timeLimit(.minutes(2)))
struct STAActualSequentialExecutionTests {
    @Test func originalDlxtpDfrtpDfxtpRetainPulseLawsPartialControlsAndConditionalState() throws {
        typealias Helper = NativeSTASequentialExecution
        let path = try #require(ProcessInfo.processInfo.environment["LSI_ACTUAL_SKY130_TT_LIBERTY"])
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let count = try #require(attributes[.size] as? NSNumber).uint64Value
        #expect(count <= 32 * 1_048_576)
        guard count <= 32 * 1_048_576 else { throw TimingError.invalidInput("Actual Liberty byte limit") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let digest = try SHA256ContentDigester().digest(data: data)
        #expect(digest.hexadecimalValue == "8e78e14442062dba34d414fca6490b2f6b96038d4510d1438ca44fee31487135")
        guard digest.hexadecimalValue == "8e78e14442062dba34d414fca6490b2f6b96038d4510d1438ca44fee31487135" else {
            throw TimingError.invalidInput("Required original source digest")
        }
        let reference = try ArtifactReference(digest: digest, byteCount: UInt64(data.count),
            descriptor: .init(role: .input, kind: .netlist, format: .liberty))
        let bytes = Array(data)
        let resources = STALibertyResources(maximumStorageBytes: 1_073_741_824,
            maximumWork: 1_000_000_000, maximumDuration: .seconds(90))
        let owner = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 64), resources: resources)
        let name = "sky130_fd_sc_hd__dlxtp_1", corner = "tt_025C_1v80"
        let source = try #require(owner.cells.first { $0.name == name })
        let cell = try owner.library.cell(named: name), model = try #require(cell.sequentialModel)
        let budget = NativeSTAStateBudget(maximum: 100_000), limits = try STAExecutionLimits()
        var work: UInt64 = 0
        let plan = try Helper.compile(model: model, source: source, work: &work, limits: limits, stateBudget: budget)
        #expect(plan.kind == .latch && plan.clockPin == "GATE" && plan.activeEdge == .rise && plan.closeEdge == .fall)
        #expect(plan.dataPins == ["D"] && plan.outputs.map(\.pin) == ["Q"])
        let supplies = try [("VPWR","primary_power",TimingDesign.Constant.one), ("VGND","primary_ground",.zero),
            ("VPB","nwell",.one), ("VNB","pwell",.zero)].map {
            try STAOperatingSupplyAssumption(instance: "latch", cell: name, cornerID: corner, library: reference,
                                            pin: $0.0, sourcePGType: $0.1, value: $0.2)
        }
        let receipt = try Helper.validateNormalPower(source: owner, cell: name, instance: "latch", cornerID: corner,
            library: reference, assumptions: supplies, work: &work, limits: limits, stateBudget: budget)
        #expect(receipt.assumptions == supplies && receipt.functions.count == 1)
        #expect(receipt.functions[0].pin == "Q" && receipt.functions[0].value == false)
        #expect(receipt.functions[0].byteOffset == source.pins.first { $0.name == "Q" }?.powerDownFunction?.byteOffset)
        #expect(throws: LibertyNormalPowerError.self) {
            _ = try Helper.validateNormalPower(source: owner, cell: name, instance: "latch", cornerID: corner,
                library: reference, assumptions: [], work: &work, limits: limits, stateBudget: budget)
        }
        let changed = try STAOperatingSupplyAssumption(instance: "latch", cell: name, cornerID: corner,
            library: reference, pin: "VPWR", sourcePGType: "primary_ground", value: .one)
        #expect(throws: LibertyNormalPowerError.self) {
            _ = try Helper.validateNormalPower(source: owner, cell: name, instance: "latch", cornerID: corner,
                library: reference, assumptions: [changed,supplies[1]], work: &work, limits: limits, stateBudget: budget)
        }
        let actualNames = [name,"sky130_fd_sc_hd__dfxtp_1","sky130_fd_sc_hd__dfrtp_1"]
        let characterized = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: actualNames,
            propagationCellNames: [], sequentialPropagationCellNames: actualNames,
            limits: .init(maximumNestingDepth: 64), resources: resources)
        let arcs = cell.arcs.filter { $0.toPin == "Q" && ["D","GATE"].contains($0.fromPin) }
        #expect(arcs.count == 2)
        let luts = arcs.flatMap { [$0.delayRise,$0.delayFall,$0.transitionRise,$0.transitionFall] }
        let slew = try #require(luts.map { $0.inputSlews[0] }.max())
        let load = try #require(luts.map { $0.outputLoads[0] }.max())
        let window = Helper.Window(open: .init(edge: .rise, early: 2e-9, late: 2e-9, earlySlew: slew, lateSlew: slew),
            close: .init(edge: .fall, early: 7e-9, late: 7e-9, earlySlew: slew, lateSlew: slew), period: 10e-9)
        var consumed: [String] = []
        for time in [1e-9,4e-9] {
            let input = Helper.Transition(pin: "D", edge: .rise, early: time, late: time,
                earlySlew: slew, lateSlew: slew, parentRouteIndex: 4)
            let request = try Helper.requestLatch(plan: plan, cell: cell, output: "Q", outputEdge: .rise,
                input: input, window: window, outputLoad: load, work: &work, limits: limits, stateBudget: budget)
            let sample = try characterized.evaluatePropagation(cell: name, fromPin: request.earlyCandidates[0].pin, toPin: "Q",
                edge: .rise, inputSlew: request.earlyCandidates[0].inputSlew, outputLoad: load)
            let result = try Helper.complete(request, earlySamples: [sample], lateSamples: [sample],
                earlyReceiptIndices: [0], lateReceiptIndices: [1], characterized: characterized,
                work: &work, limits: limits, stateBudget: budget)
            consumed.append(request.earlyCandidates[0].pin)
            #expect(result.late.rawDelay > 0 && result.late.outputSlew > 0)
            #expect(result.late.arrival == request.lateCandidates[0].releaseTime + sample.delay.result)
            #expect(result.causalInput.parentRouteIndex == 4)
        }
        #expect(consumed == ["GATE","D"])
        let checks = try Helper.requiredChecks(plan: plan, pin: "D", edge: .rise, work: &work, limits: limits)
        #expect(checks.map(\.kind) == [.setup,.hold] && checks.allSatisfy { $0.relatedEdge == .fall })
        for actual in actualNames {
            let laws = try characterized.pulseWidthConstraints(cell: actual)
            let expectedCount = actual == name ? 1 : actual.hasSuffix("dfrtp_1") ? 3 : 2
            #expect(laws.count == expectedCount)
            for law in laws {
                let identity = try #require(law.sourceIdentity)
                #expect(identity.line > 0 && identity.byteOffset > 0)
                #expect(law.relatedOutputPin == "Q" && law.relatedPin == law.pin)
                let sample = try characterized.evaluatePulseWidth(cell:actual,pin:law.pin,
                    openingEdge:law.openingEdge,sourceIdentity:identity,inputSlew:0.5e-9)
                let minimumSlew = try #require(sample.minimumSlew), maximumSlew = try #require(sample.maximumSlew)
                #expect(sample.inputSlew == 0.5e-9 && abs(minimumSlew - 0.01e-9) < 1e-25 && abs(maximumSlew - 1.5e-9) < 1e-24)
                #expect(abs(sample.result - 0.8333333e-9) < 1e-22)
                try characterized.validate(sample)
                #expect(throws:TimingCharacterizationError.self) {
                    try characterized.evaluatePulseWidth(cell:actual,pin:law.pin,
                        openingEdge:law.openingEdge,sourceIdentity:identity,inputSlew:2e-9)
                }
            }
        }
        let resetName = "sky130_fd_sc_hd__dfrtp_1"
        let resetCell = try owner.library.cell(named:resetName)
        let resetSource = try #require(owner.cells.first { $0.name == resetName })
        let resetPlan = try Helper.compile(model:try #require(resetCell.sequentialModel),source:resetSource,
            work:&work,limits:limits,stateBudget:budget)
        for value in [TimingDesign.Constant.one,.zero] {
            let state = try Helper.staticControls(plan:resetPlan,inputs:["RESET_B":value],powerValues:["VPWR":.one,"VGND":.zero],
                work:&work,limits:limits,stateBudget:budget,sourceResources:resources)
            #expect(state.effect == (value == .one ? .inactive : .clear))
            #expect(state.outputs == (value == .one ? [:] : ["Q":.zero]))
        }
        let controls = try characterized.directionalControlArcs(cell:resetName)
        let clear = try #require(controls.first { $0.fromPin == "RESET_B" && $0.toPin == "Q" })
        #expect(controls.count == 1 && clear.kind == .clear && clear.delayRise == nil && clear.transitionRise == nil)
        let delay = try #require(clear.delayFall), transition = try #require(clear.transitionFall)
        let controlSlew = max(delay.inputSlews[0],transition.inputSlews[0])
        let controlLoad = max(delay.outputLoads[0],transition.outputLoads[0])
        let actual = try characterized.evaluateDirectionalControl(cell:resetName,fromPin:"RESET_B",toPin:"Q",kind:.clear,
            outputEdge:.fall,sourceIdentity:clear.sourceIdentity,inputSlew:controlSlew,outputLoad:controlLoad)
        #expect(actual.delay.result > 0 && actual.outputSlew.result > 0)
        #expect(throws:TimingCharacterizationError.self) {
            try characterized.evaluateDirectionalControl(cell:resetName,fromPin:"RESET_B",toPin:"Q",kind:.clear,
                outputEdge:.rise,sourceIdentity:clear.sourceIdentity,inputSlew:controlSlew,outputLoad:controlLoad)
        }
    }
}

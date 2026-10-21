import Foundation
import Synchronization
import Testing
import TimingCore
@testable import STAEngine

@Suite("Strict clock and pulse payloads", .timeLimit(.minutes(1)))
struct NativeStrictNumericalPropagationTests {
    private enum Refusal: Error, Equatable { case capacity, work, cancelled }
    private final class Resources: LibertySourceResourceAccounting {
        struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var peak: UInt64 = 0; var work: UInt64 = 0; var cancelled = false }
        private let storage = Mutex(State())
        let maximum: UInt64
        let maximumWork: UInt64
        init(bytes: UInt64 = 64 * 1024 * 1024, work: UInt64 = 10_000_000) { maximum = bytes; maximumWork = work }
        var state: State { storage.withLock { $0 } }
        func cancel() { storage.withLock { $0.cancelled = true } }
        func check() throws { if state.cancelled { throw Refusal.cancelled } }
        func chargeWork(_ amount: UInt64) throws {
            try storage.withLock { state in
                guard amount <= maximumWork - state.work else { throw Refusal.work }; state.work += amount
            }
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            try storage.withLock { state in
                guard byteCount <= maximum - state.live - state.temporary else { throw Refusal.capacity }
                if kind == .liveOwnedBytes { state.live += byteCount } else { state.temporary += byteCount }
                state.peak = max(state.peak, state.live + state.temporary)
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                storage.withLock { state in
                    if kind == .liveOwnedBytes { state.live -= byteCount } else { state.temporary -= byteCount }
                }
            }
        }
    }
    private struct Fixture {
        let source: OwnedLibertySource
        let characterized: CharacterizedTimingLibrary
        let design: TimingDesign
        let cells: [TimingCell]
        let plans: [Int: NativeSTASequentialExecution.Plan]
        let constraints: TimingConstraintSet
        let limits: STAExecutionLimits
    }
    private func fixture() throws -> Fixture {
        let bytes = Array(STAPropagatedClockFixture.liberty(delay: 0.4).utf8)
        let original = STALibertyResources()
        let source = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 64), resources: original)
        let characterized = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["BUF", "FF"],
            propagationCellNames: ["BUF"], sequentialPropagationCellNames: ["FF"],
            limits: .init(maximumNestingDepth: 64), resources: original)
        let design = STAPropagatedClockFixture.design
        let cells = try design.instances.map { try source.library.cell(named: $0.cell) }
        let limits = try STAExecutionLimits(maximumPathStates: 1_000_000, maximumPathWorkUnits: 10_000_000)
        let budget = NativeSTAStateBudget(maximum: limits.maximumPathStates)
        var work: UInt64 = 0, plans: [Int: NativeSTASequentialExecution.Plan] = [:]
        for index in cells.indices {
            guard let model = cells[index].sequentialModel else { continue }
            plans[index] = try NativeSTASequentialExecution.compile(model: model,
                source: source.cells.first { $0.name == cells[index].name }, work: &work, limits: limits,
                stateBudget: budget, sourceResources: original)
        }
        return Fixture(source: source, characterized: characterized, design: design, cells: cells, plans: plans,
            constraints: try SDCParser().parse(Data(STAPropagatedClockFixture.sdc.utf8)), limits: limits)
    }

    @Test func characterizationUsesOriginalAccountantAndCopiedNamesKeepAdmission() throws {
        let fixture = try fixture(), resources = Resources()
        var retained: NativeSTAClockCharacterization?
        do {
            let legacy = try NativeSTAClockPropagation.characterizationCells(design: fixture.design,
                library: fixture.source.library, constraints: [fixture.constraints], plans: fixture.plans,
                resources: STALibertyResources(), delimiter: ":")
            let actual = try NativeSTAClockPropagation.characterizationCells(design: fixture.design,
                library: fixture.source.library, constraints: [fixture.constraints], plans: fixture.plans,
                resources: STALibertyResources(), delimiter: ":", transformResources: resources)
            #expect(actual.buffers == legacy.buffers && actual.sequential == legacy.sequential)
            #expect(actual.receivers.map(\.root) == legacy.receivers.map(\.root))
            #expect(actual.receivers.map(\.receiver) == ["L:CLK", "C:CLK"])
            #expect(resources.state.temporary == 0 && resources.state.live > 0 && resources.state.work > 0)
            retained = actual
        }
        #expect(retained?.buffers == ["BUF"] && resources.state.live > 0)
        retained = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func characterizationRefusesBeforeGrowthAndPreservesCallerRefusals() throws {
        let fixture = try fixture()
        for resources in [Resources(bytes: 0), Resources(work: 0)] {
            do {
                _ = try NativeSTAClockPropagation.characterizationCells(design: fixture.design,
                    library: fixture.source.library, constraints: [fixture.constraints], plans: fixture.plans,
                    resources: STALibertyResources(), delimiter: ":", transformResources: resources)
                Issue.record("Resource refusal unexpectedly published a clock inventory")
            } catch let error as Refusal { #expect(error == .capacity || error == .work) }
            #expect(resources.state.live == 0 && resources.state.temporary == 0)
        }
        let cancelled = Resources(); cancelled.cancel()
        #expect(throws: Refusal.cancelled) {
            _ = try NativeSTAClockPropagation.characterizationCells(design: fixture.design,
                library: fixture.source.library, constraints: [fixture.constraints], plans: fixture.plans,
                resources: STALibertyResources(), delimiter: ":", transformResources: cancelled)
        }
        #expect(cancelled.state.live == 0 && cancelled.state.temporary == 0)
    }

    @Test func typedSegmentCopiesKeepExactPhysicalIdentityAndReleaseScratch() throws {
        let resources = Resources(), budget = NativeSTAStateBudget(maximum: 1000, transformResources: resources)
        var retained: NativeSTAClockEvent?
        let clock = TimingConstraintSet.Clock(name: "clk", source: "clk", period: 20e-9)
        do {
            let first = try NativeSTAClockPropagation.appendSegment([], text: nil, prefix: "wire:", first: "net-α",
                second: "I:CLK", edge: .rise, late: 2, early: 1, budget: budget)
            let second = try NativeSTAClockPropagation.appendSegment(first.segments, text: first.text,
                prefix: "cell:", first: "B", second: "A", third: "Y", edge: .fall, late: 4, early: 3, budget: budget)
            retained = .init(clock: clock, edge: .fall, rootEdge: .rise, rootPhase: 0,
                late: 6, early: 4, lateSlew: 1, earlySlew: 1, segments: second.segments,
                segmentPayload: second.payload, textRetention: second.text)
            #expect(second.segments.map(\.physicalIdentity) == ["wire:net-α:I:CLK:rise", "cell:B:A:Y:fall"])
            #expect(first.segments.count == 1 && first.segments[0].lateDelay == 2)
        }
        #expect(retained?.segments.count == 2 && resources.state.live > 0 && resources.state.temporary == 0)
        retained = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
        let rejected = Resources(bytes: 0)
        #expect(throws: Refusal.capacity) {
            _ = try NativeSTAClockPropagation.appendSegment([], text: nil, prefix: "wire:", first: "n", second: "s",
                edge: .rise, late: 1, early: 1, budget: .init(maximum: 1000, transformResources: rejected))
        }
        #expect(rejected.state.live == 0)
    }

    private func pulse(_ fixture: Fixture, resources: Resources?) throws -> NativeSTAControlPulsePropagation {
        let budget = NativeSTAStateBudget(maximum: fixture.limits.maximumPathStates, transformResources: resources)
        let pulse = try STAControlPulseSource(modeID: "functional", sourcePort: "clk", referenceClock: "clk",
            period: 20e-9, risePhase: 1e-9, fallPhase: 11e-9, riseTransition: 0.2e-9, fallTransition: 0.3e-9)
        var work: UInt64 = 0, evidence: NativeSTASourceEvidence?, rc: NativeSTADistributedRC?, conservative: NativeSTAConservativeWires?
        return try .init(design: fixture.design, cells: fixture.cells, source: fixture.source,
            plans: [:], sources: [pulse], constants: [:], loads: ["leaf": 0], characterized: fixture.characterized,
            variation: .init(), mode: "functional", delimiter: ":", resources: resources, limits: fixture.limits,
            budget: budget, evidence: &evidence, rc: &rc, conservative: &conservative, work: &work)
    }
    @Test func actualBufferedControlPulseRetainsBothEdgesWithoutChangingLegacyValues() throws {
        let fixture = try fixture(), resources = Resources()
        var retained: NativeSTATransformRetention?
        do {
            let legacy = try pulse(fixture, resources: nil)
            var actual = try pulse(fixture, resources: resources)
            let expected = try #require(legacy.receiver(net: "leaf", sink: "L:CLK"))
            let observed = try #require(actual.receiver(net: "leaf", sink: "L:CLK"))
            #expect(observed.rise.early == expected.rise.early && observed.fall.late == expected.fall.late)
            #expect(observed.rise.segments == expected.rise.segments && observed.fall.segments == expected.fall.segments)
            #expect(observed.rise.segments.count == 1 && observed.rise.segments[0].physicalIdentity == "control-cell:B:rise")
            retained = try actual.finishTransformRetention()
            #expect(resources.state.live > 0 && resources.state.temporary == 0)
        }
        #expect(retained != nil && resources.state.live > 0)
        retained = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
        let cancelled = Resources(); cancelled.cancel()
        #expect(throws: Refusal.cancelled) { _ = try pulse(fixture, resources: cancelled) }
        #expect(cancelled.state.live == 0 && cancelled.state.temporary == 0)
    }
    private func clocks(_ fixture: Fixture, resources: Resources?) throws -> NativeSTAClockPropagation {
        let budget = NativeSTAStateBudget(maximum: fixture.limits.maximumPathStates, transformResources: resources)
        var work: UInt64 = 0
        var rc: NativeSTADistributedRC? = try .init(options: STAPropagatedClockFixture.options,
            limits: fixture.limits, parasitics: SPEFParser().parse(Data(STAPropagatedClockFixture.spef.utf8)),
            design: fixture.design, cells: fixture.cells, source: fixture.source,
            sourceResources: resources, stateBudget: budget, mode: "functional", corner: "test", initialSteps: 0, work: &work)
        var conservative: NativeSTAConservativeWires?, evidence: NativeSTASourceEvidence?
        return try .init(design: fixture.design, cells: fixture.cells, source: fixture.source,
            constraints: fixture.constraints, sequentialPlans: fixture.plans, normalPowerValidated: true,
            sourceEvidence: &evidence, loads: ["leaf": 0], characterized: fixture.characterized,
            sourceResources: resources, stateBudget: budget, variation: .init(), limits: fixture.limits,
            delimiter: ":", mode: "functional", corner: "test", rc: &rc, conservative: &conservative, work: &work)
    }
    @Test func actualPropagatedClockKeepsLegacyArrivalPhaseAndFinalObservationLease() throws {
        let fixture = try fixture(), resources = Resources(work: 100_000_000)
        var retained: NativeSTATransformRetention?
        do {
            let legacy = try clocks(fixture, resources: nil)
            var actual = try clocks(fixture, resources: resources)
            #expect(actual.observations == legacy.observations && actual.observations.count == 4)
            let rise = try #require(actual.leaves["L"]?.rise)
            #expect(rise.rootEdge == .rise && rise.rootPhase == fixture.constraints.clocks[0].waveform[0])
            #expect(rise.segments.map(\.physicalIdentity) == ["wire:root:B:A:rise", "cell:B:A:Y:rise", "wire:leaf:L:CLK:rise"])
            retained = try actual.finishTransformRetention()
            #expect(resources.state.live > 0 && resources.state.temporary == 0)
        }
        #expect(retained != nil && resources.state.live > 0)
        retained = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

}

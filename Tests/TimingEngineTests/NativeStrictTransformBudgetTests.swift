import Foundation
import Synchronization
import Testing
import TimingCore
@testable import STAEngine

@Suite("Native strict transform budget ownership", .timeLimit(.minutes(1)))
struct NativeStrictTransformBudgetTests {
    private enum Refusal: Error, Equatable { case work, storage, cancelled }
    private final class Resources: LibertySourceResourceAccounting {
        struct State { var work: UInt64 = 0; var live: UInt64 = 0; var temporary: UInt64 = 0; var cancelled = false; var reservations = 0; var releases = 0; var remainingWork: UInt64? = nil }
        private let storage = Mutex(State())
        let maximumWork: UInt64
        let maximumBytes: UInt64
        let cancelAfterReserve: Bool
        init(work: UInt64 = 100, bytes: UInt64 = 1024, cancelAfterReserve: Bool = false) {
            maximumWork = work; maximumBytes = bytes; self.cancelAfterReserve = cancelAfterReserve
        }
        var state: State { storage.withLock { $0 } }
        func stopWork() { storage.withLock { $0.remainingWork = 0 } }
        func cancel() { storage.withLock { $0.cancelled = true } }
        func check() throws { if state.cancelled { throw Refusal.cancelled } }
        func chargeWork(_ amount: UInt64) throws {
            try storage.withLock { state in
                guard amount <= maximumWork - state.work else { throw Refusal.work }
                if let remaining = state.remainingWork {
                    guard amount <= remaining else { throw Refusal.work }
                    state.remainingWork = remaining - amount
                }
                state.work += amount
            }
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            try storage.withLock { state in
                guard byteCount <= maximumBytes - state.live - state.temporary else { throw Refusal.storage }
                if kind == .liveOwnedBytes { state.live += byteCount } else { state.temporary += byteCount }
                state.reservations += 1
                if cancelAfterReserve { state.cancelled = true }
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                storage.withLock { state in
                    if kind == .liveOwnedBytes { state.live -= byteCount } else { state.temporary -= byteCount }
                    state.releases += 1
                }
            }
        }
    }
    @Test func concreteStrideAndCopiesOwnOneReservationUntilFinalRelease() throws {
        let resources = Resources()
        let budget = NativeSTAStateBudget(maximum: 1, transformResources: resources)
        var original = try budget.reservePayload(UInt64.self, capacity: 7, kind: .liveOwnedBytes)
        #expect(resources.state.live == UInt64(7 * MemoryLayout<UInt64>.stride))
        // Payload admission does not spend the independent logical state-slot allowance.
        try budget.reserve(1)
        #expect(throws: STAPathAnalysisError.self) { try budget.reserve(1) }
        var copy = original; original = nil
        #expect(resources.state.live == 56 && resources.state.releases == 0)
        withExtendedLifetime(copy) {}
        copy = nil
        #expect(resources.state.live == 0 && resources.state.reservations == resources.state.releases)
    }
    @Test func cumulativeWorkHasNoScenarioResetAndRefusalDoesNotRefundWork() throws {
        let resources = Resources(work: 10)
        let first = NativeSTAStateBudget(maximum: 10, transformResources: resources)
        let second = NativeSTAStateBudget(maximum: 10, transformResources: resources)
        try first.chargeScheduledWork(4)
        try second.chargeScheduledWork(6)
        #expect(throws: Refusal.work) { try first.chargeScheduledWork(1) }
        #expect(resources.state.work == 10)
    }
    @Test func preGrowthCapacityOverflowAndPostReservationCancellationRefund() throws {
        let small = Resources(bytes: 7)
        let budget = NativeSTAStateBudget(maximum: 10, transformResources: small)
        #expect(throws: Refusal.storage) { try budget.reservePayload(UInt64.self, capacity: 1, kind: .temporaryBytes) }
        #expect(small.state.reservations == 0 && small.state.temporary == 0)
        do {
            try budget.reservePayload(UInt64.self, capacity: Int.max, kind: .temporaryBytes)
            Issue.record("Overflowing payload capacity was admitted")
        } catch LibertySourceError.arithmeticOverflow {
        } catch {
            Issue.record("Unexpected payload overflow failure: \(error)")
        }
        #expect(small.state.reservations == 0)
        let cancelled = Resources(cancelAfterReserve: true)
        let interrupted = NativeSTAStateBudget(maximum: 10, transformResources: cancelled)
        #expect(throws: Refusal.cancelled) {
            try interrupted.reservePayload(UInt64.self, capacity: 1, kind: .temporaryBytes)
        }
        #expect(cancelled.state.temporary == 0 && cancelled.state.reservations == cancelled.state.releases)
    }
    @Test func nilControlRetainsLegacyPolicyAndAddsNoPayloadOwner() throws {
        let legacy = NativeSTAStateBudget(maximum: 1)
        let lease = try legacy.reservePayload(UInt64.self, capacity: 10, kind: .temporaryBytes)
        #expect(lease == nil)
        try legacy.chargeScheduledWork(UInt64.max)
        try legacy.reserve(1)
        #expect(throws: STAPathAnalysisError.self) { try legacy.reserve(1) }
    }
    @Test func immutablePayloadAndResultCopiesKeepReservationsWithoutChangingSemanticsOrJSON() throws {
        let resources = Resources(work: 10_000, bytes: 65_536)
        var retainedCopy: STAPayload?
        let plain = STAPayload(worstSetupSlack: 1, worstHoldSlack: nil, analyzedCorners: ["tt"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(plain)
        do {
            let builder = NativeSTATransformStorage(budget: .init(maximum: 10, transformResources: resources), kind: .liveOwnedBytes)
            try builder.reserve(Double.self, capacity: 4)
            var payload = plain
            payload.transformRetention = try builder.finish()
            #expect(payload == plain && payload.hashValue == plain.hashValue)
            #expect(try encoder.encode(payload) == expected)
            retainedCopy = payload
        }
        #expect(resources.state.live > 0)
        let decoded = try JSONDecoder().decode(STAPayload.self, from: expected)
        #expect(decoded == retainedCopy)
        withExtendedLifetime(retainedCopy) {}
        retainedCopy = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func growingArrayReleasesReplacedBufferAndRetainsOnlyTheLastPublishedCopy() throws {
        let resources = Resources(work: 10_000, bytes: 65_536)
        var retainedCopy: NativeSTATransformRetention?
        do {
            let storage = NativeSTATransformStorage(budget: .init(maximum: 100, transformResources: resources), kind: .liveOwnedBytes)
            var values: [UInt64] = []
            for value in 0..<17 { try storage.append(UInt64(value), to: &values, site: 1) }
            #expect(values == Array(0..<17).map(UInt64.init))
            // Five geometric replacements have completed, so obsolete payload leases are gone.
            #expect(resources.state.releases >= 4)
            retainedCopy = try storage.finish()
            let work = resources.state.work
            do {
                try storage.append(18, to: &values, site: 1)
                Issue.record("Finished storage accepted another append")
            } catch LibertySourceError.invalidCapacity {
            } catch {
                Issue.record("Unexpected finished-storage failure: \(error)")
            }
            #expect(resources.state.work == work && values.count == 17)
        }
        #expect(resources.state.live > 0 && resources.state.temporary == 0)
        withExtendedLifetime(retainedCopy) {}; retainedCopy = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func actualMultiCornerGraphMatchesLegacyAndUsesOneCumulativeLedger() async throws {
        let fixture = try STAProcessTestFixture()
        let resources = Resources(work: 100_000_000, bytes: 16_777_216)
        var lastResult: STAExecutionResult?
        do {
            let engine = NativeSTAEngine(reader: fixture.reader)
            let legacy = try await engine.prepare(fixture.request, resources: .init(reader: fixture.reader,
                sourceLimits: .init(maximumNestingDepth: 64), sourceResources: resources, limits: .init()))
            let baseline = try await engine.execute(legacy)
            let controlled = try PreparedSTAExecution(request: legacy.request, design: legacy.design,
                processInputs: legacy.processInputs, constraints: legacy.constraints, parasitics: legacy.parasitics,
                parasiticSource: legacy.parasiticSource, modeIDs: legacy.modeIDs, catalog: legacy.inspectedSources,
                configuration: legacy.effectiveConfiguration, characterization: legacy.characterization,
                sourceResources: resources, clockCharacterization: legacy.clockCharacterization,
                limits: legacy.limits, transformResources: resources)
            let before = resources.state.work
            let result = try await engine.execute(controlled)
            #expect(result.payload == baseline.payload && result.payload.analyzedCorners.count == 2)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let actualJSON = try encoder.encode(result.payload)
            let legacyJSON = try encoder.encode(baseline.payload)
            #expect(actualJSON == legacyJSON)
            #expect(resources.state.work > before && resources.state.live > 0)
            var detached = result; detached.transformRetention = nil
            #expect(detached == result && detached.hashValue == result.hashValue)
            let detachedJSON = try encoder.encode(detached)
            let resultJSON = try encoder.encode(result)
            #expect(detachedJSON == resultJSON)
            lastResult = result
            let charged = resources.state.work
            resources.stopWork()
            do {
                _ = try await engine.execute(controlled)
                Issue.record("A second graph operation reset the shared caller allowance")
            } catch STAExecutionError.underlying(let cause) {
                let wrapped = try #require(cause as? TimingControlledTransformFailure)
                #expect((wrapped.cause as? Refusal) == .work)
            }
            #expect(resources.state.work == charged)
        }
        #expect(resources.state.live > 0)
        withExtendedLifetime(lastResult) {}; lastResult = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func actualCharacterizedMatchingSpendsSourceWorkWithoutTemporaryMatchArrays() throws {
        let resources = Resources(work: 1_000_000, bytes: 1_048_576)
        do {
            let text = """
            library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
              lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;
                index_1("1,3");index_2("2,6");}
              cell(CELL){pin(A){direction:input;capacitance:0.25;}
                pin(Y){direction:output;function:A;timing(){related_pin:A;timing_sense:positive_unate;
                  cell_rise(t){values("2,6","8,12");}cell_fall(t){values("10,30","40,60");}
                  rise_transition(t){values("1,5","7,11");}fall_transition(t){values("2,6","8,12");}}}}}
            """
            let bytes = Array(text.utf8)
            let library = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["CELL"],
                propagationCellNames: ["CELL"], limits: .init(maximumNestingDepth: 16), resources: resources)
            let before = resources.state.work
            let sample = try library.evaluatePropagation(cell: "CELL", fromPin: "A", toPin: "Y", edge: .rise,
                inputSlew: 1e-9, outputLoad: 2e-12)
            #expect(sample.delay.result == 2e-9 && sample.outputSlew.result == 1e-9)
            try library.validate(sample.delay); try library.validate(sample.outputSlew)
            #expect(resources.state.work > before)
            let reservations = resources.state.reservations
            let work = resources.state.work
            resources.stopWork()
            #expect(throws: Refusal.work) {
                _ = try library.evaluatePropagation(cell: "CELL", fromPin: "A", toPin: "Y", edge: .rise,
                    inputSlew: 1e-9, outputLoad: 2e-12)
            }
            #expect(resources.state.work == work && resources.state.reservations == reservations)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

}

import Foundation
import Synchronization
import Testing
import TimingCore
@testable import STAEngine

@Suite("Strict numerical payload owners", .timeLimit(.minutes(1)))
struct NativeStrictNumericalPayloadTests {
    private enum Refusal: Error, Equatable { case storage, work, cancelled }
    private final class Resources: LibertySourceResourceAccounting {
        struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0; var cancelled = false; var peak: UInt64 = 0 }
        private let storage = Mutex(State())
        private let callback = Mutex<(@Sendable () throws -> Void)?>(nil)
        let maximum: UInt64
        let maximumWork: UInt64
        init(bytes: UInt64 = 1_000_000, work: UInt64 = 1_000_000) { maximum = bytes; maximumWork = work }
        var state: State { storage.withLock { $0 } }
        func check() throws {
            if state.cancelled { throw Refusal.cancelled }
            let next = callback.withLock { value in let next = value; value = nil; return next }
            try next?()
        }
        func onNextCheck(_ body: @escaping @Sendable () throws -> Void) { callback.withLock { $0 = body } }
        func cancel() { storage.withLock { $0.cancelled = true } }
        func chargeWork(_ amount: UInt64) throws {
            try storage.withLock { state in
                guard amount <= maximumWork - state.work else { throw Refusal.work }
                state.work += amount
            }
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            try storage.withLock { state in
                guard byteCount <= maximum - state.live - state.temporary else { throw Refusal.storage }
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
    private final class Rendezvous: Sendable {
        private struct State { var ownerEntered = false; var releaseOwner = false; var waiterReady = false; var releaseCheck = false; var finished = 0; var failures: [String] = []; var waiterBody = false }
        private let state = Mutex(State())
        private let wake = NSCondition()
        private func update(_ body: (inout State) -> Void) {
            wake.lock(); state.withLock { value in body(&value) }; wake.broadcast(); wake.unlock()
        }
        private func wait(_ predicate: (State) -> Bool) throws {
            let deadline = Date().addingTimeInterval(10)
            wake.lock(); defer { wake.unlock() }
            while !state.withLock({ predicate($0) }) {
                guard wake.wait(until: deadline) else { throw Refusal.cancelled }
            }
        }
        func enterOwner() throws { update { $0.ownerEntered = true }; try wait { $0.releaseOwner } }
        func ownerIsReady() throws { try wait { $0.ownerEntered } }
        func beforeWaiterAcquire() throws { update { $0.waiterReady = true }; try wait { $0.releaseCheck } }
        func waiterIsReady() throws { try wait { $0.waiterReady } }
        func release() { update { $0.releaseCheck = true; $0.releaseOwner = true } }
        func finish(_ error: String? = nil) { update { $0.finished += 1; if let error { $0.failures.append(error) } } }
        func bodyEntered() { update { $0.waiterBody = true } }
        func result() throws -> (failures: [String], waiterBody: Bool) {
            try wait { $0.finished == 2 }
            return state.withLock { ($0.failures, $0.waiterBody) }
        }
    }
    private final class WaitingResources: LibertySourceResourceAccounting {
        private struct State { var checks = 0; var cancelled = false }
        private let state = Mutex(State())
        let rendezvous: Rendezvous
        init(_ rendezvous: Rendezvous) { self.rendezvous = rendezvous }
        func cancel() { state.withLock { $0.cancelled = true } }
        func check() throws {
            let checks = try state.withLock { state in
                guard !state.cancelled else { throw Refusal.cancelled }
                state.checks += 1; return state.checks
            }
            // Two work checks, two prepaid-diagnostic checks, then the metadata post-check precede acquire.
            if checks == 6 { try rendezvous.beforeWaiterAcquire() }
        }
        func chargeWork(_ amount: UInt64) throws {}
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            .init(kind: kind, byteCount: byteCount) {}
        }
    }
    private func numerical(_ resources: Resources?) throws -> NativeSTAConservativeNumerics {
        let limits = try STAExecutionLimits(maximumPathStates: 1_000_000, maximumPathWorkUnits: 1_000_000)
        return .init(limits: limits, budget: .init(maximum: limits.maximumPathStates, transformResources: resources), resources: nil)
    }
    @Test func denseCopyAdmitsCoexistingWritableStorageAndFinalCopyKeepsOwner() throws {
        let resources = Resources()
        let n = try numerical(resources)
        var original: NativeSTAConservativeNumerics.Matrix? = try n.matrix(2, 2)
        original![0, 0] = try TimingNumericInterval(point: 2)
        let bytes = UInt64(4 * MemoryLayout<TimingNumericInterval>.stride)
        #expect(resources.state.live == bytes)
        var copied: NativeSTAConservativeNumerics.Matrix? = try n.copy(original!)
        #expect(resources.state.live == bytes * 2)
        copied![0, 0] = try TimingNumericInterval(point: 7)
        #expect(original![0, 0].lowerBound == 2)
        #expect(copied![0, 0].lowerBound == 7)
        original = nil
        #expect(resources.state.live == bytes)
        var final = copied; copied = nil
        #expect(resources.state.live == bytes)
        withExtendedLifetime(final) {}
        final = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
        #expect(resources.state.work == 8)
    }
    @Test func sparseSharedCoordinatesAndIndependentValuesReleaseAtLastOwner() throws {
        let resources = Resources()
        do {
            let n = try numerical(resources), s = NativeSTAConservativeSparseNumerics(numerical: n)
            var work: UInt64 = 0
            let one = try TimingNumericInterval(point: 1)
            var original: NativeSTAConservativeSparseNumerics.CSR? = try s.fromRows([[0: one], [1: one]], columns: 2, work: &work)
            let coordinateBytes = UInt64(5 * MemoryLayout<Int>.stride)
            let valueBytes = UInt64(2 * MemoryLayout<TimingNumericInterval>.stride)
            #expect(resources.state.live == coordinateBytes + valueBytes)
            var negative: NativeSTAConservativeSparseNumerics.CSR? = try s.negated(original!, work: &work)
            #expect(resources.state.live == coordinateBytes + valueBytes * 2)
            original = nil
            #expect(resources.state.live == coordinateBytes + valueBytes)
            #expect(negative!.values[0].lowerBound == -1)
            withExtendedLifetime(negative) {}
            negative = nil
            #expect(resources.state.live == 0 && resources.state.temporary == 0)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }
    @Test func refusalPrecedesDenseGrowthAndMidpointScratchRefundsOnWorkFailure() throws {
        let small = Resources(bytes: 1)
        #expect(throws: Refusal.storage) { try numerical(small).matrix(2, 2) }
        #expect(small.state.live == 0 && small.state.temporary == 0)
        let limited = Resources(work: 4)
        do {
            let n = try numerical(limited)
            let a = try n.matrix(2, 2)
            let before = limited.state.live
            var work: UInt64 = 0
            #expect(throws: Refusal.work) { try n.inverseCandidate(a, work: &work) }
            #expect(limited.state.temporary == 0 && limited.state.live == before)
            limited.cancel()
            #expect(throws: Refusal.cancelled) { try n.matrix(1, 1) }
        }
        #expect(limited.state.live == 0 && limited.state.temporary == 0)
    }
    @Test func strictAndLegacyDenseArithmeticHaveIdenticalIntervals() throws {
        let resources = Resources()
        do {
            let strict = try numerical(resources), legacy = try numerical(nil)
            var strictWork: UInt64 = 0, legacyWork: UInt64 = 0
            var a = try strict.matrix(2, 2), b = try legacy.matrix(2, 2)
            for (index, value) in [2.0, 0.5, 0.5, 3.0].enumerated() {
                a.values[index] = try .init(point: value); b.values[index] = try .init(point: value)
            }
            let actual = try strict.solve(a, strict.identity(2, work: &strictWork), work: &strictWork)
            let expected = try legacy.solve(b, legacy.identity(2, work: &legacyWork), work: &legacyWork)
            #expect(actual.values == expected.values)
            #expect(strictWork == legacyWork)
            #expect(resources.state.temporary == 0)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }
    @Test func synchronousNativeReentryRefusesAndOuterRouteRemainsUsable() throws {
        let resources = Resources()
        let n = try numerical(resources)
        var work: UInt64 = 0
        let (_, statistics) = try NativeSTAConservativeNativeAllocation.withLease(dimension: 1, nonzeros: 1,
            numerical: n, policy: .init(quotaBytes: 4096, recordCapacity: 16), work: &work) { work in
            resources.onNextCheck {
                let limits = try STAExecutionLimits(maximumPathStates: 1_000_000)
                let nested = NativeSTAConservativeNumerics(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: nil)
                var nestedWork: UInt64 = 0
                do {
                    _ = try NativeSTAConservativeNativeAllocation.withLease(dimension: 1, nonzeros: 1,
                        numerical: nested, policy: .init(quotaBytes: 4096, recordCapacity: 16), work: &nestedWork) { _ in
                        Issue.record("Recursive native route entered its body")
                    }
                    Issue.record("Recursive native route unexpectedly succeeded")
                } catch let error as NativeSTAConservativeCouplingError {
                    guard case .nativeBackendFailure(let message) = error else { throw error }
                    #expect(message == "recursive native allocation lease")
                }
            }
            try n.tick(&work, 0)
            try NativeSTAConservativeNativeAllocation.check()
        }
        #expect(statistics.outstandingAllocations == 0)
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
        _ = try NativeSTAConservativeNativeAllocation.withLease(dimension: 1, nonzeros: 1,
            numerical: n, policy: .init(quotaBytes: 4096, recordCapacity: 16), work: &work) { _ in
            try NativeSTAConservativeNativeAllocation.check()
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test(arguments: [false, true])
    func independentNativeCallsSerializeAndCancelledWaiterCannotEnter(cancel: Bool) throws {
        let rendezvous = Rendezvous()
        // Each run owns its coordination and resources; suites share no mutable fixture.
        let waiterResources = WaitingResources(rendezvous)
        let owner = Thread {
            do {
                let limits = try STAExecutionLimits(maximumPathStates: 100_000)
                let n = NativeSTAConservativeNumerics(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: nil)
                var work: UInt64 = 0
                _ = try NativeSTAConservativeNativeAllocation.withLease(dimension: 1, nonzeros: 1,
                    numerical: n, policy: .init(quotaBytes: 4096, recordCapacity: 16), work: &work) { _ in
                    try rendezvous.enterOwner()
                    try NativeSTAConservativeNativeAllocation.check()
                }
                rendezvous.finish()
            } catch { rendezvous.finish(String(describing: error)) }
        }
        owner.start()
        try rendezvous.ownerIsReady()
        let waiter = Thread {
            do {
                let limits = try STAExecutionLimits(maximumPathStates: 100_000)
                let n = NativeSTAConservativeNumerics(limits: limits,
                    budget: .init(maximum: limits.maximumPathStates, transformResources: waiterResources), resources: nil)
                var work: UInt64 = 0
                _ = try NativeSTAConservativeNativeAllocation.withLease(dimension: 1, nonzeros: 1,
                    numerical: n, policy: .init(quotaBytes: 4096, recordCapacity: 16), work: &work) { _ in
                    rendezvous.bodyEntered()
                    try NativeSTAConservativeNativeAllocation.check()
                }
                rendezvous.finish(cancel ? "Cancelled waiter published a result" : nil)
            } catch Refusal.cancelled {
                rendezvous.finish(cancel ? nil : "Unexpected cancellation")
            } catch { rendezvous.finish(String(describing: error)) }
        }
        waiter.start()
        defer { rendezvous.release() }
        try rendezvous.waiterIsReady()
        if cancel { waiterResources.cancel() }
        rendezvous.release()
        let result = try rendezvous.result()
        #expect(result.failures.isEmpty)
        #expect(result.waiterBody == !cancel)
        withExtendedLifetime((owner, waiter)) {}
    }

    @Test func sparseRowGrowthRefusesBeforeInsertAndRefundsConstructionMetadata() throws {
        let metadata = UInt64(2 * (MemoryLayout<[Int: TimingNumericInterval]>.stride
            + MemoryLayout<LibertySourceStorageReservation?>.stride))
        let resources = Resources(bytes: metadata)
        do {
            let n = try numerical(resources)
            var rows = try NativeSTAConservativeRowStorage(count: 2, numerical: n)
            #expect(resources.state.temporary == metadata)
            #expect(throws: Refusal.storage) { try rows.set(TimingNumericInterval(point: 1), row: 0, column: 0) }
            #expect(rows[0].isEmpty && rows[1].isEmpty)
            #expect(resources.state.temporary == metadata)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func actualControlledOnePolePreservesLegacyCrossingAndCopiedPreparedLifetime() throws {
        typealias K = NativeSTAConservativeCoupling
        typealias E = TimingParasitics.Endpoint
        let driver = E(name: "driver", ownerNet: "n"), sink = E(name: "sink", ownerNet: "n")
        let inventory = TimingParasitics(networks: [.init(name: "n", capacitances: [
            .init(source: .init(declaringNet: "n", identifier: 1, line: 1), first: sink, capacitance: 1e-14)
        ], resistances: [
            .init(source: .init(declaringNet: "n", identifier: 1, line: 1), first: driver, second: sink, resistance: 100)
        ], connections: [driver, sink])])
        let limits = try STAExecutionLimits(maximumPathStates: 1_000_000, maximumPathWorkUnits: 1_000_000)
        let options = try STAConservativeCoupledRCOptions(maximumNodes: 32, maximumBasisSweeps: 8,
            maximumCertificateAttempts: 12, operatingHistory: .boundedOperatingHistory)
        let thresholds = TimingCharacterizationThresholds(inputRise: 50, inputFall: 50, outputRise: 50, outputFall: 50,
            slewLowerRise: 20, slewUpperRise: 80, slewLowerFall: 20, slewUpperFall: 80)
        let sources: [K.Source] = [.dynamic(endpoint: driver, sourceIsPort: true, riseSlew: 6e-9...6e-9, fallSlew: 6e-9...6e-9)]
        let resources = Resources()
        do {
            var strictWork: UInt64 = 0, legacyWork: UInt64 = 0
            var actual: K.Prepared? = try K().prepare(parasitics: inventory, sources: sources, receiverLoads: [:],
                thresholds: thresholds, options: options, limits: limits,
                stateBudget: .init(maximum: limits.maximumPathStates, transformResources: resources), sourceResources: nil, work: &strictWork)
            let expected = try K().prepare(parasitics: inventory, sources: sources, receiverLoads: [:],
                thresholds: thresholds, options: options, limits: limits,
                stateBudget: .init(maximum: limits.maximumPathStates), sourceResources: nil, work: &legacyWork)
            var copied = actual; actual = nil
            #expect(resources.state.live > 0 && resources.state.temporary == 0)
            let lhs = try K().bounds(prepared: copied!, source: driver, sink: sink, edge: .rise,
                sourceSlew: 6e-9...6e-9, work: &strictWork)
            let rhs = try K().bounds(prepared: expected, source: driver, sink: sink, edge: .rise,
                sourceSlew: 6e-9...6e-9, work: &legacyWork)
            #expect(lhs.delay == rhs.delay && lhs.slew == rhs.slew)
            #expect(lhs.minimumCrossingDerivative == rhs.minimumCrossingDerivative)
            #expect(strictWork >= legacyWork)
            withExtendedLifetime(copied) {}
            copied = nil
            #expect(resources.state.live == 0 && resources.state.temporary == 0)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func numericDiagnosticKeepsTypedCauseAndRefundsAtFinalFailureCopy() throws {
        let resources = Resources()
        do {
            let n = try numerical(resources), sparse = NativeSTAConservativeSparseNumerics(numerical: n)
            var work: UInt64 = 0
            let f = try sparse.fromRows([[0: TimingNumericInterval(point: 1)]], columns: 1, work: &work)
            let one = try n.identity(1, work: &work)
            let baseline = resources.state.live
            var retained: TimingControlledTransformFailure?
            do {
                _ = try NativeSTAConservativeCoupling().certifiedSparseWeight(comparison: f, ones: one,
                    monotoneWeight: true, maximumIterations: 2, numerical: n, work: &work)
                Issue.record("Positive comparison diagonal unexpectedly certified")
            } catch let failure as TimingControlledTransformFailure {
                let cause = try #require(failure.cause as? NativeSTAConservativeCandidateNotCertified)
                #expect(cause.reason.contains("principal comparison proved non-Hurwitz"))
                #expect(cause.reason.contains("diagonal transformedCoordinateRow=0 coefficient=1.0"))
                retained = failure
            }
            #expect(resources.state.live > baseline)
            var final = retained; retained = nil
            #expect(resources.state.live > baseline)
            withExtendedLifetime(final) {}
            final = nil
            #expect(resources.state.live == baseline && resources.state.temporary == 0)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func representativeSparseRowsUseTypedLinearPayloadAndRefundAtFinalCSR() throws {
        let count = 512, resources = Resources()
        var result: NativeSTAConservativeSparseNumerics.CSR?
        let scalarBytes = MemoryLayout<TimingNumericInterval>.stride
        let csrBytes = UInt64((2 * count + 1) * MemoryLayout<Int>.stride + count * scalarBytes)
        let rowMetadata = UInt64(count * (MemoryLayout<[Int: TimingNumericInterval]>.stride
            + MemoryLayout<LibertySourceStorageReservation?>.stride))
        let rowHash = try TimingTransformCapacity.dictionary(Int.self, TimingNumericInterval.self, minimumCapacity: 2)
        let expectedPeak = rowMetadata + UInt64(count) * rowHash + csrBytes + UInt64(2 * MemoryLayout<Int>.stride)
        do {
            let n = try numerical(resources), s = NativeSTAConservativeSparseNumerics(numerical: n)
            var rows = try NativeSTAConservativeRowStorage(count: count, numerical: n)
            for row in 0..<count { try rows.set(TimingNumericInterval(point: 2), row: row, column: row) }
            var work: UInt64 = 0
            result = try s.fromRows(rows, columns: count, work: &work)
            #expect(result!.rowOffsets.count == count + 1 && result!.values.count == count)
            #expect(result!.columnIndices == Array(0..<count))
            #expect(result!.values.allSatisfy { $0.lowerBound == 2 && $0.upperBound == 2 })
            #expect(resources.state.live == csrBytes)
            #expect(resources.state.peak <= expectedPeak)
            #expect(resources.state.work < 20_000)
            print("strict sparse payload n=\(count) peak=\(resources.state.peak) work=\(resources.state.work) csr=\(resources.state.live)")
            withExtendedLifetime(rows) {}
        }
        #expect(resources.state.temporary == 0 && resources.state.live == csrBytes)
        var final = result; result = nil
        #expect(resources.state.live == csrBytes)
        withExtendedLifetime(final) {}
        final = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

}

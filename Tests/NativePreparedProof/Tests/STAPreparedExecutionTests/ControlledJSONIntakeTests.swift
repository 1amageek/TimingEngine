import Foundation
import PDKCore
import PDKDiscovery
import Synchronization
import Testing
import TimingCore
@testable import STAEngine

@Suite("Controlled Timing JSON intake")
struct ControlledJSONIntakeTests {
    private final class Resources: LibertySourceResourceAccounting {
        enum Failure: Error, Sendable { case cancelled, capacity, work }
        private struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0; var cancelled = false }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        func cancel(_ value: Bool) { state.withLock { $0.cancelled = value } }
        func check() throws { if state.withLock({ $0.cancelled }) { throw Failure.cancelled } }
        func chargeWork(_ amount: UInt64) throws {
            try state.withLock { state in
                let next = state.work.addingReportingOverflow(amount)
                guard !next.overflow, next.partialValue <= 1_000_000 else { throw Failure.work }
                state.work = next.partialValue
            }
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            try state.withLock { state in
                let old = kind == .liveOwnedBytes ? state.live : state.temporary
                let next = old.addingReportingOverflow(byteCount)
                guard !next.overflow, next.partialValue <= 1_000_000 else { throw Failure.capacity }
                if kind == .liveOwnedBytes { state.live = next.partialValue } else { state.temporary = next.partialValue }
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                state.withLock { state in
                    if kind == .liveOwnedBytes { state.live -= byteCount } else { state.temporary -= byteCount }
                }
            }
        }
    }

    @Test(arguments: [1, 2, 3])
    func belowExactAboveConfiguredNestingCeiling(maximum: Int) throws {
        let resources = Resources()
        let bytes = Data(#"{"schemaVersion":2,"topDesignName":"top","ports":[],"instances":[],"nets":[]}"#.utf8)
        do {
            let decoded = try NativeSTABoundedJSONDecoder(maximumNesting: maximum).decodeDesign(bytes, resources: resources)
            #expect(maximum >= 2)
            #expect(decoded.value.topDesignName == "top")
        } catch let failure as PDKControlledDecodeFailure {
            #expect(maximum == 1)
            guard case .resource(.exhausted(let dimension, let limit, let attempted)) = failure.cause else {
                Issue.record("Expected exact depth refusal: \(failure.cause)"); return
            }
            #expect(dimension == .decodeNesting)
            #expect(limit == 1)
            #expect(attempted == 2)
        }
        #expect(resources.live == 0)
        #expect(resources.temporary == 0)
    }

    @Test func depthReleaseDoesNotCheckCancelledCallerAndCanBeReused() throws {
        let resources = Resources()
        do {
            let accounting = try NativeSTAPDKAccounting(resources: resources, maximumNesting: 1)
            var first: PDKAdmissionReservation? = try accounting.reserve(.init(dimension: .decodeNesting, amount: 1))
            #expect(first != nil)
            resources.cancel(true)
            first = nil // Release must balance depth even while cancellation is active.
            resources.cancel(false)
            let next = try accounting.reserve(.init(dimension: .decodeNesting, amount: 1))
            #expect(next.cost.amount == 1)
            withExtendedLifetime(next) {}
        }
        #expect(resources.live == 0)
        #expect(resources.temporary == 0)
    }
}

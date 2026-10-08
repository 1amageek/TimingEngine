import Synchronization
@testable import TimingCore

final class LibertyCodecTestResources: LibertySourceResourceAccounting {
    enum Failure: Error, Sendable, Equatable { case quota(LibertySourceStorageKind), work, cancelled, deadline }
    private struct State {
        var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0
        var checks = 0; var reservations = 0; var releases = 0
    }
    private let state = Mutex(State())
    private let maximumLiveBytes: UInt64
    private let maximumTemporaryBytes: UInt64
    private let maximumWork: UInt64
    private let refuseAfterChecks: Int?
    private let checkFailure: Failure
    init(maximumLiveBytes: UInt64 = .max, maximumTemporaryBytes: UInt64 = .max,
         maximumWork: UInt64 = .max, refuseAfterChecks: Int? = nil, checkFailure: Failure = .cancelled) {
        self.maximumLiveBytes = maximumLiveBytes; self.maximumTemporaryBytes = maximumTemporaryBytes
        self.maximumWork = maximumWork; self.refuseAfterChecks = refuseAfterChecks; self.checkFailure = checkFailure
    }
    var liveBytes: UInt64 { state.withLock { $0.live } }
    var temporaryBytes: UInt64 { state.withLock { $0.temporary } }
    var work: UInt64 { state.withLock { $0.work } }
    var reservationCount: Int { state.withLock { $0.reservations } }
    var releaseCount: Int { state.withLock { $0.releases } }
    func check() throws {
        try state.withLock { state in
            state.checks += 1
            if let refuseAfterChecks, state.checks > refuseAfterChecks { throw checkFailure }
        }
    }
    func chargeWork(_ amount: UInt64) throws {
        try state.withLock { state in
            let (next, overflow) = state.work.addingReportingOverflow(amount)
            guard !overflow, next <= maximumWork else { throw Failure.work }; state.work = next
        }
    }
    func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
        try state.withLock { state in
            let current = kind == .liveOwnedBytes ? state.live : state.temporary
            let limit = kind == .liveOwnedBytes ? maximumLiveBytes : maximumTemporaryBytes
            let (next, overflow) = current.addingReportingOverflow(byteCount)
            guard !overflow, next <= limit else { throw Failure.quota(kind) }
            if kind == .liveOwnedBytes { state.live = next } else { state.temporary = next }
            state.reservations += 1
        }
        return .init(kind: kind, byteCount: byteCount) { [self] in
            state.withLock { state in
                if kind == .liveOwnedBytes { state.live -= byteCount } else { state.temporary -= byteCount }
                state.releases += 1
            }
        }
    }
}

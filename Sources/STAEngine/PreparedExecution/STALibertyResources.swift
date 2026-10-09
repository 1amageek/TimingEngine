import Synchronization
import TimingCore

/// Invocation-local accounting; callbacks release outside the synchronized admission operation.
public final class STALibertyResources: LibertySourceResourceAccounting {
    private struct State { var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0 }
    private let state = Mutex(State())
    private let maximumStorageBytes: UInt64
    private let maximumWork: UInt64
    private let deadline: ContinuousClock.Instant
    public init(maximumStorageBytes: UInt64 = 268_435_456, maximumWork: UInt64 = 100_000_000,
        maximumDuration: Duration = .seconds(30)) {
        self.maximumStorageBytes = maximumStorageBytes; self.maximumWork = maximumWork
        deadline = ContinuousClock.now.advanced(by: maximumDuration)
    }
    public func check() throws {
        if Task.isCancelled { throw STAPreparationError.cancelled }
        if ContinuousClock.now > deadline { throw STAPreparationError.capacity("Liberty source deadline exceeded") }
    }
    public func chargeWork(_ amount: UInt64) throws {
        try check()
        try state.withLock { state in
            let (next, overflow) = state.work.addingReportingOverflow(amount)
            guard !overflow, next <= maximumWork else { throw STAPreparationError.capacity("Liberty work exceeded") }
            state.work = next
        }
    }
    public func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
        try check()
        try state.withLock { state in
            let current = kind == .liveOwnedBytes ? state.live : state.temporary
            let (next, overflow) = current.addingReportingOverflow(byteCount)
            let (total, totalOverflow) = next.addingReportingOverflow(kind == .liveOwnedBytes ? state.temporary : state.live)
            guard !overflow, !totalOverflow, total <= maximumStorageBytes else { throw STAPreparationError.capacity("Liberty storage exceeded") }
            if kind == .liveOwnedBytes { state.live = next } else { state.temporary = next }
        }
        return .init(kind: kind, byteCount: byteCount) { [self] in
            state.withLock { state in
                if kind == .liveOwnedBytes { state.live -= byteCount } else { state.temporary -= byteCount }
            }
        }
    }
}

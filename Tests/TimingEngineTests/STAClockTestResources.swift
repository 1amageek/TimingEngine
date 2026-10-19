import Synchronization
import TimingCore
import STAEngine

/// Deterministic external deadline boundary shared by preparation and execution.
final class STAClockTestResources: LibertySourceResourceAccounting {
    enum Failure: Error { case deadline }
    private let expired = Mutex(false)
    private let backing = STALibertyResources()
    func expire() { expired.withLock { $0 = true } }
    func check() throws { if expired.withLock({ $0 }) { throw Failure.deadline }; try backing.check() }
    func chargeWork(_ amount: UInt64) throws { try check(); try backing.chargeWork(amount) }
    func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
        try check(); return try backing.reserveStorage(kind: kind, byteCount: byteCount)
    }
}

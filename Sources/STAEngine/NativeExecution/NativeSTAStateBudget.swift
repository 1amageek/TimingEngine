import Synchronization
import TimingCore

/// Request-owned conservative logical workspace admission, shared by clock and data.
internal final class NativeSTAStateBudget: Sendable {
    private let used = Mutex(0)
    private let maximum: Int
    let transformResources: (any LibertySourceResourceAccounting)?
    init(maximum: Int, transformResources: (any LibertySourceResourceAccounting)? = nil) {
        self.maximum = maximum; self.transformResources = transformResources
    }

    /// Admit only this concrete buffer payload; its owner retains the lease through the final use.
    func reservePayload<Element>(_ type: Element.Type, capacity: Int, kind: LibertySourceStorageKind)
        throws -> LibertySourceStorageReservation? {
        guard let resources = transformResources else { return nil }
        guard capacity >= 0 else { throw LibertySourceError.arithmeticOverflow }
        let bytes = UInt64(capacity).multipliedReportingOverflow(by: UInt64(MemoryLayout<Element>.stride))
        guard !bytes.overflow else { throw LibertySourceError.arithmeticOverflow }
        try resources.check()
        let lease = try resources.reserveStorage(kind: kind, byteCount: bytes.partialValue)
        try resources.check()
        return lease
    }

    /// This is the same request-wide work ledger, independent of logical state-slot admission.
    func chargeScheduledWork(_ units: UInt64) throws {
        guard let resources = transformResources else { return }
        try resources.check()
        try resources.chargeWork(units)
        try resources.check()
    }
    func reserve(_ count: Int) throws {
        try used.withLock { used in
            let next = used.addingReportingOverflow(count)
            guard count >= 0, !next.overflow, next.partialValue <= maximum else {
                throw STAPathAnalysisError.capacity(resource: "cumulative native state slots", limit: UInt64(maximum))
            }
            used = next.partialValue
        }
    }
}

import Synchronization
import TimingCore

/// One operation's original limits/accountant survive every checked-context copy.
internal final class NativeSTAInitialSourceControl: Sendable {
    let stateBudget: NativeSTAStateBudget
    let limits: STAExecutionLimits
    let resources: any LibertySourceResourceAccounting
    private let work = Mutex(UInt64(0))
    private let lease: LibertySourceStorageReservation

    init(limits: STAExecutionLimits, resources: any LibertySourceResourceAccounting, contextCount: Int) throws {
        self.limits = limits; self.resources = resources
        try Task.checkCancellation(); try resources.check()
        let output = contextCount.multipliedReportingOverflow(by: MemoryLayout<STAConservativeSourceContext>.stride)
        guard contextCount >= 0, !output.overflow else { throw LibertySourceError.arithmeticOverflow }
        let metadata = MemoryLayout<Mutex<UInt64>>.stride + MemoryLayout<NativeSTAInitialSourceControl>.stride
            + MemoryLayout<LibertySourceStorageReservation>.stride + MemoryLayout<STAExecutionLimits>.stride
            + MemoryLayout<NativeSTAStateBudget>.stride + MemoryLayout<any LibertySourceResourceAccounting>.stride
        let total = output.partialValue.addingReportingOverflow(metadata)
        guard !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        lease = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(total.partialValue))
        stateBudget = NativeSTAStateBudget(maximum: limits.maximumPathStates)
        try stateBudget.reserve(contextCount)
    }
    // Called only before any context is published; builders already check the same work ceiling.
    func finishBuilder(work total: UInt64) throws {
        guard total <= limits.maximumPathWorkUnits else { throw capacity() }
        work.withLock { $0 = total }
        try checkpoint(amount: 0)
    }
    func checkpoint(amount: UInt64 = 1) throws {
        try work.withLock { used in
            let next = used.addingReportingOverflow(amount)
            guard !next.overflow, next.partialValue <= limits.maximumPathWorkUnits else { throw capacity() }
            used = next.partialValue
        }
        // No caller/source callback runs under the counter lock.
        try Task.checkCancellation(); try resources.check(); try resources.chargeWork(amount)
    }
    func reserve(bytes: Int, slots: Int) throws -> LibertySourceStorageReservation {
        try Task.checkCancellation(); try resources.check()
        guard bytes >= 0, slots >= 0 else { throw LibertySourceError.arithmeticOverflow }
        try stateBudget.reserve(slots)
        return try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(bytes))
    }
    private func capacity() -> STAPathAnalysisError {
        .capacity(resource: "initial source context work", limit: limits.maximumPathWorkUnits)
    }
}

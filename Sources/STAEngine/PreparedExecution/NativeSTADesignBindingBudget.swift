import Synchronization
import TimingCore

/// Prepared copies share one cumulative admission counter; callbacks run outside its lock.
internal final class NativeSTADesignBindingBudget: Sendable {
    private let used: Mutex<UInt64>
    private let maximum: UInt64
    private let reservation: LibertySourceStorageReservation

    init(limits: STAExecutionLimits, resources: any LibertySourceResourceAccounting) throws {
        maximum = limits.maximumPathWorkUnits
        // Account concrete fields without placing the noncopyable Mutex in a Copyable tuple.
        let counterAndLimit = UInt64(MemoryLayout<Mutex<UInt64>>.stride)
            .addingReportingOverflow(UInt64(MemoryLayout<UInt64>.stride))
        let payload = counterAndLimit.partialValue
            .addingReportingOverflow(UInt64(MemoryLayout<LibertySourceStorageReservation>.stride))
        guard !counterAndLimit.overflow, !payload.overflow else { throw LibertySourceError.arithmeticOverflow }
        let bytes = payload.partialValue
        try resources.check(); try resources.chargeWork(1)
        reservation = try resources.reserveStorage(kind:.liveOwnedBytes,byteCount:bytes)
        used = Mutex(UInt64(1))
    }
    func charge(_ amount: UInt64) throws(STADesignBindingError) {
        try used.withLock { used throws(STADesignBindingError) in
            let next = used.addingReportingOverflow(amount)
            guard !next.overflow, next.partialValue <= maximum else { throw .capacity }
            used = next.partialValue
        }
    }
}

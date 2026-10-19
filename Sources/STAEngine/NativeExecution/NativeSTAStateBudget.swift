import Synchronization

/// Request-owned conservative logical workspace admission, shared by clock and data.
internal final class NativeSTAStateBudget: Sendable {
    private let used = Mutex(0)
    private let maximum: Int
    init(maximum: Int) { self.maximum = maximum }
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

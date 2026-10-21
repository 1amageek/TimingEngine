/// Ensures cancellation/deadline changes caused by an external callback are
/// observed before its caller can allocate, traverse or publish.
package final class TimingCheckedSourceResources: LibertySourceResourceAccounting, Sendable {
    private let underlying: any LibertySourceResourceAccounting
    private let metadata: LibertySourceStorageReservation

    package init(_ underlying: any LibertySourceResourceAccounting) throws {
        try underlying.check()
        let bytes = try LibertySourceCapacity.byteCount(of:
            (any LibertySourceResourceAccounting, LibertySourceStorageReservation).self, capacity: 1)
        let metadata = try underlying.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        try underlying.check()
        self.underlying = underlying; self.metadata = metadata
    }

    package func check() throws { try underlying.check() }
    package func chargeWork(_ amount: UInt64) throws {
        try underlying.check()
        try underlying.chargeWork(amount)
        try underlying.check()
    }
    package func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws
        -> LibertySourceStorageReservation {
        try underlying.check()
        let reservation = try underlying.reserveStorage(kind: kind, byteCount: byteCount)
        try underlying.check()
        return reservation
    }
}

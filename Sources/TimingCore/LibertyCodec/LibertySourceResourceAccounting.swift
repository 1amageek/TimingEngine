/// Trusted external accounting. Implementations synchronize shared resource state.
public protocol LibertySourceResourceAccounting: Sendable {
    func check() throws
    func chargeWork(_ amount: UInt64) throws
    func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64)
        throws -> LibertySourceStorageReservation
}

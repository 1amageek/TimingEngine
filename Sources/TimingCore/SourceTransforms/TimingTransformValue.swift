/// Retain the complete handle while using its value. Detached values transfer
/// their managed-storage responsibility to the caller, as for OwnedLibertySource.
public struct TimingTransformValue<Value: Sendable>: Sendable {
    public let value: Value
    private let owner: any Sendable

    package init<Retention: Sendable>(value: Value, retaining: Retention,
        resources: any LibertySourceResourceAccounting) throws {
        try resources.check()
        let fixed = try LibertySourceCapacity.byteCount(of: Self.self, capacity: 1)
        let retained = try LibertySourceCapacity.byteCount(of:
            (Retention, LibertySourceStorageReservation).self, capacity: 1)
        let total = fixed.addingReportingOverflow(retained)
        guard !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        let reservation = try resources.reserveStorage(kind: .liveOwnedBytes,
            byteCount: total.partialValue)
        try resources.check()
        try resources.chargeWork(1)
        try resources.check()
        self.value = value
        self.owner = Owner(retaining: retaining, reservation: reservation)
    }

    private final class Owner<Retention: Sendable>: Sendable {
        let retaining: Retention
        let reservation: LibertySourceStorageReservation
        init(retaining: Retention, reservation: LibertySourceStorageReservation) {
            self.retaining = retaining; self.reservation = reservation
        }
    }
}

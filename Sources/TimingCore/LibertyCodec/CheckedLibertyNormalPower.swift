/// An exact source-owned conditional result. No public unchecked constructor or decoder exists.
public final class CheckedLibertyNormalPower: Sendable {
    public let receipt: LibertyNormalPowerReceipt
    private let source: OwnedLibertySource
    private let reservation: LibertySourceStorageReservation

    internal init(receipt: LibertyNormalPowerReceipt, source: OwnedLibertySource,
                  reservation: LibertySourceStorageReservation) {
        self.receipt = receipt; self.source = source; self.reservation = reservation
    }
}

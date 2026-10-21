/// A typed caller cause paired with the complete lower failure and its anchors.
/// Inspecting cause never transfers the lower error's retained storage lifetime.
public struct TimingControlledTransformFailure: Error, Sendable {
    public let cause: any Error
    private let retained: any Sendable
    private let metadata: LibertySourceStorageReservation

    package init<Retention: Sendable>(cause: any Error, retaining: Retention,
        metadata: LibertySourceStorageReservation) {
        self.cause = cause; self.retained = retaining; self.metadata = metadata
    }

    package static func storageByteCount() throws -> UInt64 {
        try LibertySourceCapacity.byteCount(of:
            (any Error, any Sendable, LibertySourceStorageReservation).self, capacity: 1)
    }
}

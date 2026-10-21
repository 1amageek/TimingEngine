/// One invocation's prepaid terminal failure boundary. It preserves source owner
/// lifetime without consulting a cancelled/exhausted caller after a failure.
package struct TimingControlledDiagnostics<Retention: Sendable>: Sendable {
    private let resources: any LibertySourceResourceAccounting
    private let retained: Retention
    private let metadata: LibertySourceStorageReservation

    package init(resources: any LibertySourceResourceAccounting, retaining: Retention) throws {
        try resources.check()
        let wrapper = try TimingControlledTransformFailure.storageByteCount()
        let payload = try LibertySourceCapacity.byteCount(of:
            (Retention, LibertySourceStorageReservation?).self, capacity: 1)
        let boundary = try LibertySourceCapacity.byteCount(of: Self.self, capacity: 1)
        let first = wrapper.addingReportingOverflow(payload)
        let total = first.partialValue.addingReportingOverflow(boundary)
        guard !first.overflow, !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        let lease = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: total.partialValue)
        try resources.check()
        self.resources = resources; retained = retaining; metadata = lease
    }

    /// No caller callback, string conversion or new source-data copy occurs here.
    package func failure(_ cause: any Error) -> TimingControlledTransformFailure {
        TimingControlledTransformFailure(cause: cause,
            retaining: (retained, Optional<LibertySourceStorageReservation>.none), metadata: metadata)
    }

    package func sourceFailure(utf8ByteCount: UInt64,
        _ construct: () -> any Error) throws -> TimingControlledTransformFailure {
        try resources.check()
        let lease = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: utf8ByteCount)
        try resources.check()
        try resources.chargeWork(utf8ByteCount)
        try resources.check()
        let cause = construct()
        return TimingControlledTransformFailure(cause: cause, retaining: (retained, Optional(lease)), metadata: metadata)
    }
}

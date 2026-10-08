/// An external receipt, shared through copies, with exactly-once release.
public struct LibertySourceStorageReservation: Sendable {
    public let kind: LibertySourceStorageKind
    public let byteCount: UInt64
    private let owner: Owner

    public init(kind: LibertySourceStorageKind, byteCount: UInt64,
                release: @escaping @Sendable () -> Void) {
        self.kind = kind; self.byteCount = byteCount; owner = Owner(release: release)
    }

    private final class Owner: Sendable {
        let release: @Sendable () -> Void
        init(release: @escaping @Sendable () -> Void) { self.release = release }
        deinit { release() }
    }
}

/// Concrete logical payload extent, independent of allocator overhead or RSS.
public enum LibertySourceStorageKind: Sendable, Hashable {
    case liveOwnedBytes, temporaryBytes
}

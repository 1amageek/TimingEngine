/// Actual source table attribute position, independent of artifact availability or corner.
public struct LibertyTimingTableIdentity: Sendable, Hashable, Codable {
    public let name: String
    public let line: Int
    public let byteOffset: Int
    internal init(name: String, line: Int, byteOffset: Int) {
        self.name = name; self.line = line; self.byteOffset = byteOffset
    }
}

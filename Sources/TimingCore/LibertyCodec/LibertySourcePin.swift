/// An original pin declaration, in source order; no inferred terminal identity.
public struct LibertySourcePin: Sendable, Hashable {
    public let name: String
    public let line: Int
    public let byteOffset: Int
    internal init(name: String, line: Int, byteOffset: Int) {
        self.name = name; self.line = line; self.byteOffset = byteOffset
    }
}

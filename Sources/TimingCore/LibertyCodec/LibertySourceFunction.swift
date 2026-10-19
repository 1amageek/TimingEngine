/// An actual function attribute and its source position, never an inferred gate kind.
public struct LibertySourceFunction: Sendable, Hashable, Codable {
    public enum Content: Sendable, Hashable, Codable {
        case normalized(LibertyBooleanFunctionFacts)
        case unsupported(LibertyBooleanFunctionIssue)
    }
    public let content: Content
    public let line: Int
    public let byteOffset: Int

    internal init(content: Content, line: Int, byteOffset: Int) {
        self.content = content; self.line = line; self.byteOffset = byteOffset
    }
}

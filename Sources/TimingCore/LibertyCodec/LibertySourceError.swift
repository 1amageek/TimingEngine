/// Source failures publish no unchecked library or coverage success.
public enum LibertySourceError: Error, Sendable {
    case resource(any Error)
    case invalidLimit, invalidCapacity, arithmeticOverflow
    case invalidUTF8(byteOffset: Int)
    case unsupportedSemantics(String)
    case nestingLimit(maximum: Int)
    case syntax(line: Int)
    case conversion(any Error)
}

public struct TimingPathObject: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public enum Kind: String, Sendable, Hashable, Codable { case name, port, pin, net, clock, instance }
    public let kind: Kind
    public let pattern: String
    public init(kind: Kind, pattern: String) { self.kind = kind; self.pattern = pattern }
    public init(stringLiteral value: String) { kind = .name; pattern = value }
}

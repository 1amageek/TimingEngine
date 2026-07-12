import Foundation

public struct TimingPathGroup: Sendable, Hashable, Codable {
    public var name: String
    public var from: [String]
    public var to: [String]
    public var through: [String]
    public var weight: Double?

    public init(
        name: String,
        from: [String] = [],
        to: [String] = [],
        through: [String] = [],
        weight: Double? = nil
    ) {
        self.name = name
        self.from = from
        self.to = to
        self.through = through
        self.weight = weight
    }
}

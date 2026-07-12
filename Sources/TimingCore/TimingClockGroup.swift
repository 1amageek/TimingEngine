import Foundation

public struct TimingClockGroup: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case asynchronous
        case logicallyExclusive
        case physicallyExclusive
    }

    public var kind: Kind
    public var groups: [[String]]

    public init(kind: Kind, groups: [[String]]) {
        self.kind = kind
        self.groups = groups
    }
}

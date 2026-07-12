import Foundation

public enum TimingEdge: String, Sendable, Hashable, Codable {
    case rise
    case fall

    public var inverted: TimingEdge {
        switch self {
        case .rise:
            return .fall
        case .fall:
            return .rise
        }
    }
}

public enum TimingSense: String, Sendable, Hashable, Codable {
    case positiveUnate
    case negativeUnate
    case nonUnate

    public func inputEdge(for outputEdge: TimingEdge) -> TimingEdge? {
        switch self {
        case .positiveUnate:
            return outputEdge
        case .negativeUnate:
            return outputEdge.inverted
        case .nonUnate:
            return nil
        }
    }
}

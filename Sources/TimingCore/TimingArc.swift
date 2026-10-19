import Foundation

public struct TimingArc: Sendable, Hashable, Codable {
    public var fromPin: String
    public var toPin: String
    public var sense: TimingSense
    public var delayRise: TimingLUT
    public var delayFall: TimingLUT
    public var transitionRise: TimingLUT
    public var transitionFall: TimingLUT
    public var isConstraint: Bool
    public var sourceIdentity: LibertyTimingSourceIdentity?

    public init(
        fromPin: String,
        toPin: String,
        sense: TimingSense,
        delayRise: TimingLUT,
        delayFall: TimingLUT,
        transitionRise: TimingLUT,
        transitionFall: TimingLUT,
        isConstraint: Bool = false,
        sourceIdentity: LibertyTimingSourceIdentity? = nil
    ) {
        self.fromPin = fromPin
        self.toPin = toPin
        self.sense = sense
        self.delayRise = delayRise
        self.delayFall = delayFall
        self.transitionRise = transitionRise
        self.transitionFall = transitionFall
        self.isConstraint = isConstraint
        self.sourceIdentity = sourceIdentity
    }

    public func delay(for outputEdge: TimingEdge) -> TimingLUT {
        switch outputEdge {
        case .rise:
            return delayRise
        case .fall:
            return delayFall
        }
    }

    public func transition(for outputEdge: TimingEdge) -> TimingLUT {
        switch outputEdge {
        case .rise:
            return transitionRise
        case .fall:
            return transitionFall
        }
    }
}

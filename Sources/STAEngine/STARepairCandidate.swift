import Foundation

public struct STARepairCandidate: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case reduceLogicDepth = "reduce-logic-depth"
        case upsizeCell = "upsize-cell"
        case addHoldBuffer = "add-hold-buffer"
        case reviewClockConstraint = "review-clock-constraint"
    }

    public var kind: Kind
    public var endpoint: String
    public var modeID: String
    public var cornerID: String
    public var rationale: String
    public var expectedImpact: String

    public init(
        kind: Kind,
        endpoint: String,
        modeID: String,
        cornerID: String,
        rationale: String,
        expectedImpact: String
    ) {
        self.kind = kind
        self.endpoint = endpoint
        self.modeID = modeID
        self.cornerID = cornerID
        self.rationale = rationale
        self.expectedImpact = expectedImpact
    }
}

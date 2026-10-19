/// One original pin pulse law. Rise opens a high pulse; fall opens a low pulse.
public struct TimingPulseWidthConstraint: Sendable, Hashable, Codable {
    public enum Limit: Sendable, Hashable, Codable {
        case scalar(Double)
        /// One related-pin transition axis; the LUT's second coordinate is representation only.
        case relatedPinTransition(TimingLUT)
    }

    public let pin: String
    public let relatedPin: String?
    public let relatedOutputPin: String?
    public let openingEdge: TimingEdge
    public let limit: Limit
    public let sourceIdentity: LibertyTimingSourceIdentity?

    public init(pin: String, relatedPin: String? = nil, relatedOutputPin: String? = nil,
                openingEdge: TimingEdge, limit: Limit, sourceIdentity: LibertyTimingSourceIdentity? = nil) {
        self.pin = pin; self.relatedPin = relatedPin; self.relatedOutputPin = relatedOutputPin
        self.openingEdge = openingEdge; self.limit = limit; self.sourceIdentity = sourceIdentity
    }
}

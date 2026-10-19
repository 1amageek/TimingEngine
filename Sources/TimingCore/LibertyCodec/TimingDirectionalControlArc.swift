/// Original asynchronous-control tables; inventory alone grants no dynamic propagation policy.
public struct TimingDirectionalControlArc: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case clear, preset }
    public let kind: Kind
    public let fromPin: String
    public let toPin: String
    public let sense: TimingSense?
    public let delayRise: TimingLUT?
    public let delayFall: TimingLUT?
    public let transitionRise: TimingLUT?
    public let transitionFall: TimingLUT?
    public let sourceIdentity: LibertyTimingSourceIdentity

    internal init(kind: Kind, fromPin: String, toPin: String, sense: TimingSense?,
                  delayRise: TimingLUT?, delayFall: TimingLUT?, transitionRise: TimingLUT?, transitionFall: TimingLUT?,
                  sourceIdentity: LibertyTimingSourceIdentity) {
        self.kind = kind; self.fromPin = fromPin; self.toPin = toPin; self.sense = sense
        self.delayRise = delayRise; self.delayFall = delayFall
        self.transitionRise = transitionRise; self.transitionFall = transitionFall; self.sourceIdentity = sourceIdentity
    }
}

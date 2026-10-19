import TimingCore

/// Explicit primary-input operating waveform; receiver timing is computed from the candidate.
public struct STAControlPulseSource: Sendable, Hashable, Codable {
    public let modeID: String
    public let sourcePort: String
    public let referenceClock: String
    public let period: Double
    public let risePhase: Double
    public let fallPhase: Double
    public let riseTransition: Double
    public let fallTransition: Double

    public init(modeID: String, sourcePort: String, referenceClock: String, period: Double,
                risePhase: Double, fallPhase: Double, riseTransition: Double, fallTransition: Double) throws {
        guard [modeID, sourcePort, referenceClock].allSatisfy({ !$0.isEmpty }),
              [period, risePhase, fallPhase, riseTransition, fallTransition].allSatisfy(\.isFinite),
              period > 0, risePhase >= 0, risePhase < fallPhase, fallPhase < period,
              riseTransition > 0, fallTransition > 0 else {
            throw TimingError.invalidInput("Control pulse source requires exact identities and finite ordered waveform")
        }
        self.modeID = modeID; self.sourcePort = sourcePort; self.referenceClock = referenceClock
        self.period = period; self.risePhase = risePhase; self.fallPhase = fallPhase
        self.riseTransition = riseTransition; self.fallTransition = fallTransition
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(modeID: c.decode(String.self, forKey: .modeID), sourcePort: c.decode(String.self, forKey: .sourcePort),
            referenceClock: c.decode(String.self, forKey: .referenceClock), period: c.decode(Double.self, forKey: .period),
            risePhase: c.decode(Double.self, forKey: .risePhase), fallPhase: c.decode(Double.self, forKey: .fallPhase),
            riseTransition: c.decode(Double.self, forKey: .riseTransition), fallTransition: c.decode(Double.self, forKey: .fallTransition))
    }
}

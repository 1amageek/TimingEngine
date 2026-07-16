import Foundation
import TimingCore

public struct SignalIntegrityPayload: Sendable, Hashable, Codable {
    public var violationCount: Int
    public var worstDeltaDelay: Double?
    public var worstNoiseRatio: Double?
    public var analyzedModes: [String]
    public var analyzedNets: [SINetSummary]
    public var violations: [SIViolation]
    public var provenance: TimingArtifactProvenance

    public init(
        violationCount: Int,
        worstDeltaDelay: Double?,
        worstNoiseRatio: Double? = nil,
        analyzedModes: [String] = [],
        analyzedNets: [SINetSummary] = [],
        violations: [SIViolation] = [],
        provenance: TimingArtifactProvenance = TimingArtifactProvenance()
    ) {
        self.violationCount = violationCount
        self.worstDeltaDelay = worstDeltaDelay
        self.worstNoiseRatio = worstNoiseRatio
        self.analyzedModes = analyzedModes
        self.analyzedNets = analyzedNets
        self.violations = violations
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case violationCount
        case worstDeltaDelay
        case worstNoiseRatio
        case analyzedModes
        case analyzedNets
        case violations
        case provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            violationCount: try container.decodeIfPresent(Int.self, forKey: .violationCount) ?? 0,
            worstDeltaDelay: try container.decodeIfPresent(Double.self, forKey: .worstDeltaDelay),
            worstNoiseRatio: try container.decodeIfPresent(Double.self, forKey: .worstNoiseRatio),
            analyzedModes: try container.decodeIfPresent([String].self, forKey: .analyzedModes) ?? [],
            analyzedNets: try container.decodeIfPresent([SINetSummary].self, forKey: .analyzedNets) ?? [],
            violations: try container.decodeIfPresent([SIViolation].self, forKey: .violations) ?? [],
            provenance: try container.decodeIfPresent(TimingArtifactProvenance.self, forKey: .provenance) ?? TimingArtifactProvenance()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(violationCount, forKey: .violationCount)
        try container.encodeIfPresent(worstDeltaDelay, forKey: .worstDeltaDelay)
        try container.encodeIfPresent(worstNoiseRatio, forKey: .worstNoiseRatio)
        try container.encode(analyzedModes, forKey: .analyzedModes)
        try container.encode(analyzedNets, forKey: .analyzedNets)
        try container.encode(violations, forKey: .violations)
        try container.encode(provenance, forKey: .provenance)
    }
}

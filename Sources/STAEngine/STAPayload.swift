import Foundation
import TimingCore

public struct STAPayload: Sendable, Hashable, Codable {
    public var worstSetupSlack: Double?
    public var worstHoldSlack: Double?
    public var analyzedCorners: [String]
    public var analyzedModes: [String]
    public var endpoints: [STAEndpoint]
    public var criticalPaths: [STAPath]
    public var violations: [STAViolation]
    public var repairCandidates: [STARepairCandidate]
    public var provenance: TimingArtifactProvenance

    public init(
        worstSetupSlack: Double?,
        worstHoldSlack: Double?,
        analyzedCorners: [String],
        analyzedModes: [String] = [],
        endpoints: [STAEndpoint] = [],
        criticalPaths: [STAPath] = [],
        violations: [STAViolation] = [],
        repairCandidates: [STARepairCandidate] = [],
        provenance: TimingArtifactProvenance = TimingArtifactProvenance()
    ) {
        self.worstSetupSlack = worstSetupSlack
        self.worstHoldSlack = worstHoldSlack
        self.analyzedCorners = analyzedCorners
        self.analyzedModes = analyzedModes
        self.endpoints = endpoints
        self.criticalPaths = criticalPaths
        self.violations = violations
        self.repairCandidates = repairCandidates
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case worstSetupSlack
        case worstHoldSlack
        case analyzedCorners
        case analyzedModes
        case endpoints
        case criticalPaths
        case violations
        case repairCandidates
        case provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            worstSetupSlack: try container.decodeIfPresent(Double.self, forKey: .worstSetupSlack),
            worstHoldSlack: try container.decodeIfPresent(Double.self, forKey: .worstHoldSlack),
            analyzedCorners: try container.decodeIfPresent([String].self, forKey: .analyzedCorners) ?? [],
            analyzedModes: try container.decodeIfPresent([String].self, forKey: .analyzedModes) ?? [],
            endpoints: try container.decodeIfPresent([STAEndpoint].self, forKey: .endpoints) ?? [],
            criticalPaths: try container.decodeIfPresent([STAPath].self, forKey: .criticalPaths) ?? [],
            violations: try container.decodeIfPresent([STAViolation].self, forKey: .violations) ?? [],
            repairCandidates: try container.decodeIfPresent([STARepairCandidate].self, forKey: .repairCandidates) ?? [],
            provenance: try container.decodeIfPresent(TimingArtifactProvenance.self, forKey: .provenance) ?? TimingArtifactProvenance()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(worstSetupSlack, forKey: .worstSetupSlack)
        try container.encodeIfPresent(worstHoldSlack, forKey: .worstHoldSlack)
        try container.encode(analyzedCorners, forKey: .analyzedCorners)
        try container.encode(analyzedModes, forKey: .analyzedModes)
        try container.encode(endpoints, forKey: .endpoints)
        try container.encode(criticalPaths, forKey: .criticalPaths)
        try container.encode(violations, forKey: .violations)
        try container.encode(repairCandidates, forKey: .repairCandidates)
        try container.encode(provenance, forKey: .provenance)
    }
}

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
    public var parasiticReduction: TimingParasiticReductionEvidence?
    public var provenance: TimingArtifactProvenance
    public var processSelection: STAProcessSelection?
    public var effectiveConfiguration: STAEffectiveConfiguration?
    public var characterization: [STACharacterizationObservation]
    public var libraryConsumption: [STALibraryConsumption]

    public init(
        worstSetupSlack: Double?,
        worstHoldSlack: Double?,
        analyzedCorners: [String],
        analyzedModes: [String] = [],
        endpoints: [STAEndpoint] = [],
        criticalPaths: [STAPath] = [],
        violations: [STAViolation] = [],
        repairCandidates: [STARepairCandidate] = [],
        parasiticReduction: TimingParasiticReductionEvidence? = nil,
        provenance: TimingArtifactProvenance = TimingArtifactProvenance(),
        processSelection: STAProcessSelection? = nil,
        effectiveConfiguration: STAEffectiveConfiguration? = nil,
        characterization: [STACharacterizationObservation] = [],
        libraryConsumption: [STALibraryConsumption] = []
    ) {
        self.worstSetupSlack = worstSetupSlack
        self.worstHoldSlack = worstHoldSlack
        self.analyzedCorners = analyzedCorners
        self.analyzedModes = analyzedModes
        self.endpoints = endpoints
        self.criticalPaths = criticalPaths
        self.violations = violations
        self.repairCandidates = repairCandidates
        self.parasiticReduction = parasiticReduction
        self.provenance = provenance
        self.processSelection = processSelection
        self.effectiveConfiguration = effectiveConfiguration
        self.characterization = characterization
        self.libraryConsumption = libraryConsumption
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
        case parasiticReduction
        case provenance
        case processSelection
        case effectiveConfiguration
        case characterization
        case libraryConsumption
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            worstSetupSlack: try container.decodeIfPresent(Double.self, forKey: .worstSetupSlack),
            worstHoldSlack: try container.decodeIfPresent(Double.self, forKey: .worstHoldSlack),
            analyzedCorners: try container.decode([String].self, forKey: .analyzedCorners),
            analyzedModes: try container.decode([String].self, forKey: .analyzedModes),
            endpoints: try container.decode([STAEndpoint].self, forKey: .endpoints),
            criticalPaths: try container.decode([STAPath].self, forKey: .criticalPaths),
            violations: try container.decode([STAViolation].self, forKey: .violations),
            repairCandidates: try container.decode([STARepairCandidate].self, forKey: .repairCandidates),
            parasiticReduction: try container.decodeIfPresent(TimingParasiticReductionEvidence.self, forKey: .parasiticReduction),
            provenance: try container.decode(TimingArtifactProvenance.self, forKey: .provenance),
            processSelection: try container.decodeIfPresent(STAProcessSelection.self, forKey: .processSelection),
            effectiveConfiguration: try container.decodeIfPresent(STAEffectiveConfiguration.self, forKey: .effectiveConfiguration),
            characterization: try container.decode([STACharacterizationObservation].self, forKey: .characterization),
            libraryConsumption: try container.decode([STALibraryConsumption].self, forKey: .libraryConsumption)
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
        try container.encodeIfPresent(parasiticReduction, forKey: .parasiticReduction)
        try container.encode(provenance, forKey: .provenance)
        try container.encodeIfPresent(processSelection, forKey: .processSelection)
        try container.encodeIfPresent(effectiveConfiguration, forKey: .effectiveConfiguration)
        try container.encode(characterization, forKey: .characterization)
        try container.encode(libraryConsumption, forKey: .libraryConsumption)
    }
}

import Foundation

public struct TimingQualificationReport: Sendable, Hashable, Codable {
    public enum Decision: String, Sendable, Hashable, Codable {
        case qualified
        case blocked
        case failed
    }

    public var schemaVersion: Int
    public var decision: Decision
    public var processID: String
    public var pdkVersion: String
    public var pdkDigest: String
    public var pdkManifestDigest: String?
    public var corpusSuiteID: String
    public var corpusEvidenceDigest: String?
    public var requiredModeIDs: [String]
    public var requiredCornerIDs: [String]
    public var externalOracle: TimingExternalOracleEvidence
    public var pdkEvidence: TimingPDKQualificationEvidence?
    public var findings: [String]

    public init(
        decision: Decision,
        processID: String,
        pdkVersion: String,
        pdkDigest: String,
        pdkManifestDigest: String? = nil,
        corpusSuiteID: String,
        corpusEvidenceDigest: String? = nil,
        requiredModeIDs: [String],
        requiredCornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        pdkEvidence: TimingPDKQualificationEvidence? = nil,
        findings: [String]
    ) {
        self.schemaVersion = 1
        self.decision = decision
        self.processID = processID
        self.pdkVersion = pdkVersion
        self.pdkDigest = pdkDigest
        self.pdkManifestDigest = pdkManifestDigest
        self.corpusSuiteID = corpusSuiteID
        self.corpusEvidenceDigest = corpusEvidenceDigest
        self.requiredModeIDs = requiredModeIDs
        self.requiredCornerIDs = requiredCornerIDs
        self.externalOracle = externalOracle
        self.pdkEvidence = pdkEvidence
        self.findings = findings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case decision
        case processID
        case pdkVersion
        case pdkDigest
        case pdkManifestDigest
        case corpusSuiteID
        case corpusEvidenceDigest
        case requiredModeIDs
        case requiredCornerIDs
        case externalOracle
        case pdkEvidence
        case findings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            decision: try container.decode(Decision.self, forKey: .decision),
            processID: try container.decodeIfPresent(String.self, forKey: .processID) ?? "",
            pdkVersion: try container.decodeIfPresent(String.self, forKey: .pdkVersion) ?? "",
            pdkDigest: try container.decodeIfPresent(String.self, forKey: .pdkDigest) ?? "",
            pdkManifestDigest: try container.decodeIfPresent(String.self, forKey: .pdkManifestDigest),
            corpusSuiteID: try container.decodeIfPresent(String.self, forKey: .corpusSuiteID) ?? "",
            corpusEvidenceDigest: try container.decodeIfPresent(String.self, forKey: .corpusEvidenceDigest),
            requiredModeIDs: try container.decodeIfPresent([String].self, forKey: .requiredModeIDs) ?? [],
            requiredCornerIDs: try container.decodeIfPresent([String].self, forKey: .requiredCornerIDs) ?? [],
            externalOracle: try container.decodeIfPresent(TimingExternalOracleEvidence.self, forKey: .externalOracle)
                ?? TimingExternalOracleEvidence(oracleID: "unknown", status: .notEvaluated, details: "No oracle evidence was retained."),
            pdkEvidence: try container.decodeIfPresent(TimingPDKQualificationEvidence.self, forKey: .pdkEvidence),
            findings: try container.decodeIfPresent([String].self, forKey: .findings) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(decision, forKey: .decision)
        try container.encode(processID, forKey: .processID)
        try container.encode(pdkVersion, forKey: .pdkVersion)
        try container.encode(pdkDigest, forKey: .pdkDigest)
        try container.encodeIfPresent(pdkManifestDigest, forKey: .pdkManifestDigest)
        try container.encode(corpusSuiteID, forKey: .corpusSuiteID)
        try container.encodeIfPresent(corpusEvidenceDigest, forKey: .corpusEvidenceDigest)
        try container.encode(requiredModeIDs, forKey: .requiredModeIDs)
        try container.encode(requiredCornerIDs, forKey: .requiredCornerIDs)
        try container.encode(externalOracle, forKey: .externalOracle)
        try container.encodeIfPresent(pdkEvidence, forKey: .pdkEvidence)
        try container.encode(findings, forKey: .findings)
    }
}

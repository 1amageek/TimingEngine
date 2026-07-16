import Foundation

public struct TimingEvidenceAssessment: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        case passed
        case blocked
        case failed
    }

    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var processID: String
    public var pdkVersion: String
    public var pdkDigest: String
    public var pdkManifestDigest: String?
    public var corpusSuiteID: String
    public var corpusEvidenceDigest: String?
    public var requiredModeIDs: [String]
    public var requiredCornerIDs: [String]
    public var externalOracle: TimingExternalOracleEvidence
    public var externalCorrelation: TimingExternalCorrelationReport?
    public var pdkEvidence: TimingPDKEvidence?
    public var findings: [String]

    public init(
        processID: String,
        pdkVersion: String,
        pdkDigest: String,
        pdkManifestDigest: String? = nil,
        corpusSuiteID: String,
        corpusEvidenceDigest: String? = nil,
        requiredModeIDs: [String],
        requiredCornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        externalCorrelation: TimingExternalCorrelationReport? = nil,
        pdkEvidence: TimingPDKEvidence? = nil,
        findings: [String]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.processID = processID
        self.pdkVersion = pdkVersion
        self.pdkDigest = pdkDigest
        self.pdkManifestDigest = pdkManifestDigest
        self.corpusSuiteID = corpusSuiteID
        self.corpusEvidenceDigest = corpusEvidenceDigest
        self.requiredModeIDs = requiredModeIDs
        self.requiredCornerIDs = requiredCornerIDs
        self.externalOracle = externalOracle
        self.externalCorrelation = externalCorrelation
        self.pdkEvidence = pdkEvidence
        self.findings = findings
    }

    public var outcome: Outcome {
        if findings.contains("pdk_reference_invalid")
            || findings.contains("process_id_mismatch") {
            return .failed
        }
        return findings.isEmpty ? .passed : .blocked
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case processID
        case pdkVersion
        case pdkDigest
        case pdkManifestDigest
        case corpusSuiteID
        case corpusEvidenceDigest
        case requiredModeIDs
        case requiredCornerIDs
        case externalOracle
        case externalCorrelation
        case pdkEvidence
        case findings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported timing evidence assessment schema version."
            )
        }
        self.schemaVersion = schemaVersion
        self.processID = try container.decode(String.self, forKey: .processID)
        self.pdkVersion = try container.decode(String.self, forKey: .pdkVersion)
        self.pdkDigest = try container.decode(String.self, forKey: .pdkDigest)
        self.pdkManifestDigest = try container.decodeIfPresent(String.self, forKey: .pdkManifestDigest)
        self.corpusSuiteID = try container.decode(String.self, forKey: .corpusSuiteID)
        self.corpusEvidenceDigest = try container.decodeIfPresent(String.self, forKey: .corpusEvidenceDigest)
        self.requiredModeIDs = try container.decode([String].self, forKey: .requiredModeIDs)
        self.requiredCornerIDs = try container.decode([String].self, forKey: .requiredCornerIDs)
        self.externalOracle = try container.decode(TimingExternalOracleEvidence.self, forKey: .externalOracle)
        self.externalCorrelation = try container.decodeIfPresent(TimingExternalCorrelationReport.self, forKey: .externalCorrelation)
        self.pdkEvidence = try container.decodeIfPresent(TimingPDKEvidence.self, forKey: .pdkEvidence)
        self.findings = try container.decode([String].self, forKey: .findings)
    }
}

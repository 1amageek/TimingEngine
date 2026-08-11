import CircuiteFoundation
import Foundation
import TimingCore

public struct TimingExternalCorrelationReport: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var processID: String
    public var pdkVersion: String
    public var pdkManifestDigest: String
    public var corpusEvidenceDigest: String
    public var pdkManifestArtifact: TimingArtifactBinding
    public var corpusEvidenceArtifact: TimingArtifactBinding
    public var nativeEngine: ProducerIdentity
    public var oracleTool: ProducerIdentity
    public var oracleExecutableArtifact: TimingArtifactBinding
    public var inputArtifacts: [TimingArtifactBinding]
    public var nativeOutputArtifact: TimingArtifactBinding
    public var oracleOutputArtifact: TimingArtifactBinding
    public var correlation: TimingCorrelationResult

    public init(
        processID: String,
        pdkVersion: String,
        pdkManifestDigest: String,
        corpusEvidenceDigest: String,
        pdkManifestArtifact: TimingArtifactBinding,
        corpusEvidenceArtifact: TimingArtifactBinding,
        nativeEngine: ProducerIdentity,
        oracleTool: ProducerIdentity,
        oracleExecutableArtifact: TimingArtifactBinding,
        inputArtifacts: [TimingArtifactBinding],
        nativeOutputArtifact: TimingArtifactBinding,
        oracleOutputArtifact: TimingArtifactBinding,
        correlation: TimingCorrelationResult
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.processID = processID
        self.pdkVersion = pdkVersion
        self.pdkManifestDigest = pdkManifestDigest
        self.corpusEvidenceDigest = corpusEvidenceDigest
        self.pdkManifestArtifact = pdkManifestArtifact
        self.corpusEvidenceArtifact = corpusEvidenceArtifact
        self.nativeEngine = nativeEngine
        self.oracleTool = oracleTool
        self.oracleExecutableArtifact = oracleExecutableArtifact
        self.inputArtifacts = inputArtifacts
        self.nativeOutputArtifact = nativeOutputArtifact
        self.oracleOutputArtifact = oracleOutputArtifact
        self.correlation = correlation
    }

    public func validateStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TimingError.invalidInput("Unsupported external correlation report schema version.")
        }
        guard Self.isSHA256(pdkManifestDigest), Self.isSHA256(corpusEvidenceDigest) else {
            throw TimingError.invalidInput("External correlation identity digests must be SHA-256 values.")
        }
        guard !processID.isEmpty, !pdkVersion.isEmpty else {
            throw TimingError.invalidInput("External correlation process identity is incomplete.")
        }
        guard !inputArtifacts.isEmpty else {
            throw TimingError.invalidInput("External correlation must retain the correlated input artifacts.")
        }
        let artifacts = [
            pdkManifestArtifact,
            corpusEvidenceArtifact,
            oracleExecutableArtifact,
            nativeOutputArtifact,
            oracleOutputArtifact,
        ] + inputArtifacts
        guard artifacts.allSatisfy(Self.isAuditable),
              artifacts.allSatisfy(\.isWorkspaceRelative) else {
            throw TimingError.invalidInput("External correlation contains an incomplete artifact reference.")
        }
        guard pdkManifestArtifact.descriptor.role == .input,
              corpusEvidenceArtifact.descriptor.role == .input,
              oracleExecutableArtifact.descriptor.role == .input,
              inputArtifacts.allSatisfy({ $0.descriptor.role == .input }),
              nativeOutputArtifact.descriptor.role == .output,
              oracleOutputArtifact.descriptor.role == .output else {
            throw TimingError.invalidInput("External correlation artifact roles do not match their semantics.")
        }
        guard pdkManifestArtifact.descriptor.kind == .technology,
              corpusEvidenceArtifact.descriptor.kind == .report,
              corpusEvidenceArtifact.descriptor.format == .json else {
            throw TimingError.invalidInput("External correlation evidence artifact kinds are invalid.")
        }
        guard correlation.oracleID == oracleTool.identifier else {
            throw TimingError.invalidInput("External correlation oracle identity does not match its tool identity.")
        }
        guard let oracleBuild = oracleTool.build,
              Self.isSHA256(oracleBuild),
              oracleBuild.caseInsensitiveCompare(
                oracleExecutableArtifact.digest.hexadecimalValue
              ) == .orderedSame else {
            throw TimingError.invalidInput("External correlation oracle identity must match the executable SHA-256 digest.")
        }
        guard nativeEngine != oracleTool else {
            throw TimingError.invalidInput("Native and oracle timing tools must be independent.")
        }
        guard nativeOutputArtifact.id != oracleOutputArtifact.id,
              nativeOutputArtifact.id != oracleExecutableArtifact.id,
              oracleOutputArtifact.id != oracleExecutableArtifact.id else {
            throw TimingError.invalidInput("Executable, native output and oracle output artifacts must be distinct.")
        }
        let evidenceArtifacts = [
            pdkManifestArtifact,
            corpusEvidenceArtifact,
            oracleExecutableArtifact,
            nativeOutputArtifact,
            oracleOutputArtifact,
        ]
        guard Set(evidenceArtifacts.map(\.id)).count == evidenceArtifacts.count,
              Set(inputArtifacts.map(\.id)).count == inputArtifacts.count else {
            throw TimingError.invalidInput("External correlation artifact identities must be unique within each role.")
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.processID = try container.decode(String.self, forKey: .processID)
        self.pdkVersion = try container.decode(String.self, forKey: .pdkVersion)
        self.pdkManifestDigest = try container.decode(String.self, forKey: .pdkManifestDigest)
        self.corpusEvidenceDigest = try container.decode(String.self, forKey: .corpusEvidenceDigest)
        self.pdkManifestArtifact = try container.decode(
            TimingArtifactBinding.self,
            forKey: .pdkManifestArtifact
        )
        self.corpusEvidenceArtifact = try container.decode(
            TimingArtifactBinding.self,
            forKey: .corpusEvidenceArtifact
        )
        self.nativeEngine = try container.decode(ProducerIdentity.self, forKey: .nativeEngine)
        self.oracleTool = try container.decode(ProducerIdentity.self, forKey: .oracleTool)
        self.oracleExecutableArtifact = try container.decode(
            TimingArtifactBinding.self,
            forKey: .oracleExecutableArtifact
        )
        self.inputArtifacts = try container.decode(
            [TimingArtifactBinding].self,
            forKey: .inputArtifacts
        )
        self.nativeOutputArtifact = try container.decode(
            TimingArtifactBinding.self,
            forKey: .nativeOutputArtifact
        )
        self.oracleOutputArtifact = try container.decode(
            TimingArtifactBinding.self,
            forKey: .oracleOutputArtifact
        )
        self.correlation = try container.decode(TimingCorrelationResult.self, forKey: .correlation)
        try validateStructure()
    }

    private static func isAuditable(_ artifact: TimingArtifactBinding) -> Bool {
        artifact.digest.algorithm == .sha256
            && isSHA256(artifact.digest.hexadecimalValue)
            && artifact.byteCount > 0
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

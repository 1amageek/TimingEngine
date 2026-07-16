import CircuiteFoundation
import Foundation
import TimingCore

public struct TimingExternalCorrelationReport: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var processID: String
    public var pdkVersion: String
    public var pdkManifestDigest: String
    public var corpusEvidenceDigest: String
    public var pdkManifestArtifact: ArtifactReference
    public var corpusEvidenceArtifact: ArtifactReference
    public var nativeEngine: ProducerIdentity
    public var oracleTool: ProducerIdentity
    public var oracleExecutableArtifact: ArtifactReference
    public var inputArtifacts: [ArtifactReference]
    public var nativeOutputArtifact: ArtifactReference
    public var oracleOutputArtifact: ArtifactReference
    public var correlation: TimingCorrelationResult

    public init(
        processID: String,
        pdkVersion: String,
        pdkManifestDigest: String,
        corpusEvidenceDigest: String,
        pdkManifestArtifact: ArtifactReference,
        corpusEvidenceArtifact: ArtifactReference,
        nativeEngine: ProducerIdentity,
        oracleTool: ProducerIdentity,
        oracleExecutableArtifact: ArtifactReference,
        inputArtifacts: [ArtifactReference],
        nativeOutputArtifact: ArtifactReference,
        oracleOutputArtifact: ArtifactReference,
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
              artifacts.allSatisfy({ $0.locator.location.storage == .workspaceRelative }) else {
            throw TimingError.invalidInput("External correlation contains an incomplete artifact reference.")
        }
        guard pdkManifestArtifact.locator.role == .input,
              corpusEvidenceArtifact.locator.role == .input,
              oracleExecutableArtifact.locator.role == .input,
              inputArtifacts.allSatisfy({ $0.locator.role == .input }),
              nativeOutputArtifact.locator.role == .output,
              oracleOutputArtifact.locator.role == .output else {
            throw TimingError.invalidInput("External correlation artifact roles do not match their semantics.")
        }
        guard pdkManifestArtifact.locator.kind == .technology,
              corpusEvidenceArtifact.locator.kind == .report,
              corpusEvidenceArtifact.locator.format == .json else {
            throw TimingError.invalidInput("External correlation evidence artifact kinds are invalid.")
        }
        guard correlation.oracleID == oracleTool.identifier else {
            throw TimingError.invalidInput("External correlation oracle identity does not match its tool identity.")
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

    private static func isAuditable(_ artifact: ArtifactReference) -> Bool {
        artifact.digest.algorithm == .sha256
            && isSHA256(artifact.digest.hexadecimalValue)
            && artifact.byteCount > 0
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

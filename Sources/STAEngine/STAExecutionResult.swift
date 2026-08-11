import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import TimingCore

/// Domain-owned STA result projected onto the Foundation evidence contracts.
public struct STAExecutionResult: Sendable, Hashable, Codable, ArtifactProducing,
    DiagnosticReporting, EvidenceProviding
{
    public let schemaVersion: SchemaVersion
    public let runID: String
    public let status: TimingExecutionStatus
    public let payload: STAPayload
    public let inputBindings: [TimingArtifactBinding]
    public let artifactBindings: [TimingArtifactBinding]
    public var artifacts: [ArtifactReference] { artifactBindings.map(\.reference) }
    public let diagnostics: [DesignDiagnostic]
    public let evidence: EvidenceManifest

    public init(
        runID: String,
        status: TimingExecutionStatus,
        payload: STAPayload,
        inputBindings: [TimingArtifactBinding] = [],
        artifactBindings: [TimingArtifactBinding] = [],
        diagnostics: [DesignDiagnostic] = [],
        provenance: ExecutionProvenance,
        schemaVersion: SchemaVersion = STARequest.currentSchemaVersion
    ) throws {
        guard schemaVersion == STARequest.currentSchemaVersion else {
            throw TimingError.invariantViolation("Unsupported STA execution result schema version.")
        }
        guard provenance.inputs == inputBindings.map(\.reference) else {
            throw TimingError.invariantViolation(
                "STA execution provenance inputs do not match the exact input bindings."
            )
        }
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.status = status
        self.payload = payload
        self.inputBindings = inputBindings
        self.artifactBindings = artifactBindings
        self.diagnostics = diagnostics
        self.evidence = try EvidenceManifest.contentAddressed(
            provenance: provenance,
            artifacts: artifactBindings.map(\.reference),
            digester: SHA256ContentDigester()
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        let decodedEvidence = try container.decode(EvidenceManifest.self, forKey: .evidence)
        try self.init(
            runID: container.decode(String.self, forKey: .runID),
            status: container.decode(TimingExecutionStatus.self, forKey: .status),
            payload: container.decode(STAPayload.self, forKey: .payload),
            inputBindings: container.decode(
                [TimingArtifactBinding].self,
                forKey: .inputBindings
            ),
            artifactBindings: container.decode(
                [TimingArtifactBinding].self,
                forKey: .artifactBindings
            ),
            diagnostics: container.decode([DesignDiagnostic].self, forKey: .diagnostics),
            provenance: decodedEvidence.provenance,
            schemaVersion: schemaVersion
        )
        guard evidence == decodedEvidence else {
            throw DecodingError.dataCorruptedError(
                forKey: .evidence,
                in: container,
                debugDescription: "STA evidence does not match the bound inputs, artifacts, or provenance."
            )
        }
    }
}

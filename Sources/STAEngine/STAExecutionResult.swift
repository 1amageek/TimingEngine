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

    internal var transformRetention: NativeSTATransformRetention? = nil

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
        try self.init(runID: runID, status: status, payload: payload, inputBindings: inputBindings,
            artifactBindings: artifactBindings, diagnostics: diagnostics, provenance: provenance,
            schemaVersion: schemaVersion, transformBudget: nil)
    }

    internal init(
        runID: String,
        status: TimingExecutionStatus,
        payload: STAPayload,
        inputBindings: [TimingArtifactBinding] = [],
        artifactBindings: [TimingArtifactBinding] = [],
        diagnostics: [DesignDiagnostic] = [],
        provenance: ExecutionProvenance,
        schemaVersion: SchemaVersion,
        transformBudget: NativeSTAStateBudget?
    ) throws {
        let budget = transformBudget ?? NativeSTAStateBudget(maximum: Int.max)
        let temporary = NativeSTATransformStorage(budget: budget, kind: .temporaryBytes)
        let retained = NativeSTATransformStorage(budget: budget, kind: .liveOwnedBytes)
        guard schemaVersion == STARequest.currentSchemaVersion else {
            throw TimingError.invariantViolation("Unsupported STA execution result schema version.")
        }
        guard provenance.inputs == (try temporary.map(inputBindings, \.reference)) else {
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
        let artifactReferences = try retained.map(artifactBindings, \.reference)
        self.evidence = try Self.makeEvidence(provenance: provenance, artifacts: artifactReferences, budget: budget)
        try retained.hold(payload.transformRetention)
        try retained.hold(self)
        transformRetention = try retained.finish()
    }

    /// Uses the dependency-owned construction cost; no private canonical encoding is duplicated here.
    private static func makeEvidence(provenance: ExecutionProvenance, artifacts: [ArtifactReference],
        budget: NativeSTAStateBudget) throws -> EvidenceManifest {
        guard budget.transformResources != nil else {
            return try EvidenceManifest.contentAddressed(provenance: provenance, artifacts: artifacts,
                digester: SHA256ContentDigester())
        }
        let canonical = try EvidenceManifest.canonicalizationCost(provenance: provenance, artifacts: artifacts,
            checkpoint: { try budget.chargeScheduledWork($0) })
        let digest = try SHA256ContentDigester.managedCost(byteCount: canonical.canonicalByteCount)
        let first = canonical.temporaryByteCount.addingReportingOverflow(digest.temporaryByteCount)
        let temporary = first.partialValue.addingReportingOverflow(digest.retainedByteCount)
        guard !first.overflow, !temporary.overflow,
              canonical.retainedByteCount == 0, let count = Int(exactly: temporary.partialValue) else {
            throw LibertySourceError.arithmeticOverflow
        }
        // The digester's returned 64-byte digest is temporary to this factory;
        // CF's canonical cost already covers its additional hex/parsing buffers.
        let lease = try budget.reservePayload(UInt8.self, capacity: count, kind: .temporaryBytes)
        try budget.chargeScheduledWork(canonical.workUnits)
        try budget.chargeScheduledWork(digest.workUnits)
        let result = try EvidenceManifest.contentAddressed(provenance: provenance, artifacts: artifacts,
            digester: SHA256ContentDigester())
        try budget.transformResources?.check()
        withExtendedLifetime(lease) {}
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, runID, status, payload, inputBindings, artifactBindings, diagnostics, evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        let decodedEvidence = try container.decode(EvidenceManifest.self, forKey: .evidence)
        let resources = try NativeSTADecodingResources.resources(decoder)
        let budget = resources.map { NativeSTAStateBudget(maximum: Int.max, transformResources: $0) }
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
            schemaVersion: schemaVersion,
            transformBudget: budget
        )
        guard evidence == decodedEvidence else {
            throw DecodingError.dataCorruptedError(
                forKey: .evidence,
                in: container,
                debugDescription: "STA evidence does not match the bound inputs, artifacts, or provenance."
            )
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.runID == rhs.runID
            && lhs.status == rhs.status
            && lhs.payload == rhs.payload
            && lhs.inputBindings == rhs.inputBindings
            && lhs.artifactBindings == rhs.artifactBindings
            && lhs.diagnostics == rhs.diagnostics
            && lhs.evidence == rhs.evidence
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(schemaVersion)
        hasher.combine(runID)
        hasher.combine(status)
        hasher.combine(payload)
        hasher.combine(inputBindings)
        hasher.combine(artifactBindings)
        hasher.combine(diagnostics)
        hasher.combine(evidence)
    }

}

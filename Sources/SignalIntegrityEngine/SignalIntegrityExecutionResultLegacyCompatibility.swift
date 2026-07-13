import CircuiteFoundation
import Foundation
import TimingCore
import XcircuitePackage

/// Compatibility projection from the retired Xcircuite result envelope.
extension SignalIntegrityExecutionResult {
    init(
        legacy: XcircuiteEngineResultEnvelope<SignalIntegrityPayload>,
        request: SignalIntegrityFoundationRequest,
        bridge: TimingFoundationArtifactBridge = TimingFoundationArtifactBridge()
    ) throws {
        guard request.schemaVersion == SignalIntegrityFoundationRequest.currentSchemaVersion else {
            throw TimingFoundationBoundaryError.unsupportedSchemaVersion(
                expected: SignalIntegrityFoundationRequest.currentSchemaVersion,
                actual: request.schemaVersion
            )
        }
        guard legacy.runID == request.runID else {
            throw TimingFoundationBoundaryError.resultIdentityMismatch(
                expected: request.runID,
                actual: legacy.runID
            )
        }
        let producer: ProducerIdentity
        do {
            producer = try ProducerIdentity(
                kind: .engine,
                identifier: legacy.metadata.engineID,
                version: legacy.metadata.implementationVersion,
                build: legacy.metadata.implementationID
            )
        } catch {
            throw TimingFoundationBoundaryError.invalidArtifactIdentity(
                "producer=\(legacy.metadata.engineID)"
            )
        }
        let artifacts = try legacy.artifacts.map { artifact in
            try bridge.foundationReference(
                from: artifact,
                defaultKind: .report,
                defaultFormat: .json,
                producer: producer
            )
        }
        let diagnostics = try legacy.diagnostics.map { diagnostic in
            try bridge.foundationDiagnostic(
                from: diagnostic,
                namespace: "timing.signal_integrity",
                subjectKind: .net
            )
        }
        let provenance: ExecutionProvenance
        do {
            provenance = try ExecutionProvenance(
                producer: producer,
                inputs: request.inputs,
                configurationDigest: request.configurationDigest,
                designRevision: request.designRevision ?? request.design.digest,
                randomSeed: request.randomSeed,
                startedAt: legacy.metadata.startedAt,
                completedAt: legacy.metadata.completedAt
            )
        } catch {
            throw TimingFoundationBoundaryError.invalidArtifactIdentity(
                "execution-provenance"
            )
        }
        self.init(
            runID: legacy.runID,
            status: Self.status(for: legacy.status),
            payload: legacy.payload,
            artifacts: artifacts,
            diagnostics: diagnostics,
            provenance: provenance,
            schemaVersion: .v1
        )
    }

    private static func status(
        for status: XcircuiteEngineExecutionStatus
    ) -> TimingExecutionStatus {
        switch status {
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .blocked:
            return .blocked
        case .cancelled:
            return .cancelled
        }
    }
}

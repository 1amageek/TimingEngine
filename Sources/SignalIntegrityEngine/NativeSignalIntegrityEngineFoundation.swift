import Foundation
import CircuiteFoundation
import LogicIR
import PDKCore
import TimingCore
import XcircuitePackage

/// Foundation-native signal-integrity engine.
public struct NativeSignalIntegrityEngine: SignalIntegrityFoundationEngine {
    private let compatibilityBackend: any LegacySignalIntegrityAnalyzing
    public let reader: any TimingArtifactReading
    public let artifactStore: (any TimingArtifactStoring)?
    public let workspaceRoot: URL?

    public init(
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil
    ) {
        self.reader = reader
        self.compatibilityBackend = LegacyNativeSignalIntegrityEngine(
            reader: LegacyTimingArtifactReaderAdapter(
                reader: reader
            )
        )
        self.artifactStore = artifactStore
        self.workspaceRoot = workspaceRoot
    }

    internal init(
        compatibilityBackend: any LegacySignalIntegrityAnalyzing,
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil
    ) {
        self.compatibilityBackend = compatibilityBackend
        self.reader = reader
        self.artifactStore = artifactStore
        self.workspaceRoot = workspaceRoot
    }

    public func execute(
        _ request: SignalIntegrityFoundationRequest
    ) async throws -> SignalIntegrityExecutionResult {
        let legacyRequest = try makeLegacyRequest(request)
        let legacyResult = try await compatibilityBackend.execute(legacyRequest)
        let foundationResult = try SignalIntegrityExecutionResult(legacy: legacyResult, request: request)
        guard let artifactStore else { return foundationResult }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = try await artifactStore.store(
            try encoder.encode(foundationResult.payload),
            artifactID: try ArtifactID(rawValue: "timing-signal-integrity-report"),
            runID: request.runID,
            kind: .report,
            format: .json,
            producer: foundationResult.evidence.provenance.producer
        )
        return SignalIntegrityExecutionResult(
            runID: foundationResult.runID,
            status: foundationResult.status,
            payload: foundationResult.payload,
            artifacts: foundationResult.artifacts + [report],
            diagnostics: foundationResult.diagnostics,
            provenance: foundationResult.evidence.provenance,
            schemaVersion: foundationResult.schemaVersion
        )
    }

    private func makeLegacyRequest(
        _ request: SignalIntegrityFoundationRequest
    ) throws -> SignalIntegrityRequest {
        let bridge = TimingFoundationArtifactBridge()
        let designArtifact = try bridge.legacyReference(
            from: request.design,
            kind: .netlist,
            format: .json,
            runID: request.runID,
            workspaceRoot: workspaceRoot
        )
        let constraintsArtifact = try bridge.legacyReference(
            from: request.constraints,
            kind: .constraint,
            format: .sdc,
            runID: request.runID,
            workspaceRoot: workspaceRoot
        )
        let pdkArtifact = try bridge.legacyReference(
            from: request.pdkManifest,
            kind: .technology,
            format: .json,
            runID: request.runID,
            workspaceRoot: workspaceRoot
        )
        let parasiticsArtifact = try bridge.legacyReference(
            from: request.parasitics,
            kind: .parasitic,
            format: .spef,
            runID: request.runID,
            workspaceRoot: workspaceRoot
        )
        let pdkDigest = request.pdkDigest?.hexadecimalValue
            ?? request.pdkManifest.digest.hexadecimalValue
        return SignalIntegrityRequest(
            runID: request.runID,
            inputs: [designArtifact, constraintsArtifact, pdkArtifact, parasiticsArtifact],
            design: LogicDesignReference(
                artifact: designArtifact,
                topDesignName: request.topDesignName,
                designDigest: request.designRevision?.hexadecimalValue
                    ?? request.design.digest.hexadecimalValue,
                provenance: LogicDesignProvenance(
                    sourceDesignDigest: request.designRevision?.hexadecimalValue
                        ?? request.design.digest.hexadecimalValue,
                    inputDesignDigest: request.design.digest.hexadecimalValue,
                    producerID: "timing.foundation.request",
                    producerVersion: "1",
                    runID: request.runID
                )
            ),
            constraints: TimingConstraintReference(
                artifact: constraintsArtifact,
                modeIDs: request.requestedModeIDs
            ),
            pdk: PDKReference(
                manifest: pdkArtifact,
                processID: request.processID,
                version: request.pdkVersion,
                digest: pdkDigest
            ),
            parasitics: parasiticsArtifact,
            maxDeltaDelay: request.maxDeltaDelay,
            maxNoiseRatio: request.maxNoiseRatio
        )
    }
}

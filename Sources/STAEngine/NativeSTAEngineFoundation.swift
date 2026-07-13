import Foundation
import CircuiteFoundation
import LogicIR
import PDKCore
import TimingCore
import XcircuitePackage

/// Foundation-native STA engine.
///
/// The retained legacy backend is injected only as an explicit compatibility
/// implementation. Requests and results crossing this public seam are always
/// CircuiteFoundation values.
public struct NativeSTAEngine: STAFoundationEngine {
    private let compatibilityBackend: any LegacySTAAnalyzing
    public let reader: any TimingArtifactReading
    public let artifactStore: (any TimingArtifactStoring)?
    public let workspaceRoot: URL?

    public init(
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil
    ) {
        self.reader = reader
        self.compatibilityBackend = LegacyNativeSTAEngine(
            reader: LegacyTimingArtifactReaderAdapter(
                reader: reader
            )
        )
        self.artifactStore = artifactStore
        self.workspaceRoot = workspaceRoot
    }

    internal init(
        compatibilityBackend: any LegacySTAAnalyzing,
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil
    ) {
        self.compatibilityBackend = compatibilityBackend
        self.reader = reader
        self.artifactStore = artifactStore
        self.workspaceRoot = workspaceRoot
    }

    public func execute(_ request: STAFoundationRequest) async throws -> STAExecutionResult {
        let legacyRequest = try makeLegacyRequest(request)
        let legacyResult = try await compatibilityBackend.execute(legacyRequest)
        let foundationResult = try STAExecutionResult(legacy: legacyResult, request: request)
        guard let artifactStore else { return foundationResult }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = try await artifactStore.store(
            try encoder.encode(foundationResult.payload),
            artifactID: try ArtifactID(rawValue: "timing-sta-report"),
            runID: request.runID,
            kind: .report,
            format: .json,
            producer: foundationResult.evidence.provenance.producer
        )
        return STAExecutionResult(
            runID: foundationResult.runID,
            status: foundationResult.status,
            payload: foundationResult.payload,
            artifacts: foundationResult.artifacts + [report],
            diagnostics: foundationResult.diagnostics,
            provenance: foundationResult.evidence.provenance,
            schemaVersion: foundationResult.schemaVersion
        )
    }

    private func makeLegacyRequest(_ request: STAFoundationRequest) throws -> STARequest {
        let bridge = TimingFoundationArtifactBridge()
        let designArtifact = try bridge.legacyReference(
            from: request.design,
            kind: .netlist,
            format: .json,
            runID: request.runID,
            workspaceRoot: workspaceRoot
        )
        let libraryReferences = try request.libraries.map { library in
            TimingLibraryReference(
                artifact: try bridge.legacyReference(
                    from: library.artifact,
                    kind: .timingLibrary,
                    format: .liberty,
                    runID: request.runID,
                    workspaceRoot: workspaceRoot
                ),
                cornerIDs: library.cornerIDs
            )
        }
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
        let parasitics = try request.parasitics.map { artifact in
            try bridge.legacyReference(
                from: artifact,
                kind: .parasitic,
                format: .spef,
                runID: request.runID,
                workspaceRoot: workspaceRoot
            )
        }
        let pdkDigest = request.pdkDigest?.hexadecimalValue
            ?? request.pdkManifest.digest.hexadecimalValue
        let legacyInputs = [designArtifact]
            + libraryReferences.map(\.artifact)
            + [constraintsArtifact, pdkArtifact]
            + (parasitics.map { [$0] } ?? [])
        return STARequest(
            runID: request.runID,
            inputs: legacyInputs,
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
            libraries: libraryReferences,
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
            parasitics: parasitics,
            requestedModeIDs: request.requestedModeIDs,
            requestedCornerIDs: request.requestedCornerIDs,
            analysisKinds: request.analysisKinds,
            maxPaths: request.maxPaths,
            requiresSignoff: request.requiresSignoff,
            variation: request.variation
        )
    }
}

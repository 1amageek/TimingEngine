import Foundation
import LogicIR
import PDKCore
import TimingCore
import XcircuitePackage

/// Foundation-facing adapter for the native STA implementation.
public struct NativeSTAFoundationEngine: STAFoundationEngine {
    public let legacyEngine: any STAAnalyzing
    public let workspaceRoot: URL?

    public init(
        legacyEngine: any STAAnalyzing = NativeSTAEngine(),
        workspaceRoot: URL? = nil
    ) {
        self.legacyEngine = legacyEngine
        self.workspaceRoot = workspaceRoot
    }

    public func execute(_ request: STAFoundationRequest) async throws -> STAExecutionResult {
        guard request.schemaVersion == STAFoundationRequest.currentSchemaVersion else {
            throw TimingFoundationBoundaryError.unsupportedSchemaVersion(
                expected: STAFoundationRequest.currentSchemaVersion,
                actual: request.schemaVersion
            )
        }
        let legacyRequest = try makeLegacyRequest(request)
        let legacyResult = try await legacyEngine.execute(legacyRequest)
        return try STAExecutionResult(
            legacy: legacyResult,
            request: request
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
                    ?? request.design.digest.hexadecimalValue
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

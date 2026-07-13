import Foundation
import LogicIR
import PDKCore
import TimingCore
import XcircuitePackage

/// Foundation-facing adapter for the native signal-integrity implementation.
@available(*, deprecated, message: "Use NativeSignalIntegrityEngine.")
public struct NativeSignalIntegrityFoundationEngine: SignalIntegrityFoundationEngine {
    public let legacyEngine: any LegacySignalIntegrityAnalyzing
    public let workspaceRoot: URL?

    public init(
        legacyEngine: any LegacySignalIntegrityAnalyzing = LegacyNativeSignalIntegrityEngine(),
        workspaceRoot: URL? = nil
    ) {
        self.legacyEngine = legacyEngine
        self.workspaceRoot = workspaceRoot
    }

    public func execute(
        _ request: SignalIntegrityFoundationRequest
    ) async throws -> SignalIntegrityExecutionResult {
        guard request.schemaVersion == SignalIntegrityFoundationRequest.currentSchemaVersion else {
            throw TimingFoundationBoundaryError.unsupportedSchemaVersion(
                expected: SignalIntegrityFoundationRequest.currentSchemaVersion,
                actual: request.schemaVersion
            )
        }
        let legacyRequest = try makeLegacyRequest(request)
        let legacyResult = try await legacyEngine.execute(legacyRequest)
        return try SignalIntegrityExecutionResult(
            legacy: legacyResult,
            request: request
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
                    ?? request.design.digest.hexadecimalValue
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

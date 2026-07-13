import Foundation
import LogicIR
import PDKCore
import TimingCore
import XcircuitePackage

@available(*, deprecated, message: "Use NativeSignalIntegrityEngine Foundation execution or NativeSignalIntegrityFoundationEngine.")
public struct LegacyNativeSignalIntegrityEngine: SignalIntegrityAnalyzing {
    public let reader: any LegacyTimingArtifactReading
    public let artifactStore: (any LegacyTimingArtifactStoring)?
    public let parasiticParser: any TimingParasiticParsing
    public let constraintParser: any TimingConstraintParsing

    public init(
        reader: any LegacyTimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any LegacyTimingArtifactStoring)? = nil,
        parasiticParser: any TimingParasiticParsing = SPEFParser(),
        constraintParser: any TimingConstraintParsing = SDCParser()
    ) {
        self.reader = reader
        self.artifactStore = artifactStore
        self.parasiticParser = parasiticParser
        self.constraintParser = constraintParser
    }

    public func execute(_ request: SignalIntegrityRequest) async throws -> XcircuiteEngineResultEnvelope<SignalIntegrityPayload> {
        let startedAt = Date()
        do {
            _ = try await reader.read(request.design.artifact)
            _ = try await reader.read(request.pdk.manifest)
            let constraintsData = try await reader.read(request.constraints.artifact)
            let modeIDs = request.constraints.modeIDs.isEmpty ? ["default"] : request.constraints.modeIDs
            for modeID in modeIDs {
                _ = try constraintParser.parse(constraintsData, modeID: modeID)
            }
            let parasitics = try parasiticParser.parse(try await reader.read(request.parasitics))
            let provenanceIssues = LogicDesignProvenanceValidation.issues(for: request.design)
            guard provenanceIssues.isEmpty else {
                return provenanceBlockedEnvelope(
                    request: request,
                    startedAt: startedAt,
                    issues: provenanceIssues
                )
            }
            if parasitics.couplings.contains(where: { parasitics.network(named: $0.firstNet)?.resistance ?? 0 <= 0 }) {
                throw TimingError.unsupportedSemantic(
                    format: "SPEF",
                    semantic: "coupling delta delay without victim resistance"
                )
            }
            let summaries = parasitics.couplings.map { coupling in
                let victim = parasitics.network(named: coupling.firstNet)
                let ground = max(victim?.groundCapacitance ?? 0, Double.leastNonzeroMagnitude)
                let resistance = max(victim?.resistance ?? 0, 0)
                let noiseRatio = coupling.capacitance / (ground + coupling.capacitance)
                let deltaDelay = 0.69 * resistance * coupling.capacitance
                return SINetSummary(
                    victimNet: coupling.firstNet,
                    aggressorNet: coupling.secondNet,
                    couplingCapacitance: coupling.capacitance,
                    noiseRatio: noiseRatio,
                    deltaDelay: deltaDelay
                )
            }
            let violations = summaries.filter {
                $0.deltaDelay > request.maxDeltaDelay || $0.noiseRatio > request.maxNoiseRatio
            }.map {
                SIViolation(
                    victimNet: $0.victimNet,
                    aggressorNet: $0.aggressorNet,
                    deltaDelay: $0.deltaDelay,
                    noiseRatio: $0.noiseRatio,
                    suggestedActions: ["reduce_coupling", "increase_victim_drive", "rerun_pex_with_coupling"]
                )
            }
            let provenance = TimingArtifactProvenance(
                designDigest: request.design.designDigest.isEmpty ? request.design.artifact.sha256 : request.design.designDigest,
                libraryDigests: [],
                constraintDigest: request.constraints.artifact.sha256,
                pdkDigest: request.pdk.digest.isEmpty ? request.pdk.manifest.sha256 : request.pdk.digest,
                parasiticsDigest: request.parasitics.sha256
            )
            let provenanceDiagnostics: [XcircuiteEngineDiagnostic] = provenance.hasCoreDigests
                ? []
                : [XcircuiteEngineDiagnostic(
                    severity: .warning,
                    code: "INCOMPLETE_TIMING_PROVENANCE",
                    message: "The signal-integrity verdict is missing one or more immutable input digests.",
                    suggestedActions: ["record_design_digest", "record_constraint_digest", "record_pdk_digest", "record_parasitic_digest"]
                )]
            let payload = SignalIntegrityPayload(
                violationCount: violations.count,
                worstDeltaDelay: summaries.map(\.deltaDelay).max(),
                worstNoiseRatio: summaries.map(\.noiseRatio).max(),
                analyzedModes: modeIDs,
                analyzedNets: summaries,
                violations: violations,
                signoffEligible: provenance.isCompleteForSignalIntegrity,
                provenance: provenance
            )
            var artifacts: [XcircuiteFileReference] = []
            if let artifactStore {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                artifacts.append(try await artifactStore.store(
                    try encoder.encode(payload),
                    artifactID: "timing-signal-integrity-report",
                    runID: request.runID,
                    format: .json
                ))
            }
            let diagnostics = violations.map {
                XcircuiteEngineDiagnostic(
                    severity: .error,
                    code: "SI_CROSSTALK_VIOLATION",
                    message: "Crosstalk on \($0.victimNet) from \($0.aggressorNet) exceeds the configured limit.",
                    entity: $0.victimNet,
                    suggestedActions: $0.suggestedActions
                )
            } + provenanceDiagnostics
            return XcircuiteEngineResultEnvelope(
                schemaVersion: SignalIntegrityRequest.currentSchemaVersion,
                runID: request.runID,
                status: .completed,
                diagnostics: diagnostics,
                artifacts: artifacts,
                metadata: XcircuiteEngineExecutionMetadata(
                    engineID: "timing.signal-integrity",
                    implementationID: "native-signal-integrity",
                    implementationVersion: "1.1.0",
                    startedAt: startedAt,
                    completedAt: Date()
                ),
                payload: payload
            )
        } catch let error as TimingError {
            if case .artifactWriteFailed = error {
                return failedEnvelope(request: request, startedAt: startedAt, error: error)
            }
            return blockedEnvelope(request: request, startedAt: startedAt, error: error)
        } catch {
            return XcircuiteEngineResultEnvelope(
                schemaVersion: SignalIntegrityRequest.currentSchemaVersion,
                runID: request.runID,
                status: .failed,
                diagnostics: [XcircuiteEngineDiagnostic(
                    severity: .error,
                    code: "SI_EXECUTION_FAILED",
                    message: error.localizedDescription,
                    suggestedActions: ["inspect_input_artifacts", "reproduce_with_timing_cli"]
                )],
                metadata: XcircuiteEngineExecutionMetadata(
                    engineID: "timing.signal-integrity",
                    implementationID: "native-signal-integrity",
                    implementationVersion: "1.1.0",
                    startedAt: startedAt,
                    completedAt: Date()
                ),
                payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil)
            )
        }
    }

    private func blockedEnvelope(
        request: SignalIntegrityRequest,
        startedAt: Date,
        error: TimingError
    ) -> XcircuiteEngineResultEnvelope<SignalIntegrityPayload> {
        XcircuiteEngineResultEnvelope(
            schemaVersion: SignalIntegrityRequest.currentSchemaVersion,
            runID: request.runID,
            status: .blocked,
            diagnostics: [XcircuiteEngineDiagnostic(
                severity: .error,
                code: "SI_\(code(for: error))",
                message: error.localizedDescription,
                suggestedActions: ["inspect_input_artifacts", "check_spef_coupling_data"]
            )],
            metadata: XcircuiteEngineExecutionMetadata(
                engineID: "timing.signal-integrity",
                implementationID: "native-signal-integrity",
                implementationVersion: "1.1.0",
                startedAt: startedAt,
                completedAt: Date()
            ),
            payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil)
        )
    }

    private func provenanceBlockedEnvelope(
        request: SignalIntegrityRequest,
        startedAt: Date,
        issues: [LogicDesignProvenanceValidation.Issue]
    ) -> XcircuiteEngineResultEnvelope<SignalIntegrityPayload> {
        XcircuiteEngineResultEnvelope(
            schemaVersion: SignalIntegrityRequest.currentSchemaVersion,
            runID: request.runID,
            status: .blocked,
            diagnostics: issues.map { issue in
                XcircuiteEngineDiagnostic(
                    severity: .error,
                    code: issue.diagnosticCode,
                    message: issue.message,
                    suggestedActions: ["repair_design_provenance", "recreate_design_handoff"]
                )
            },
            metadata: XcircuiteEngineExecutionMetadata(
                engineID: "timing.signal-integrity",
                implementationID: "native-signal-integrity",
                implementationVersion: "1.1.0",
                startedAt: startedAt,
                completedAt: Date()
            ),
            payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil)
        )
    }

    private func failedEnvelope(
        request: SignalIntegrityRequest,
        startedAt: Date,
        error: TimingError
    ) -> XcircuiteEngineResultEnvelope<SignalIntegrityPayload> {
        XcircuiteEngineResultEnvelope(
            schemaVersion: SignalIntegrityRequest.currentSchemaVersion,
            runID: request.runID,
            status: .failed,
            diagnostics: [XcircuiteEngineDiagnostic(
                severity: .error,
                code: "SI_ARTIFACT_WRITE_FAILED",
                message: error.localizedDescription,
                suggestedActions: ["inspect_output_directory", "retry_with_writable_artifact_store"]
            )],
            metadata: XcircuiteEngineExecutionMetadata(
                engineID: "timing.signal-integrity",
                implementationID: "native-signal-integrity",
                implementationVersion: "1.1.0",
                startedAt: startedAt,
                completedAt: Date()
            ),
            payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil)
        )
    }

    private func code(for error: TimingError) -> String {
        switch error {
        case .parseFailure: return "PARSE_FAILED"
        case .missingArtifact: return "MISSING_ARTIFACT"
        case .artifactReadFailed: return "ARTIFACT_READ_FAILED"
        case .artifactDigestMismatch: return "ARTIFACT_DIGEST_MISMATCH"
        case .artifactSizeMismatch: return "ARTIFACT_SIZE_MISMATCH"
        case .unsupportedSemantic: return "UNSUPPORTED_SEMANTIC"
        case .invalidInput: return "INVALID_INPUT"
        case .artifactWriteFailed: return "ARTIFACT_WRITE_FAILED"
        case .invariantViolation: return "INVARIANT_VIOLATION"
        }
    }
}

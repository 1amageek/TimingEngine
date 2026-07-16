import Foundation
import LogicIR
import PDKCore
import TimingCore

public struct NativeSignalIntegrityEngine: SignalIntegrityFoundationEngine {
    public typealias Request = SignalIntegrityFoundationRequest
    public typealias Output = SignalIntegrityExecutionResult
    public let reader: any TimingArtifactReading
    public let artifactStore: (any TimingArtifactStoring)?
    public let parasiticParser: any TimingParasiticParsing
    public let constraintParser: any TimingConstraintParsing

    public init(
        reader: (any TimingArtifactReading)? = nil,
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil,
        parasiticParser: any TimingParasiticParsing = SPEFParser(),
        constraintParser: any TimingConstraintParsing = SDCParser()
    ) {
        self.reader = reader ?? FileSystemTimingArtifactReader(workspaceRoot: workspaceRoot)
        self.artifactStore = artifactStore
        self.parasiticParser = parasiticParser
        self.constraintParser = constraintParser
    }

    public func execute(_ request: SignalIntegrityFoundationRequest) async throws -> SignalIntegrityExecutionResult {
        let startedAt = Date()
        do {
            _ = try await reader.read(
                request.design
            )
            _ = try await reader.read(
                request.pdkManifest
            )
            let constraintsData = try await reader.read(request.constraints)
            let modeIDs = request.requestedModeIDs.isEmpty ? ["default"] : request.requestedModeIDs
            for modeID in modeIDs {
                _ = try constraintParser.parse(constraintsData, modeID: modeID)
            }
            let parasitics = try parasiticParser.parse(try await reader.read(request.parasitics))
            let provenanceIssues = LogicDesignProvenanceValidation.issues(for: logicDesignReference(for: request))
            guard provenanceIssues.isEmpty else {
                return try provenanceBlockedEnvelope(
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
                designDigest: request.designRevision?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
                libraryDigests: [],
                constraintDigest: request.constraints.digest.hexadecimalValue,
                pdkDigest: request.pdkDigest?.hexadecimalValue ?? request.pdkManifest.digest.hexadecimalValue,
                parasiticsDigest: request.parasitics.digest.hexadecimalValue
            )
            let provenanceDiagnostics: [DesignDiagnostic] = provenance.hasCoreDigests
                ? []
                : [DesignDiagnostic(
                    severity: .warning,
                    code: "timing.signal_integrity.incomplete_timing_provenance",
                    message: "The signal-integrity verdict is missing one or more immutable input digests.",
                    suggestedActions: ["timing.signal_integrity.action.record_design_digest", "timing.signal_integrity.action.record_constraint_digest", "timing.signal_integrity.action.record_pdk_digest", "timing.signal_integrity.action.record_parasitic_digest"]
                )]
            let payload = SignalIntegrityPayload(
                violationCount: violations.count,
                worstDeltaDelay: summaries.map(\.deltaDelay).max(),
                worstNoiseRatio: summaries.map(\.noiseRatio).max(),
                analyzedModes: modeIDs,
                analyzedNets: summaries,
                violations: violations,
                provenance: provenance
            )
            var artifacts: [ArtifactReference] = []
            if let artifactStore {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                artifacts.append(try await artifactStore.store(
                    try encoder.encode(payload),
                    artifactID: try ArtifactID(rawValue: "timing-signal-integrity-report"),
                    runID: request.runID,
                    kind: .report,
                    format: .json,
                    producer: nil
                ))
            }
            let diagnostics = try violations.map { violation in
                DesignDiagnostic(
                    code: try DiagnosticCode(rawValue: "timing.signal_integrity.si_crosstalk_violation"),
                    severity: .error,
                    summary: "Crosstalk on \(violation.victimNet) from \(violation.aggressorNet) exceeds the configured limit.",
                    subject: try DesignObjectReference(kind: .net, identifier: violation.victimNet),
                    suggestedActions: violation.suggestedActions.map { SuggestedAction(code: $0, summary: $0) }
                )
            } + provenanceDiagnostics
            return SignalIntegrityExecutionResult(
                runID: request.runID,
                status: .completed,
                payload: payload,
                artifacts: artifacts,
                diagnostics: diagnostics,
                provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
                schemaVersion: SignalIntegrityFoundationRequest.currentSchemaVersion
            )
        } catch let error as TimingError {
            if case .artifactWriteFailed = error {
                return try failedEnvelope(request: request, startedAt: startedAt, error: error)
            }
            return try blockedEnvelope(request: request, startedAt: startedAt, error: error)
        } catch {
            return SignalIntegrityExecutionResult(
                runID: request.runID,
                status: .failed,
                payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil),
                diagnostics: [DesignDiagnostic(
                    severity: .error,
                    code: "timing.signal_integrity.execution_failed",
                    message: error.localizedDescription,
                    suggestedActions: ["inspect_input_artifacts", "reproduce_with_timing_cli"]
                )],
                provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
                schemaVersion: SignalIntegrityFoundationRequest.currentSchemaVersion
            )
        }
    }

    private func blockedEnvelope(
        request: SignalIntegrityFoundationRequest,
        startedAt: Date,
        error: TimingError
    ) throws -> SignalIntegrityExecutionResult {
        SignalIntegrityExecutionResult(
            runID: request.runID,
            status: .blocked,
            payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil),
            diagnostics: [DesignDiagnostic(
                severity: .error,
                code: code(for: error),
                message: error.localizedDescription,
                suggestedActions: ["inspect_input_artifacts", "check_spef_coupling_data"]
            )],
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: SignalIntegrityFoundationRequest.currentSchemaVersion
        )
    }

    private func provenanceBlockedEnvelope(
        request: SignalIntegrityFoundationRequest,
        startedAt: Date,
        issues: [LogicDesignProvenanceValidation.Issue]
    ) throws -> SignalIntegrityExecutionResult {
        SignalIntegrityExecutionResult(
            runID: request.runID,
            status: .blocked,
            payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil),
            diagnostics: issues.map { issue in
                DesignDiagnostic(
                    severity: .error,
                    code: issue.diagnosticCode,
                    message: issue.message,
                    suggestedActions: ["repair_design_provenance", "recreate_design_handoff"]
                )
            },
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: SignalIntegrityFoundationRequest.currentSchemaVersion
        )
    }

    private func failedEnvelope(
        request: SignalIntegrityFoundationRequest,
        startedAt: Date,
        error: TimingError
    ) throws -> SignalIntegrityExecutionResult {
        SignalIntegrityExecutionResult(
            runID: request.runID,
            status: .failed,
            payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil),
            diagnostics: [DesignDiagnostic(
                severity: .error,
                code: "timing.signal_integrity.artifact_write_failed",
                message: error.localizedDescription,
                suggestedActions: ["inspect_output_directory", "retry_with_writable_artifact_store"]
            )],
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: SignalIntegrityFoundationRequest.currentSchemaVersion
        )
    }

    private func code(for error: TimingError) -> String {
        switch error {
        case .parseFailure: return "timing.signal_integrity.parse_failed"
        case .missingArtifact: return "timing.signal_integrity.missing_artifact"
        case .artifactReadFailed: return "timing.signal_integrity.artifact_read_failed"
        case .artifactDigestMismatch: return "timing.signal_integrity.artifact_digest_mismatch"
        case .artifactSizeMismatch: return "timing.signal_integrity.artifact_size_mismatch"
        case .unsupportedSemantic: return "timing.signal_integrity.unsupported_semantic"
        case .invalidInput: return "timing.signal_integrity.invalid_input"
        case .artifactWriteFailed: return "timing.signal_integrity.artifact_write_failed"
        case .invariantViolation: return "timing.signal_integrity.invariant_violation"
        }
    }

    private func makeProvenance(
        startedAt: Date,
        completedAt: Date,
        inputs: [ArtifactReference]
    ) throws -> ExecutionProvenance {
        try ExecutionProvenance(
            producer: ProducerIdentity(
                kind: .engine,
                identifier: "timing.signal-integrity",
                version: "1.1.0"
            ),
            inputs: inputs,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
    private func logicDesignReference(for request: SignalIntegrityFoundationRequest) -> LogicDesignReference {
        LogicDesignReference(
            artifact: request.design.locator,
            topDesignName: request.topDesignName,
            designDigest: request.designRevision?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
            provenance: LogicDesignProvenance(
                sourceDesignDigest: request.designRevision?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
                inputDesignDigest: request.design.digest.hexadecimalValue,
                producerID: "timing.foundation",
                producerVersion: "1",
                runID: request.runID
            )
        )
    }
}

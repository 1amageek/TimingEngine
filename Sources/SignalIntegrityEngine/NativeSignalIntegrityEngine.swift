import Foundation
import CircuiteFoundation
import LogicIR
import PDKCore
import TimingCore

public struct NativeSignalIntegrityEngine: SignalIntegrityExecuting {
    public static let capability = TimingCapability(
        engineID: "timing.signal-integrity",
        supportedInputFormats: [.json, .verilog, .sdc, .spef],
        supportedOutputFormats: [.json],
        features: ["foundation-request", "coupling-capacitance", "delta-delay", "noise-ratio", "provenance-digests", "artifact-persistence"],
        limitations: ["waveform-resolved-noise", "process-qualified-signoff", "equipotential-cap-load", "distributed-rc-dynamics-not-evaluated"]
    )

    public typealias Request = SignalIntegrityRequest
    public typealias Output = SignalIntegrityExecutionResult
    public let reader: any TimingArtifactReading
    public let artifactStore: (any TimingArtifactStoring)?
    public let parasiticParser: any TimingParasiticParsing
    public let constraintParser: any TimingConstraintParsing
    public let parasiticReducer: any TimingParasiticReducing

    public init(
        reader: (any TimingArtifactReading)? = nil,
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil,
        parasiticParser: any TimingParasiticParsing = SPEFParser(),
        constraintParser: any TimingConstraintParsing = SDCParser(),
        parasiticReducer: any TimingParasiticReducing = EquipotentialTimingParasiticReducer()
    ) {
        self.reader = reader ?? FileSystemTimingArtifactReader(workspaceRoot: workspaceRoot)
        self.artifactStore = artifactStore
        self.parasiticParser = parasiticParser
        self.constraintParser = constraintParser
        self.parasiticReducer = parasiticReducer
    }

    public func execute(_ request: SignalIntegrityRequest) async throws -> SignalIntegrityExecutionResult {
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
            let canonicalReport = TimingCanonicalValidator()
                .validateSignalIntegrityParasitics(parasitics)
            guard canonicalReport.isValid else {
                throw TimingError.invalidInput(
                    "Canonical signal-integrity validation failed: "
                        + canonicalReport.findings.map(\.code).sorted().joined(separator: ", ")
                )
            }
            let provenanceIssues = LogicDesignProvenanceValidation.issues(for: logicDesignReference(for: request))
            guard provenanceIssues.isEmpty else {
                return try provenanceBlockedEnvelope(
                    request: request,
                    startedAt: startedAt,
                    issues: provenanceIssues
                )
            }
            let reduced = try parasiticReducer.reduce(parasitics)
            var summaries: [SINetSummary] = []
            for coupling in reduced.couplings {
                for victimNet in coupling.declaredVictims {
                    guard let victim = parasitics.network(named: victimNet), victim.resistanceInventory > 0 else {
                        throw TimingError.unsupportedSemantic(format: "SPEF", semantic: "coupling delta delay without victim resistance")
                    }
                    let ground = reduced.groundCapacitances[victimNet] ?? 0
                    let denominator = ground + coupling.capacitance
                    let noiseRatio = denominator == 0 ? 0 : coupling.capacitance / denominator
                    let deltaDelay = 0.69 * victim.resistanceInventory * coupling.capacitance
                    guard denominator.isFinite, noiseRatio.isFinite, deltaDelay.isFinite else {
                        throw TimingError.invalidInput("Signal-integrity numerical aggregate overflow.")
                    }
                    summaries.append(SINetSummary(victimNet: victimNet,
                        aggressorNet: coupling.firstNet == victimNet ? coupling.secondNet : coupling.firstNet,
                        couplingCapacitance: coupling.capacitance, noiseRatio: noiseRatio, deltaDelay: deltaDelay))
                }
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
                designDigest: request.canonicalDesignDigest?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
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
                parasiticReduction: reduced.evidence,
                provenance: provenance
            )
            var artifactBindings: [TimingArtifactBinding] = []
            if let artifactStore {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                artifactBindings.append(try await artifactStore.store(
                    try encoder.encode(payload),
                    artifactName: "timing-signal-integrity-report",
                    runID: request.runID,
                    kind: .report,
                    format: .json
                ))
            }
            let diagnostics = try violations.map { violation in
                DesignDiagnostic(
                    code: try DiagnosticCode(rawValue: "timing.signal_integrity.si_crosstalk_violation"),
                    severity: .error,
                    summary: "Crosstalk on \(violation.victimNet) from \(violation.aggressorNet) exceeds the configured limit.",
                    subject: .path(
                        try DesignPathReference(
                            facetID: DesignFacetID(rawValue: "timing"),
                            kindID: DesignEntityKindID(rawValue: "net"),
                            localIdentifier: violation.victimNet
                        )
                    ),
                    suggestedActions: violation.suggestedActions.map { SuggestedAction(code: $0, summary: $0) }
                )
            } + provenanceDiagnostics + reduced.evidence.diagnostics(prefix: "timing.signal_integrity")
            return try SignalIntegrityExecutionResult(
                runID: request.runID,
                status: .completed,
                payload: payload,
                inputBindings: request.artifactBindings,
                artifactBindings: artifactBindings,
                diagnostics: diagnostics,
                provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
                schemaVersion: SignalIntegrityRequest.currentSchemaVersion
            )
        } catch let error as TimingError {
            if case .artifactWriteFailed = error {
                return try failedEnvelope(request: request, startedAt: startedAt, error: error)
            }
            return try blockedEnvelope(request: request, startedAt: startedAt, error: error)
        } catch {
            return try SignalIntegrityExecutionResult(
                runID: request.runID,
                status: .failed,
                payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil),
                inputBindings: request.artifactBindings,
                diagnostics: [DesignDiagnostic(
                    severity: .error,
                    code: "timing.signal_integrity.execution_failed",
                    message: error.localizedDescription,
                    suggestedActions: ["inspect_input_artifacts", "reproduce_with_timing_cli"]
                )],
                provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
                schemaVersion: SignalIntegrityRequest.currentSchemaVersion
            )
        }
    }

    private func blockedEnvelope(
        request: SignalIntegrityRequest,
        startedAt: Date,
        error: TimingError
    ) throws -> SignalIntegrityExecutionResult {
        try SignalIntegrityExecutionResult(
            runID: request.runID,
            status: .blocked,
            payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil),
            inputBindings: request.artifactBindings,
            diagnostics: [DesignDiagnostic(
                severity: .error,
                code: code(for: error),
                message: error.localizedDescription,
                suggestedActions: ["inspect_input_artifacts", "check_spef_coupling_data"]
            )],
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: SignalIntegrityRequest.currentSchemaVersion
        )
    }

    private func provenanceBlockedEnvelope(
        request: SignalIntegrityRequest,
        startedAt: Date,
        issues: [LogicDesignProvenanceValidation.Issue]
    ) throws -> SignalIntegrityExecutionResult {
        try SignalIntegrityExecutionResult(
            runID: request.runID,
            status: .blocked,
            payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil),
            inputBindings: request.artifactBindings,
            diagnostics: issues.map { issue in
                DesignDiagnostic(
                    severity: .error,
                    code: issue.diagnosticCode,
                    message: issue.message,
                    suggestedActions: ["repair_design_provenance", "recreate_design_handoff"]
                )
            },
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: SignalIntegrityRequest.currentSchemaVersion
        )
    }

    private func failedEnvelope(
        request: SignalIntegrityRequest,
        startedAt: Date,
        error: TimingError
    ) throws -> SignalIntegrityExecutionResult {
        try SignalIntegrityExecutionResult(
            runID: request.runID,
            status: .failed,
            payload: SignalIntegrityPayload(violationCount: 0, worstDeltaDelay: nil),
            inputBindings: request.artifactBindings,
            diagnostics: [DesignDiagnostic(
                severity: .error,
                code: "timing.signal_integrity.artifact_write_failed",
                message: error.localizedDescription,
                suggestedActions: ["inspect_output_directory", "retry_with_writable_artifact_store"]
            )],
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: SignalIntegrityRequest.currentSchemaVersion
        )
    }

    private func code(for error: TimingError) -> String {
        switch error {
        case .parseFailure, .spefOwnership, .parasiticReduction: return "timing.signal_integrity.parse_failed"
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
                version: "2.0.0",
                build: TimingRuntimeIdentity.currentExecutableDigest()
            ),
            inputs: inputs,
            invocation: ExecutionInvocation.inProcess(
                entryPoint: "SignalIntegrityEngine.NativeSignalIntegrityEngine.execute"
            ),
            environment: try TimingRuntimeIdentity.environmentFingerprint(
                toolchain: "timing.signal-integrity-2.0.0"
            ),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
    private func logicDesignReference(for request: SignalIntegrityRequest) -> LogicDesignReference {
        LogicDesignReference(
            artifact: request.design.reference,
            topDesignName: request.topDesignName,
            designDigest: request.canonicalDesignDigest?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
            provenance: LogicDesignProvenance(
                sourceDesignDigest: request.canonicalDesignDigest?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
                inputDesignDigest: request.design.digest.hexadecimalValue,
                producerID: "timing.signal-integrity",
                producerVersion: "2.0.0",
                runID: request.runID
            )
        )
    }
}

import CircuiteFoundation
import Foundation
import LogicIR
import SignalIntegrityEngine
import STAEngine
import TimingCore

/// Executes the local timing corpus through the canonical timing engines.
public struct LocalTimingCorpusRunner: TimingCorpusRunning {
    public let sta: any STAExecuting
    public let signalIntegrity: any SignalIntegrityExecuting
    public let reader: any TimingArtifactReading
    public let referenceAnalyzer: TimingReferenceAnalyzer
    public let correlationRunner: TimingCorrelationRunner

    public init(
        sta: any STAExecuting = NativeSTAEngine(),
        signalIntegrity: any SignalIntegrityExecuting = NativeSignalIntegrityEngine(),
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        referenceAnalyzer: TimingReferenceAnalyzer = TimingReferenceAnalyzer(),
        correlationRunner: TimingCorrelationRunner = TimingCorrelationRunner()
    ) {
        self.sta = sta
        self.signalIntegrity = signalIntegrity
        self.reader = reader
        self.referenceAnalyzer = referenceAnalyzer
        self.correlationRunner = correlationRunner
    }

    public func execute(
        manifest: TimingCorpusManifest,
        rootURL: URL,
        runID: String
    ) async throws -> TimingCorpusReport {
        let root = rootURL.standardizedFileURL
        var results: [TimingCorpusCaseResult] = []
        for corpusCase in manifest.cases.sorted(by: { $0.caseID < $1.caseID }) {
            results.append(await evaluate(corpusCase, rootURL: root, runID: "\(runID):\(corpusCase.caseID)"))
        }
        return TimingCorpusReport(
            suiteID: manifest.suiteID,
            processID: manifest.processID,
            version: manifest.version,
            isValid: results.allSatisfy(\.passed),
            caseResults: results,
            limitations: [
                "Corpus success proves only the retained cases and declared implementation scope.",
                "The scalar reference oracle is independent from the native graph propagation implementation but is not a foundry signoff tool.",
                "External digital STA oracle availability is reported separately and is not assumed by this runner."
            ]
        )
    }

    private func evaluate(
        _ corpusCase: TimingCorpusCase,
        rootURL: URL,
        runID: String
    ) async -> TimingCorpusCaseResult {
        do {
            let request = try makeRequest(corpusCase, rootURL: rootURL, runID: runID)
            let staResult: STAExecutionResult?
            let siResult: SignalIntegrityExecutionResult?
            switch corpusCase.engine {
            case .sta:
                staResult = try await sta.execute(request.sta)
                siResult = nil
            case .signalIntegrity:
                staResult = nil
                siResult = try await signalIntegrity.execute(request.si)
            }

            let status = staResult?.status ?? siResult!.status
            let observedOutcome = outcome(for: status)
            let diagnostics = (staResult?.diagnostics ?? siResult!.diagnostics)
                .map { $0.code.rawValue }
                .sorted()
            let missingCodes = Set(corpusCase.expectedDiagnosticCodes).subtracting(diagnostics).sorted()
            var correlation: TimingCorrelationResult?
            var provenance = TimingArtifactProvenance()
            var nativeSetup: Double?
            var nativeHold: Double?
            if let staResult {
                nativeSetup = staResult.payload.worstSetupSlack
                nativeHold = staResult.payload.worstHoldSlack
                provenance = staResult.payload.provenance
                if staResult.status == .completed {
                    correlation = try await correlate(
                        corpusCase,
                        request: request.sta,
                        payload: staResult.payload
                    )
                }
            } else if let siResult {
                provenance = siResult.payload.provenance
            }

            let expectedSlackMatches = matchesExpectedSlacks(corpusCase, setup: nativeSetup, hold: nativeHold)
            let correlationPassed = corpusCase.engine == .sta && corpusCase.expectedOutcome == .completed
                ? correlation?.passed == true
                : true
            return TimingCorpusCaseResult(
                caseID: corpusCase.caseID,
                expectedOutcome: corpusCase.expectedOutcome,
                observedOutcome: observedOutcome,
                passed: observedOutcome == corpusCase.expectedOutcome
                    && missingCodes.isEmpty
                    && expectedSlackMatches
                    && correlationPassed,
                expectedDiagnosticCodes: corpusCase.expectedDiagnosticCodes,
                observedDiagnosticCodes: diagnostics,
                missingExpectedDiagnosticCodes: missingCodes,
                nativeWorstSetupSlack: nativeSetup,
                nativeWorstHoldSlack: nativeHold,
                provenance: provenance,
                correlation: correlation
            )
        } catch let error as TimingError {
            let code = corpusDiagnosticCode(for: error)
            return TimingCorpusCaseResult(
                caseID: corpusCase.caseID,
                expectedOutcome: corpusCase.expectedOutcome,
                observedOutcome: .failed,
                passed: corpusCase.expectedOutcome == .failed
                    && corpusCase.expectedDiagnosticCodes.contains(code),
                expectedDiagnosticCodes: corpusCase.expectedDiagnosticCodes,
                observedDiagnosticCodes: [code],
                missingExpectedDiagnosticCodes: Set(corpusCase.expectedDiagnosticCodes)
                    .subtracting([code]).sorted()
            )
        } catch {
            return TimingCorpusCaseResult(
                caseID: corpusCase.caseID,
                expectedOutcome: corpusCase.expectedOutcome,
                observedOutcome: .failed,
                passed: false,
                expectedDiagnosticCodes: corpusCase.expectedDiagnosticCodes,
                observedDiagnosticCodes: ["TIMING_CORPUS_CASE_EXECUTION_FAILED"],
                missingExpectedDiagnosticCodes: Set(corpusCase.expectedDiagnosticCodes)
                    .subtracting(["TIMING_CORPUS_CASE_EXECUTION_FAILED"]).sorted()
            )
        }
    }

    private struct CaseRequest: Sendable {
        let sta: STARequest
        let si: SignalIntegrityRequest
    }

    private func makeRequest(
        _ corpusCase: TimingCorpusCase,
        rootURL: URL,
        runID: String
    ) throws -> CaseRequest {
        let builder = TimingArtifactReferenceBuilder()
        let design = try builder.makeReference(
            path: try resolve(corpusCase.designPath, rootURL: rootURL),
            kind: CircuiteFoundation.ArtifactKind.netlist,
            format: format(for: corpusCase.designPath, fallback: .json)
        )
        let constraint = try builder.makeReference(
            path: try resolve(corpusCase.constraintPath, rootURL: rootURL),
            kind: CircuiteFoundation.ArtifactKind.constraints,
            format: try ArtifactFormat(rawValue: "sdc")
        )
        let pdkManifest = try builder.makeReference(
            path: try resolve(corpusCase.pdkManifestPath, rootURL: rootURL),
            kind: CircuiteFoundation.ArtifactKind.technology,
            format: .json
        )
        let libraries = try corpusCase.libraryPaths.map {
            try TimingLibraryReference(
                artifact: builder.makeReference(
                    path: try resolve($0, rootURL: rootURL),
                    kind: try ArtifactKind(rawValue: "timing.library"),
                    format: .liberty
                ),
                cornerIDs: corpusCase.cornerIDs.isEmpty ? ["default"] : corpusCase.cornerIDs
            )
        }
        let parasitics = try corpusCase.parasiticsPath.map {
            try builder.makeReference(
                path: try resolve($0, rootURL: rootURL),
                kind: CircuiteFoundation.ArtifactKind.parasitics,
                format: .spef
            )
        }
        let pdkDigest = try corpusCase.pdkDigest.map {
            try ContentDigest(algorithm: .sha256, hexadecimalValue: $0)
        } ?? pdkManifest.digest
        let sta = STARequest(
            runID: runID,
            design: design,
            topDesignName: corpusCase.topDesignName,
            designRevision: design.digest,
            libraries: libraries,
            constraints: constraint,
            requestedModeIDs: corpusCase.modeIDs,
            requestedCornerIDs: corpusCase.cornerIDs,
            pdkManifest: pdkManifest,
            processID: corpusCase.processID,
            pdkVersion: corpusCase.pdkVersion,
            pdkDigest: pdkDigest,
            parasitics: parasitics,
            requiresPostLayoutInputs: corpusCase.requiresPostLayoutInputs
        )
        let siParasitics = try parasitics ?? builder.makeReference(
            path: try resolve(corpusCase.parasiticsPath ?? corpusCase.designPath, rootURL: rootURL),
            kind: CircuiteFoundation.ArtifactKind.parasitics,
            format: .spef
        )
        let si = SignalIntegrityRequest(
            runID: runID,
            design: design,
            topDesignName: corpusCase.topDesignName,
            designRevision: design.digest,
            constraints: constraint,
            requestedModeIDs: corpusCase.modeIDs,
            pdkManifest: pdkManifest,
            processID: corpusCase.processID,
            pdkVersion: corpusCase.pdkVersion,
            pdkDigest: pdkDigest,
            parasitics: siParasitics
        )
        return CaseRequest(sta: sta, si: si)
    }

    private func correlate(
        _ corpusCase: TimingCorpusCase,
        request: STARequest,
        payload: STAPayload
    ) async throws -> TimingCorrelationResult {
        let designData = try await reader.read(request.design)
        let design = try TimingDesignParser().parse(designData, topDesignName: request.topDesignName)
        var library: TimingLibrary?
        for reference in request.libraries {
            let parsed = try LibertyParser().parse(try await reader.read(reference.artifact))
            library = library.map { $0.merged(with: parsed) } ?? parsed
        }
        guard let library else {
            throw TimingError.missingArtifact(role: "timing-library")
        }
        let modeID = corpusCase.modeIDs.first ?? "default"
        let constraints = try SDCParser().parse(try await reader.read(request.constraints), modeID: modeID)
        let parasitics: TimingParasitics?
        if let reference = request.parasitics {
            parasitics = try SPEFParser().parse(try await reader.read(reference))
        } else {
            parasitics = nil
        }
        let reference = try referenceAnalyzer.analyze(
            design: design,
            library: library,
            constraints: constraints,
            parasitics: parasitics
        )
        return correlationRunner.compare(native: payload, reference: reference)
    }

    private func resolve(_ path: String, rootURL: URL) throws -> String {
        let candidate = (path.hasPrefix("/") ? URL(filePath: path) : rootURL.appending(path: path)).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(rootPath) else {
            throw TimingError.invalidInput("Timing corpus path escapes its root: \(path)")
        }
        return candidate.path(percentEncoded: false)
    }

    private func outcome(for status: TimingExecutionStatus) -> TimingCorpusExpectedOutcome {
        switch status {
        case .completed: return .completed
        case .blocked: return .blocked
        case .failed, .cancelled: return .failed
        }
    }

    private func matchesExpectedSlacks(_ corpusCase: TimingCorpusCase, setup: Double?, hold: Double?) -> Bool {
        let tolerance = correlationRunner.tolerance
        if let expected = corpusCase.expectedWorstSetupSlack,
           setup.map({ abs($0 - expected) > tolerance }) ?? true { return false }
        if let expected = corpusCase.expectedWorstHoldSlack,
           hold.map({ abs($0 - expected) > tolerance }) ?? true { return false }
        return true
    }

    private func format(for path: String, fallback: ArtifactFormat) -> ArtifactFormat {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "json": return .json
        case "v", "vh": return .verilog
        case "sv": return .systemVerilog
        default: return fallback
        }
    }

    private func corpusDiagnosticCode(for error: TimingError) -> String {
        switch error {
        case .unsupportedSemantic: return "TIMING_UNSUPPORTED_SEMANTIC"
        case .missingArtifact: return "TIMING_MISSING_ARTIFACT"
        case .artifactDigestMismatch: return "TIMING_ARTIFACT_DIGEST_MISMATCH"
        case .artifactSizeMismatch: return "TIMING_ARTIFACT_SIZE_MISMATCH"
        case .artifactReadFailed: return "TIMING_ARTIFACT_READ_FAILED"
        case .parseFailure: return "TIMING_PARSE_FAILED"
        case .invalidInput: return "TIMING_INVALID_INPUT"
        case .artifactWriteFailed: return "TIMING_ARTIFACT_WRITE_FAILED"
        case .invariantViolation: return "TIMING_INVARIANT_VIOLATION"
        }
    }
}

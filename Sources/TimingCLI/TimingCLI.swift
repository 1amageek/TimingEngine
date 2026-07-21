import Foundation
import CircuiteFoundation
import LogicIR
import SignalIntegrityEngine
import STAEngine
import TimingCore
import TimingEngine

@main
struct TimingCLI {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = ["status": "error", "message": error.localizedDescription]
            do {
                let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                print("{\"message\":\"timingengine failed\"}")
            }
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            throw TimingError.invalidInput(usage)
        }
        let values = Array(arguments.dropFirst())
        switch command {
        case "parse-liberty":
            try emit(try LibertyParser().parse(try read(path: requiredPath(values, option: "--file"))))
        case "parse-sdc":
            let path = try requiredPath(values, option: "--file")
            let modeID = option("--mode", in: values) ?? "default"
            try emit(try SDCParser().parse(try read(path: path), modeID: modeID))
        case "parse-spef":
            try emit(try SPEFParser().parse(try read(path: requiredPath(values, option: "--file"))))
        case "parse-sdf":
            try emit(try SDFParser().parse(try read(path: requiredPath(values, option: "--file"))))
        case "inspect-design":
            let path = try requiredPath(values, option: "--file")
            let top = option("--top", in: values) ?? URL(filePath: path).deletingPathExtension().lastPathComponent
            try emit(try TimingDesignParser().parse(try read(path: path), topDesignName: top))
        case "run-sta":
            try await runSTA(values)
        case "run-corpus":
            try await runCorpus(values)
        case "assess-evidence":
            try await runEvidenceAssessment(values)
        case "correlate-oracle":
            try await runOracleCorrelation(values)
        case "capabilities":
            try emit(TimingEngineService.nativeCapabilities)
        default:
            throw TimingError.invalidInput(usage)
        }
    }

    private static func runSTA(_ values: [String]) async throws {
        let workspaceRoot = option("--workspace-root", in: values).map {
            URL(filePath: $0, directoryHint: .isDirectory)
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        let designPath = try requiredPath(values, option: "--design")
        let libraryPath = try requiredPath(values, option: "--library")
        let constraintsPath = try requiredPath(values, option: "--constraints")
        let pdkPath = try requiredPath(values, option: "--pdk-manifest")
        let runID = option("--run-id", in: values) ?? "timing-cli-run"
        let top = option("--top", in: values) ?? URL(filePath: designPath).deletingPathExtension().lastPathComponent
        let modeIDs = option("--mode", in: values).map { [$0] } ?? ["default"]
        let cornerIDs = option("--corner", in: values).map { [$0] } ?? ["default"]
        let outputDirectory = option("--out", in: values).map { URL(filePath: $0) }
        let referenceBuilder = TimingArtifactReferenceBuilder()
        let designReference = try makeReference(
            path: designPath,
            workspaceRoot: workspaceRoot,
            builder: referenceBuilder,
            kind: CircuiteFoundation.ArtifactKind.netlist,
            format: format(for: designPath, fallback: .json)
        )
        let libraryReference = try makeReference(
            path: libraryPath,
            workspaceRoot: workspaceRoot,
            builder: referenceBuilder,
            kind: try ArtifactKind(rawValue: "timing.library"),
            format: .liberty
        )
        let constraintReference = try makeReference(
            path: constraintsPath,
            workspaceRoot: workspaceRoot,
            builder: referenceBuilder,
            kind: CircuiteFoundation.ArtifactKind.constraints,
            format: try ArtifactFormat(rawValue: "sdc")
        )
        let pdkManifestReference = try makeReference(
            path: pdkPath,
            workspaceRoot: workspaceRoot,
            builder: referenceBuilder,
            kind: CircuiteFoundation.ArtifactKind.technology,
            format: .json
        )
        let processID = option("--process", in: values) ?? "unknown"
        let pdkVersion = option("--pdk-version", in: values) ?? "unknown"
        let pdkDigest = try ContentDigest(
            algorithm: .sha256,
            hexadecimalValue: option("--pdk-digest", in: values) ?? pdkManifestReference.digest.hexadecimalValue
        )
        let parasitics = try option("--spef", in: values).map {
            try makeReference(
                path: $0,
                workspaceRoot: workspaceRoot,
                builder: referenceBuilder,
                kind: CircuiteFoundation.ArtifactKind.parasitics,
                format: .spef
            )
        }
        let request = STARequest(
            runID: runID,
            design: designReference,
            topDesignName: top,
            designRevision: try option("--design-digest", in: values).map { try ContentDigest(algorithm: .sha256, hexadecimalValue: $0) } ?? designReference.digest,
            libraries: [TimingLibraryReference(artifact: libraryReference, cornerIDs: cornerIDs)],
            constraints: constraintReference,
            requestedModeIDs: modeIDs,
            requestedCornerIDs: cornerIDs,
            pdkManifest: pdkManifestReference,
            processID: processID,
            pdkVersion: pdkVersion,
            pdkDigest: pdkDigest,
            parasitics: parasitics,
            requiresPostLayoutInputs: values.contains("--requires-post-layout-inputs")
        )
        let store: FileSystemTimingArtifactStore?
        if let outputDirectory {
            guard let workspaceRoot else {
                throw TimingError.invalidInput("--out requires --workspace-root for workspace-relative artifacts.")
            }
            store = try FileSystemTimingArtifactStore(
                workspaceRoot: workspaceRoot,
                outputDirectory: outputDirectory
            )
        } else {
            store = nil
        }
        let result = try await NativeSTAEngine(artifactStore: store, workspaceRoot: workspaceRoot).execute(request)
        try emit(result)
        guard result.status == .completed else {
            Foundation.exit(1)
        }
    }

    private static func makeReference(
        path: String,
        workspaceRoot: URL?,
        builder: TimingArtifactReferenceBuilder,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> ArtifactReference {
        if let workspaceRoot {
            return try builder.makeReference(
                at: URL(filePath: path),
                relativeTo: workspaceRoot,
                kind: kind,
                format: format
            )
        }
        return try builder.makeReference(path: path, kind: kind, format: format)
    }

    private static func runCorpus(_ values: [String]) async throws {
        let manifestPath = try requiredPath(values, option: "--manifest")
        let manifestData = try read(path: manifestPath)
        let manifest: TimingCorpusManifest
        do {
            manifest = try JSONDecoder().decode(TimingCorpusManifest.self, from: manifestData)
        } catch {
            throw TimingError.parseFailure(format: "Timing corpus manifest", line: 1, message: error.localizedDescription)
        }
        let rootPath = option("--root", in: values) ?? URL(filePath: manifestPath).deletingLastPathComponent().path(percentEncoded: false)
        let runID = option("--run-id", in: values) ?? "timing-corpus-run"
        let report = try await LocalTimingCorpusRunner().execute(
            manifest: manifest,
            rootURL: URL(filePath: rootPath),
            runID: runID
        )
        if let outputPath = option("--out", in: values) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let url = URL(filePath: outputPath)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                throw TimingError.artifactWriteFailed(path: outputPath, message: error.localizedDescription)
            }
        }
        try emit(report)
        guard report.isValid else {
            Foundation.exit(1)
        }
    }

    private static func runEvidenceAssessment(_ values: [String]) async throws {
        let workspaceRoot = URL(
            filePath: try requiredPath(values, option: "--workspace-root"),
            directoryHint: .isDirectory
        ).standardizedFileURL.resolvingSymlinksInPath()
        let corpusPath = try requiredPath(values, option: "--corpus-report")
        let pdkPath = try requiredPath(values, option: "--pdk-manifest")
        let correlationPath = try requiredPath(values, option: "--correlation-report")
        let oraclePath = try requiredPath(values, option: "--oracle-path")
        let oracleID = try requiredPath(values, option: "--oracle-id")
        let oracleVersion = try requiredPath(values, option: "--oracle-version")
        let corpusData = try read(path: corpusPath)
        let corpus: TimingCorpusReport
        do {
            corpus = try JSONDecoder().decode(TimingCorpusReport.self, from: corpusData)
        } catch {
            throw TimingError.parseFailure(format: "Timing corpus report", line: 1, message: error.localizedDescription)
        }
        let pdkManifest = try TimingArtifactReferenceBuilder().makeReference(
            at: URL(filePath: pdkPath),
            relativeTo: workspaceRoot,
            kind: CircuiteFoundation.ArtifactKind.technology,
            format: .json
        )
        let pdkDigest = try ContentDigest(
            algorithm: .sha256,
            hexadecimalValue: option("--pdk-digest", in: values) ?? pdkManifest.digest.hexadecimalValue
        )
        let pdk = try TimingPDKReference(
            manifest: pdkManifest,
            processID: option("--process", in: values) ?? corpus.processID,
            version: option("--pdk-version", in: values) ?? "unknown",
            digest: pdkDigest
        )
        let pdkEvidence = try LocalTimingPDKEvidenceBuilder(
            workspaceRoot: workspaceRoot
        ).build(for: pdk)
        let externalOracle = TimingExternalOracleEvidence(
            oracleID: oracleID,
            status: FileManager.default.isExecutableFile(atPath: oraclePath) ? .available : .unavailable,
            executablePath: oraclePath,
            version: oracleVersion,
            details: FileManager.default.isExecutableFile(atPath: oraclePath)
                ? "The configured external executable is retained by the correlation evidence."
                : "The configured external executable is not executable."
        )
        let modeIDs = option("--mode", in: values).map { [$0] } ?? []
        let cornerIDs = option("--corner", in: values).map { [$0] } ?? []
        let externalCorrelation = try decodeExternalCorrelation(path: correlationPath)
        try await LocalTimingExternalCorrelationVerifier().verify(
            externalCorrelation,
            corpus: corpus,
            pdk: pdk,
            externalOracle: externalOracle,
            workspaceRoot: workspaceRoot
        )
        let report = await TimingEvidenceEvaluator().evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: modeIDs,
            cornerIDs: cornerIDs,
            externalOracle: externalOracle,
            externalCorrelation: externalCorrelation,
            pdkEvidence: pdkEvidence,
            workspaceRoot: workspaceRoot
        )
        if let outputPath = option("--out", in: values) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let url = URL(filePath: outputPath)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                throw TimingError.artifactWriteFailed(path: outputPath, message: error.localizedDescription)
            }
        }
        try emit(report)
        guard report.outcome == .passed else {
            Foundation.exit(1)
        }
    }

    private static func runOracleCorrelation(_ values: [String]) async throws {
        let workspaceRoot = URL(
            filePath: try requiredPath(values, option: "--workspace-root"),
            directoryHint: .isDirectory
        ).standardizedFileURL.resolvingSymlinksInPath()
        let nativePath = try requiredPath(values, option: "--native-report")
        let oraclePath = try requiredPath(values, option: "--oracle-report")
        let corpusPath = try requiredPath(values, option: "--corpus-report")
        let pdkPath = try requiredPath(values, option: "--pdk-manifest")
        let processID = try requiredPath(values, option: "--process")
        let pdkVersion = try requiredPath(values, option: "--pdk-version")
        let oracleID = try requiredPath(values, option: "--oracle-id")
        let oracleVersion = try requiredPath(values, option: "--oracle-version")
        let oracleExecutablePath = try requiredPath(values, option: "--oracle-path")
        let native = try decodeSTAReport(path: nativePath)
        let oracle = try decodeSTAReport(path: oraclePath)
        let corpus: TimingCorpusReport
        do {
            corpus = try JSONDecoder().decode(TimingCorpusReport.self, from: read(path: corpusPath))
        } catch {
            throw TimingError.parseFailure(format: "Timing corpus report", line: 1, message: error.localizedDescription)
        }
        let pdkManifest = try TimingArtifactReferenceBuilder().makeReference(
            at: URL(filePath: pdkPath),
            relativeTo: workspaceRoot,
            kind: CircuiteFoundation.ArtifactKind.technology,
            format: .json
        )
        let pdk = try TimingPDKReference(
            manifest: pdkManifest,
            processID: processID,
            version: pdkVersion,
            digest: pdkManifest.digest
        )
        let pdkEvidence = try LocalTimingPDKEvidenceBuilder(
            workspaceRoot: workspaceRoot
        ).build(for: pdk)
        guard pdkEvidence.isComplete else {
            throw TimingError.invalidInput("PDK evidence must be complete before external correlation is retained.")
        }
        let referenceBuilder = TimingArtifactReferenceBuilder()
        let oracleExecutableArtifact = try referenceBuilder.makeReference(
            at: URL(filePath: oracleExecutablePath),
            relativeTo: workspaceRoot,
            kind: try ArtifactKind(rawValue: "tool.executable"),
            format: try ArtifactFormat(rawValue: "binary")
        )
        let matchingTools = oracle.evidence.provenance.supportingTools.filter {
            $0.identifier == oracleID
                && $0.version == oracleVersion
                && $0.build?.caseInsensitiveCompare(
                    oracleExecutableArtifact.digest.hexadecimalValue
                ) == .orderedSame
        }
        guard matchingTools.count == 1, let oracleTool = matchingTools.first else {
            throw TimingError.invalidInput("Oracle result does not retain the requested tool identity, version and executable digest.")
        }
        let tolerance = option("--tolerance", in: values).flatMap(Double.init) ?? 1e-15
        let result: TimingCorrelationResult
        if oracle.status != .completed {
            result = TimingCorrelationResult(
                oracleID: oracleID,
                status: .blocked,
                tolerance: tolerance,
                diagnostics: ["external_oracle_result_not_completed"]
            )
        } else {
            result = TimingExternalOracleCorrelator(tolerance: tolerance).compare(
                native: native.payload,
                external: oracle.payload,
                oracleID: oracleID
            )
        }
        let corpusEvidenceArtifact = try referenceBuilder.makeReference(
            at: URL(filePath: corpusPath),
            relativeTo: workspaceRoot,
            kind: .report,
            format: .json
        )
        let report = TimingExternalCorrelationReport(
            processID: processID,
            pdkVersion: pdkVersion,
            pdkManifestDigest: pdkEvidence.manifestDigest,
            corpusEvidenceDigest: try TimingEvidenceHasher().hash(corpus),
            pdkManifestArtifact: pdkManifest,
            corpusEvidenceArtifact: corpusEvidenceArtifact,
            nativeEngine: native.evidence.provenance.producer,
            oracleTool: oracleTool,
            oracleExecutableArtifact: oracleExecutableArtifact,
            inputArtifacts: native.evidence.provenance.inputs,
            nativeOutputArtifact: try referenceBuilder.makeReference(
                at: URL(filePath: nativePath),
                relativeTo: workspaceRoot,
                role: .output,
                kind: .report,
                format: .json
            ),
            oracleOutputArtifact: try referenceBuilder.makeReference(
                at: URL(filePath: oraclePath),
                relativeTo: workspaceRoot,
                role: .output,
                kind: .report,
                format: .json
            ),
            correlation: result
        )
        try await LocalTimingExternalCorrelationVerifier().verify(
            report,
            corpus: corpus,
            pdk: pdk,
            externalOracle: TimingExternalOracleEvidence(
                oracleID: oracleID,
                status: FileManager.default.isExecutableFile(atPath: oracleExecutablePath)
                    ? .available
                    : .unavailable,
                executablePath: oracleExecutablePath,
                version: oracleVersion,
                details: "Oracle selected for retained correlation."
            ),
            workspaceRoot: workspaceRoot
        )
        if let outputPath = option("--out", in: values) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let url = URL(filePath: outputPath)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                throw TimingError.artifactWriteFailed(path: outputPath, message: error.localizedDescription)
            }
        }
        try emit(report)
        guard report.correlation.status == .passed else {
            Foundation.exit(1)
        }
    }

    private static func decodeSTAReport(path: String) throws -> STAExecutionResult {
        let data = try read(path: path)
        do {
            return try JSONDecoder().decode(STAExecutionResult.self, from: data)
        } catch {
            throw TimingError.parseFailure(format: "STA execution result", line: 1, message: error.localizedDescription)
        }
    }

    private static func decodeExternalCorrelation(path: String) throws -> TimingExternalCorrelationReport {
        do {
            let report = try JSONDecoder().decode(
                TimingExternalCorrelationReport.self,
                from: read(path: path)
            )
            try report.validateStructure()
            return report
        } catch let error as TimingError {
            throw error
        } catch {
            throw TimingError.parseFailure(
                format: "Timing external correlation report",
                line: 1,
                message: error.localizedDescription
            )
        }
    }

    private static func requiredPath(_ values: [String], option: String) throws -> String {
        guard let value = Self.option(option, in: values) else {
            throw TimingError.invalidInput("Missing \(option).\n\(usage)")
        }
        return value
    }

    private static func option(_ key: String, in values: [String]) -> String? {
        guard let index = values.firstIndex(of: key), values.index(after: index) < values.endIndex else { return nil }
        return values[values.index(after: index)]
    }

    private static func read(path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(filePath: path))
        } catch {
            throw TimingError.artifactReadFailed(path: path, message: error.localizedDescription)
        }
    }

    private static func format(for path: String, fallback: ArtifactFormat) -> ArtifactFormat {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "json": return .json
        case "v", "vh": return .verilog
        case "sv": return .systemVerilog
        case "spef": return .spef
        case "sdf": return .sdf
        default: return fallback
        }
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static let usage = "Usage: timingengine <parse-liberty|parse-sdc|parse-spef|parse-sdf|inspect-design|run-sta|run-corpus|assess-evidence|correlate-oracle|capabilities> ..."
}

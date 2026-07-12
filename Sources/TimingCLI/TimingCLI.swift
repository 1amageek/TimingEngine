import Foundation
import LogicIR
import PDKCore
import SignalIntegrityEngine
import STAEngine
import TimingCore
import TimingEngine
import XcircuitePackage

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
        case "qualify":
            try runQualification(values)
        case "correlate-oracle":
            try runOracleCorrelation(values)
        case "capabilities":
            try emit(TimingEngineAPI.nativeCapabilities)
        default:
            throw TimingError.invalidInput(usage)
        }
    }

    private static func runSTA(_ values: [String]) async throws {
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
        let designReference = try referenceBuilder.makeReference(path: designPath, kind: .netlist, format: format(for: designPath, fallback: .json))
        let libraryReference = try referenceBuilder.makeReference(path: libraryPath, kind: .timingLibrary, format: .liberty)
        let constraintReference = try referenceBuilder.makeReference(path: constraintsPath, kind: .constraint, format: .sdc)
        let pdkManifestReference = try referenceBuilder.makeReference(path: pdkPath, kind: .technology, format: .json)
        let pdkReference = PDKReference(
            manifest: pdkManifestReference,
            processID: option("--process", in: values) ?? "unknown",
            version: option("--pdk-version", in: values) ?? "unknown",
            digest: option("--pdk-digest", in: values) ?? pdkManifestReference.sha256 ?? "unknown"
        )
        let parasitics = try option("--spef", in: values).map {
            try referenceBuilder.makeReference(path: $0, kind: .parasitic, format: .spef)
        }
        let request = STARequest(
            runID: runID,
            inputs: [designReference, libraryReference, constraintReference, pdkReference.manifest] + (parasitics.map { [$0] } ?? []),
            design: LogicDesignReference(artifact: designReference, topDesignName: top, designDigest: option("--design-digest", in: values) ?? designReference.sha256 ?? "unknown"),
            libraries: [TimingLibraryReference(artifact: libraryReference, cornerIDs: cornerIDs)],
            constraints: TimingConstraintReference(artifact: constraintReference, modeIDs: modeIDs),
            pdk: pdkReference,
            parasitics: parasitics,
            requestedModeIDs: modeIDs,
            requestedCornerIDs: cornerIDs,
            requiresSignoff: values.contains("--requires-signoff")
        )
        let store = outputDirectory.map { FileSystemTimingArtifactStore(outputDirectory: $0) }
        let envelope = try await NativeSTAEngine(artifactStore: store).execute(request)
        try emit(envelope)
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
    }

    private static func runQualification(_ values: [String]) throws {
        let corpusPath = try requiredPath(values, option: "--corpus-report")
        let pdkPath = try requiredPath(values, option: "--pdk-manifest")
        let corpusData = try read(path: corpusPath)
        let corpus: TimingCorpusReport
        do {
            corpus = try JSONDecoder().decode(TimingCorpusReport.self, from: corpusData)
        } catch {
            throw TimingError.parseFailure(format: "Timing corpus report", line: 1, message: error.localizedDescription)
        }
        let pdkManifest = try TimingArtifactReferenceBuilder().makeReference(
            path: pdkPath,
            kind: .technology,
            format: .json
        )
        let pdk = PDKReference(
            manifest: pdkManifest,
            processID: option("--process", in: values) ?? corpus.processID,
            version: option("--pdk-version", in: values) ?? "unknown",
            digest: option("--pdk-digest", in: values) ?? pdkManifest.sha256 ?? ""
        )
        let pdkEvidence = try LocalTimingPDKQualificationEvidenceBuilder().build(for: pdk)
        let externalOracle: TimingExternalOracleEvidence
        if let oraclePath = option("--oracle-path", in: values) {
            externalOracle = TimingExternalOracleEvidence(
                oracleID: option("--oracle-id", in: values) ?? "external-digital-sta",
                status: FileManager.default.isExecutableFile(atPath: oraclePath) ? .available : .unavailable,
                executablePath: oraclePath,
                details: FileManager.default.isExecutableFile(atPath: oraclePath)
                    ? "The configured external executable exists; command version and correlation artifacts are still required."
                    : "The configured external executable is not executable."
            )
        } else {
            externalOracle = TimingExternalOracleProbe().probe(
                oracleID: option("--oracle-id", in: values) ?? "external-digital-sta"
            )
        }
        let modeIDs = option("--mode", in: values).map { [$0] } ?? []
        let cornerIDs = option("--corner", in: values).map { [$0] } ?? []
        let report = TimingQualificationEvaluator().evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: modeIDs,
            cornerIDs: cornerIDs,
            externalOracle: externalOracle,
            pdkEvidence: pdkEvidence
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
    }

    private static func runOracleCorrelation(_ values: [String]) throws {
        let nativePath = try requiredPath(values, option: "--native-report")
        let oraclePath = try requiredPath(values, option: "--oracle-report")
        let native = try decodeSTAReport(path: nativePath)
        let oracle = try decodeSTAReport(path: oraclePath)
        let tolerance = option("--tolerance", in: values).flatMap(Double.init) ?? 1e-15
        let result: TimingCorrelationResult
        if oracle.status != .completed {
            result = TimingCorrelationResult(
                oracleID: option("--oracle-id", in: values) ?? "external-digital-sta",
                status: .blocked,
                passed: false,
                tolerance: tolerance,
                diagnostics: ["external_oracle_result_not_completed"]
            )
        } else {
            result = TimingExternalOracleCorrelator(tolerance: tolerance).compare(
                native: native.payload,
                external: oracle.payload,
                oracleID: option("--oracle-id", in: values) ?? "external-digital-sta"
            )
        }
        if let outputPath = option("--out", in: values) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            let url = URL(filePath: outputPath)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                throw TimingError.artifactWriteFailed(path: outputPath, message: error.localizedDescription)
            }
        }
        try emit(result)
    }

    private struct DecodedSTAReport {
        var status: XcircuiteEngineExecutionStatus
        var payload: STAPayload
    }

    private static func decodeSTAReport(path: String) throws -> DecodedSTAReport {
        let data = try read(path: path)
        do {
            let envelope = try JSONDecoder().decode(XcircuiteEngineResultEnvelope<STAPayload>.self, from: data)
            return DecodedSTAReport(status: envelope.status, payload: envelope.payload)
        } catch let envelopeError {
            do {
                let payload = try JSONDecoder().decode(STAPayload.self, from: data)
                return DecodedSTAReport(status: .completed, payload: payload)
            } catch {
                throw TimingError.parseFailure(format: "STA report", line: 1, message: envelopeError.localizedDescription)
            }
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

    private static func format(for path: String, fallback: XcircuiteFileFormat) -> XcircuiteFileFormat {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "json": return .json
        case "v", "vh", "sv": return .verilog
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

    private static let usage = "Usage: timingengine <parse-liberty|parse-sdc|parse-spef|parse-sdf|inspect-design|run-sta|run-corpus|qualify|correlate-oracle|capabilities> ..."
}

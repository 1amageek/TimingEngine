import CircuiteFoundation
import Foundation
import SignoffToolSupport
import STAEngine
import TimingCore

@main
struct OpenSTAOracleAdapter {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try emit(try await execute(arguments: arguments))
        } catch {
            let runID = option("--run-id", in: arguments) ?? "opensta-oracle-run"
            do {
                try emit(failureResult(runID: runID, code: "OPENSTA_ADAPTER_INPUT_INVALID", message: error.localizedDescription))
            } catch {
                print("{\"status\":\"failed\",\"message\":\"opensta oracle adapter failed\"}")
            }
        }
    }

    private static func execute(arguments: [String]) async throws -> STAExecutionResult {
        let runID = option("--run-id", in: arguments) ?? "opensta-oracle-run"
        let oracleID = option("--oracle-id", in: arguments) ?? "opensta-3.1"
        let oracleVersion = try required("--oracle-version", in: arguments)
        let staPath = try required("--sta", in: arguments)
        let designPath = try required("--design", in: arguments)
        let libraryPath = try required("--library", in: arguments)
        let constraintsPath = try required("--constraints", in: arguments)
        let pdkPath = try required("--pdk-manifest", in: arguments)
        let top = try required("--top", in: arguments)
        let modeID = option("--mode", in: arguments) ?? "default"
        let cornerID = option("--corner", in: arguments) ?? "default"
        let timeoutSeconds = option("--timeout", in: arguments).flatMap(Double.init) ?? 300
        let spefPath = option("--spef", in: arguments)
        let workspaceRoot = option("--workspace-root", in: arguments).map {
            URL(filePath: $0, directoryHint: .isDirectory)
                .standardizedFileURL.resolvingSymlinksInPath()
        }

        let referenceBuilder = TimingArtifactReferenceBuilder()
        let designReference = try makeReference(
            path: designPath,
            workspaceRoot: workspaceRoot,
            builder: referenceBuilder,
            kind: .netlist,
            format: designFormat(for: designPath)
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
        let pdkReference = try makeReference(
            path: pdkPath,
            workspaceRoot: workspaceRoot,
            builder: referenceBuilder,
            kind: CircuiteFoundation.ArtifactKind.technology,
            format: .json
        )
        let parasiticsReference = try spefPath.map {
            try makeReference(
                path: $0,
                workspaceRoot: workspaceRoot,
                builder: referenceBuilder,
                kind: CircuiteFoundation.ArtifactKind.parasitics,
                format: .spef
            )
        }
        let provenance = TimingArtifactProvenance(
            designDigest: designReference.digest.hexadecimalValue,
            libraryDigests: [libraryReference.digest.hexadecimalValue],
            constraintDigest: constraintReference.digest.hexadecimalValue,
            pdkDigest: option("--pdk-digest", in: arguments) ?? pdkReference.digest.hexadecimalValue,
            parasiticsDigest: parasiticsReference?.digest.hexadecimalValue
        )
        let inputs = [designReference, libraryReference, constraintReference, pdkReference]
            + (parasiticsReference.map { [$0] } ?? [])
        let timeUnitScale = try libertyTimeUnitScale(path: libraryPath)
        let startedAt = Date()
        let scriptURL = try makeScript(
            runID: runID,
            workingDirectory: URL(filePath: libraryPath).deletingLastPathComponent(),
            designPath: designPath,
            libraryPath: libraryPath,
            constraintsPath: constraintsPath,
            top: top,
            spefPath: spefPath
        )
        let scriptReference = try makeReference(
            path: scriptURL.path(percentEncoded: false),
            workspaceRoot: workspaceRoot,
            builder: referenceBuilder,
            kind: .evidence,
            format: try ArtifactFormat(rawValue: "tcl")
        )
        let process = Process()
        process.executableURL = URL(filePath: staPath)
        process.arguments = ["-exit", scriptURL.path(percentEncoded: false)]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        let invocation = try ExecutionInvocation.externalProcess(
            executable: staPath,
            arguments: process.arguments ?? [],
            workingDirectory: process.currentDirectoryURL?.path(percentEncoded: false)
        )

        do {
            let processResult = try await TimedProcessRunner(timeoutSeconds: timeoutSeconds).run(process: process)
            let payload = makePayload(
                stdout: processResult.standardOutput,
                modeID: modeID,
                cornerID: cornerID,
                provenance: provenance,
                timeUnitScale: timeUnitScale
            )
            let diagnostics = diagnostics(from: processResult.standardError)
            guard processResult.exitCode == 0 else {
                return try result(
                    runID: runID,
                    status: .failed,
                    diagnostics: diagnostics + [diagnostic(
                        severity: .error,
                        code: "OPENSTA_NONZERO_EXIT",
                        message: "OpenSTA exited with status \(processResult.exitCode).",
                        suggestedActions: ["inspect_opensta_stderr", "reproduce_with_generated_tcl"]
                    )],
                    payload: payload,
                    startedAt: startedAt,
                    oracleID: oracleID,
                    oracleVersion: oracleVersion,
                    inputs: inputs,
                    invocation: invocation,
                    designRevision: designReference.digest,
                    artifacts: [scriptReference]
                )
            }
            let reportDiagnostics = reportDiagnostics(for: payload, stderr: processResult.standardError)
            return try result(
                runID: runID,
                status: reportDiagnostics.isEmpty ? .completed : .blocked,
                diagnostics: diagnostics + reportDiagnostics,
                payload: payload,
                startedAt: startedAt,
                oracleID: oracleID,
                oracleVersion: oracleVersion,
                inputs: inputs,
                invocation: invocation,
                designRevision: designReference.digest,
                artifacts: [scriptReference]
            )
        } catch let error as TimedProcessError {
            return try result(
                runID: runID,
                status: .failed,
                diagnostics: [diagnostic(
                    severity: .error,
                    code: processDiagnosticCode(for: error),
                    message: error.localizedDescription,
                    suggestedActions: ["inspect_generated_tcl", "increase_timeout_if_appropriate"]
                )],
                payload: emptyPayload(modeID: modeID, cornerID: cornerID, provenance: provenance),
                startedAt: startedAt,
                oracleID: oracleID,
                oracleVersion: oracleVersion,
                inputs: inputs,
                invocation: invocation,
                designRevision: designReference.digest,
                artifacts: [scriptReference]
            )
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

    private static func makePayload(
        stdout: String,
        modeID: String,
        cornerID: String,
        provenance: TimingArtifactProvenance,
        timeUnitScale: Double
    ) -> STAPayload {
        let setup = slackValues(in: stdout, section: "setup")
        let hold = slackValues(in: stdout, section: "hold")
        return STAPayload(
            worstSetupSlack: setup.min().map { $0 * timeUnitScale },
            worstHoldSlack: hold.min().map { $0 * timeUnitScale },
            analyzedCorners: [cornerID],
            analyzedModes: [modeID],
            provenance: provenance
        )
    }

    private static func emptyPayload(
        modeID: String,
        cornerID: String,
        provenance: TimingArtifactProvenance
    ) -> STAPayload {
        STAPayload(
            worstSetupSlack: nil,
            worstHoldSlack: nil,
            analyzedCorners: [cornerID],
            analyzedModes: [modeID],
            provenance: provenance
        )
    }

    private static func slackValues(in output: String, section: String) -> [Double] {
        var currentSection = ""
        var values: [Double] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.contains("TIMINGENGINE_\(section.uppercased())_BEGIN") {
                currentSection = section
                continue
            }
            if line.contains("TIMINGENGINE_\(section.uppercased())_END") {
                currentSection = ""
                continue
            }
            guard currentSection == section, let range = line.range(of: "slack (") else { continue }
            let candidate = line[range.upperBound...]
                .split(whereSeparator: \.isWhitespace)
                .last
                .map(String.init)
            if let value = candidate.flatMap(Double.init) {
                values.append(value)
            }
        }
        return values
    }

    private static func reportDiagnostics(for payload: STAPayload, stderr: String) -> [DesignDiagnostic] {
        var result: [DesignDiagnostic] = []
        if payload.worstSetupSlack == nil {
            result.append(diagnostic(
                severity: .error,
                code: "OPENSTA_SETUP_PATH_MISSING",
                message: "OpenSTA did not emit a setup slack in the adapter report.",
                suggestedActions: ["check_clock_constraints", "check_linked_cells", "inspect_opensta_stderr"]
            ))
        }
        if payload.worstHoldSlack == nil {
            result.append(diagnostic(
                severity: .error,
                code: "OPENSTA_HOLD_PATH_MISSING",
                message: "OpenSTA did not emit a hold slack in the adapter report.",
                suggestedActions: ["check_clock_constraints", "check_sequential_arcs", "inspect_opensta_stderr"]
            ))
        }
        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(diagnostic(
                severity: .warning,
                code: "OPENSTA_STDERR_PRESENT",
                message: "OpenSTA emitted stderr; warnings are retained in the external runner result.",
                suggestedActions: ["review_external_oracle_stderr"]
            ))
        }
        return result.filter { $0.severity == .error }
    }

    private static func libertyTimeUnitScale(path: String) throws -> Double {
        let data: Data
        do {
            data = try Data(contentsOf: URL(filePath: path))
        } catch {
            throw TimingError.artifactReadFailed(path: path, message: error.localizedDescription)
        }
        guard let source = String(data: data, encoding: .utf8),
              let range = source.range(of: "time_unit"),
              let colon = source[range.upperBound...].firstIndex(of: ":") else {
            throw TimingError.parseFailure(format: "Liberty", line: 1, message: "The external oracle adapter requires an explicit time_unit.")
        }
        let value = source[source.index(after: colon)...]
            .split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        guard let value, let scale = libertyTime(value) else {
            throw TimingError.parseFailure(format: "Liberty", line: 1, message: "Invalid time_unit in external oracle library.")
        }
        return scale
    }

    private static func libertyTime(_ value: String) -> Double? {
        let lower = value.lowercased()
        let suffixes: [(String, Double)] = [("fs", 1e-15), ("ps", 1e-12), ("ns", 1e-9), ("us", 1e-6), ("ms", 1e-3), ("s", 1)]
        for (suffix, scale) in suffixes where lower.hasSuffix(suffix) {
            return Double(lower.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 * scale }
        }
        return Double(lower.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func diagnostics(from stderr: String) -> [DesignDiagnostic] {
        guard !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [diagnostic(
            severity: .warning,
            code: "OPENSTA_STDERR_PRESENT",
            message: "OpenSTA emitted stderr; the external runner retains the raw stream.",
            suggestedActions: ["review_external_oracle_stderr"]
        )]
    }

    private static func makeScript(
        runID: String,
        workingDirectory: URL,
        designPath: String,
        libraryPath: String,
        constraintsPath: String,
        top: String,
        spefPath: String?
    ) throws -> URL {
        let safeRunID = runID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        let scriptURL = workingDirectory.appending(path: ".timingengine-opensta-\(String(safeRunID)).tcl")
        var lines = [
            "read_liberty \(tclQuote(libraryPath))",
            "read_verilog \(tclQuote(designPath))",
            "link_design \(tclQuote(top))",
            "read_sdc \(tclQuote(constraintsPath))"
        ]
        if let spefPath {
            lines.append("read_spef \(tclQuote(spefPath))")
        }
        lines += [
            "puts \"TIMINGENGINE_SETUP_BEGIN\"",
            "report_checks -path_delay max -format full_clock_expanded -digits 15",
            "puts \"TIMINGENGINE_SETUP_END\"",
            "puts \"TIMINGENGINE_HOLD_BEGIN\"",
            "report_checks -path_delay min -format full_clock_expanded -digits 15",
            "puts \"TIMINGENGINE_HOLD_END\"",
            "exit"
        ]
        do {
            try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: scriptURL, options: .atomic)
        } catch {
            throw TimingError.artifactWriteFailed(path: scriptURL.path(percentEncoded: false), message: error.localizedDescription)
        }
        return scriptURL
    }

    private static func tclQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "\"\(escaped)\""
    }

    private static func result(
        runID: String,
        status: TimingExecutionStatus,
        diagnostics: [DesignDiagnostic],
        payload: STAPayload,
        startedAt: Date,
        oracleID: String,
        oracleVersion: String,
        inputs: [ArtifactReference],
        invocation: ExecutionInvocation,
        designRevision: ContentDigest?,
        artifacts: [ArtifactReference] = []
    ) throws -> STAExecutionResult {
        let producer = try ProducerIdentity(
            kind: .tool,
            identifier: "timing.sta.external",
            version: "adapter-1.0.0",
            build: oracleID
        )
        let provenance = try ExecutionProvenance(
            producer: producer,
            supportingTools: [try ProducerIdentity(
                kind: .tool,
                identifier: oracleID,
                version: oracleVersion
            )],
            inputs: inputs,
            invocation: invocation,
            designRevision: designRevision,
            startedAt: startedAt,
            completedAt: Date()
        )
        return STAExecutionResult(
            runID: runID,
            status: status,
            payload: payload,
            artifacts: artifacts,
            diagnostics: diagnostics,
            provenance: provenance
        )
    }

    private static func failureResult(
        runID: String,
        code: String,
        message: String
    ) throws -> STAExecutionResult {
        let producer = try ProducerIdentity(
            kind: .tool,
            identifier: "timing.sta.external",
            version: "adapter-1.0.0"
        )
        let provenance = try ExecutionProvenance(
            producer: producer,
            startedAt: Date(),
            completedAt: Date()
        )
        return STAExecutionResult(
            runID: runID,
            status: .failed,
            payload: STAPayload(worstSetupSlack: nil, worstHoldSlack: nil, analyzedCorners: [], analyzedModes: []),
            diagnostics: [diagnostic(severity: .error, code: code, message: message, suggestedActions: ["inspect_adapter_arguments"])],
            provenance: provenance
        )
    }

    private static func diagnostic(
        severity: DiagnosticSeverity,
        code: String,
        message: String,
        suggestedActions: [String]
    ) -> DesignDiagnostic {
        let diagnosticCode = DiagnosticCode.trusted(code)
        return DesignDiagnostic(
            code: diagnosticCode,
            severity: severity,
            summary: message,
            suggestedActions: suggestedActions.map { SuggestedAction(code: $0, summary: $0) }
        )
    }

    private static func processDiagnosticCode(for error: TimedProcessError) -> String {
        switch error {
        case .invalidConfiguration: return "OPENSTA_INVALID_TIMEOUT"
        case .launchFailed: return "OPENSTA_LAUNCH_FAILED"
        case .cancellationCheckFailed: return "OPENSTA_CANCELLATION_CHECK_FAILED"
        case .cancelled: return "OPENSTA_CANCELLED"
        case .timedOut: return "OPENSTA_TIMED_OUT"
        }
    }

    private static func required(_ key: String, in arguments: [String]) throws -> String {
        guard let value = option(key, in: arguments), !value.isEmpty else {
            throw TimingError.invalidInput("Missing \(key).")
        }
        return value
    }

    private static func option(_ key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }

    private static func designFormat(for path: String) -> ArtifactFormat {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "v", "vh": return .verilog
        case "sv": return .systemVerilog
        default: return .json
        }
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }
}

import CircuiteFoundation
import Foundation
import STAEngine
import SignoffToolSupport
import TimingCore
import DesignFlowKernel

public actor LocalTimingExternalOracleRunner: TimingExternalOracleRunning {
    public init() {}

    public func execute(_ request: TimingExternalOracleRequest) async throws -> TimingExternalOracleResult {
        guard FileManager.default.isExecutableFile(atPath: request.executablePath) else {
            return TimingExternalOracleResult(
                runID: request.runID,
                oracleID: request.oracleID,
                status: .blocked,
                diagnostics: ["external_oracle_executable_unavailable"]
            )
        }
        let workingDirectoryURL = URL(filePath: request.workingDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectoryURL.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else {
            return TimingExternalOracleResult(
                runID: request.runID,
                oracleID: request.oracleID,
                status: .blocked,
                diagnostics: ["external_oracle_working_directory_unavailable"]
            )
        }

        let process = Process()
        process.executableURL = URL(filePath: request.executablePath)
        process.arguments = request.arguments
        process.currentDirectoryURL = workingDirectoryURL
        let processResult: TimedProcessResult
        do {
            processResult = try await TimedProcessRunner(
                timeoutSeconds: request.timeoutSeconds
            ).run(process: process)
        } catch let error as TimedProcessError {
            return TimingExternalOracleResult(
                runID: request.runID,
                oracleID: request.oracleID,
                status: .failed,
                stderr: error.localizedDescription,
                diagnostics: [diagnosticCode(for: error)]
            )
        }
        let stdout = processResult.standardOutput
        let stderr = processResult.standardError
        let exitCode = processResult.exitCode
        guard exitCode == 0 else {
            return TimingExternalOracleResult(
                runID: request.runID,
                oracleID: request.oracleID,
                status: .failed,
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr,
                diagnostics: ["external_oracle_nonzero_exit"]
            )
        }
        do {
            let result = try decodeFoundationResult(stdout)
            guard result.schemaVersion == .v1 else {
                throw TimingError.invalidInput("Unsupported external STA result schema version.")
            }
            guard result.runID == request.runID else {
                return invalidResult(
                    request: request,
                    exitCode: exitCode,
                    stdout: stdout,
                    stderr: stderr,
                    diagnostic: "external_oracle_run_id_mismatch"
                )
            }
            var diagnostics = result.diagnostics.map { $0.code.rawValue }
            if result.status != .completed {
                diagnostics.append("external_oracle_result_not_completed")
            }
            return TimingExternalOracleResult(
                runID: request.runID,
                oracleID: request.oracleID,
                status: externalStatus(for: result.status),
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr,
                payload: result.payload,
                diagnostics: diagnostics
            )
        } catch {
            return TimingExternalOracleResult(
                runID: request.runID,
                oracleID: request.oracleID,
                status: .failed,
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr,
                diagnostics: ["external_oracle_output_invalid"]
            )
        }
    }

    private func decodeFoundationResult(_ stdout: String) throws -> STAExecutionResult {
        try JSONDecoder().decode(STAExecutionResult.self, from: Data(stdout.utf8))
    }

    private func invalidResult(
        request: TimingExternalOracleRequest,
        exitCode: Int32,
        stdout: String,
        stderr: String,
        diagnostic: String
    ) -> TimingExternalOracleResult {
        TimingExternalOracleResult(
            runID: request.runID,
            oracleID: request.oracleID,
            status: .failed,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            diagnostics: [diagnostic]
        )
    }

    private func externalStatus(
        for status: TimingExecutionStatus
    ) -> TimingExternalOracleResult.Status {
        switch status {
        case .completed:
            return .completed
        case .blocked:
            return .blocked
        case .failed, .cancelled:
            return .failed
        }
    }

    private func diagnosticCode(for error: TimedProcessError) -> String {
        switch error {
        case .invalidConfiguration:
            return "external_oracle_invalid_timeout"
        case .launchFailed:
            return "external_oracle_launch_failed"
        case .cancellationCheckFailed:
            return "external_oracle_cancellation_check_failed"
        case .cancelled:
            return "external_oracle_cancelled"
        case .timedOut:
            return "external_oracle_timed_out"
        }
    }
}

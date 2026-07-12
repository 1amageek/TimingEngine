import Foundation
import STAEngine
import SignoffToolSupport
import XcircuitePackage

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
            let envelope = try JSONDecoder().decode(XcircuiteEngineResultEnvelope<STAPayload>.self, from: Data(stdout.utf8))
            guard envelope.status == .completed else {
                return TimingExternalOracleResult(
                    runID: request.runID,
                    oracleID: request.oracleID,
                    status: .blocked,
                    exitCode: exitCode,
                    stdout: stdout,
                    stderr: stderr,
                    payload: envelope.payload,
                    diagnostics: ["external_oracle_result_not_completed"]
                )
            }
            return TimingExternalOracleResult(
                runID: request.runID,
                oracleID: request.oracleID,
                status: .completed,
                exitCode: exitCode,
                stdout: stdout,
                stderr: stderr,
                payload: envelope.payload
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

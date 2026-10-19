import CircuiteFoundation
import Foundation
import STAEngine
import SignoffToolSupport
import TimingCore

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
        // Typed failures retain exact captured bytes and any pending cleanup owner.
        let processResult = try await TimedProcessRunner(timeoutSeconds: request.timeoutSeconds,
            maximumOutputByteCount: request.maximumOutputByteCount,
            cleanupTimeoutSeconds: request.cleanupTimeoutSeconds).run(process: process)
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
                standardOutputData: processResult.standardOutputData,
                standardErrorData: processResult.standardErrorData,
                diagnostics: ["external_oracle_nonzero_exit"]
            )
        }
        do {
            let result = try JSONDecoder().decode(STAExecutionResult.self, from: processResult.standardOutputData)
            guard result.runID == request.runID else {
                return invalidResult(
                    request: request,
                    exitCode: exitCode,
                    stdout: stdout,
                    stderr: stderr,
                    standardOutputData: processResult.standardOutputData,
                    standardErrorData: processResult.standardErrorData,
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
                standardOutputData: processResult.standardOutputData,
                standardErrorData: processResult.standardErrorData,
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
                standardOutputData: processResult.standardOutputData,
                standardErrorData: processResult.standardErrorData,
                diagnostics: ["external_oracle_output_invalid"]
            )
        }
    }

    private func invalidResult(
        request: TimingExternalOracleRequest,
        exitCode: Int32,
        stdout: String,
        stderr: String,
        standardOutputData: Data,
        standardErrorData: Data,
        diagnostic: String
    ) -> TimingExternalOracleResult {
        TimingExternalOracleResult(
            runID: request.runID,
            oracleID: request.oracleID,
            status: .failed,
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            standardOutputData: standardOutputData,
            standardErrorData: standardErrorData,
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

}

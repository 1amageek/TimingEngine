import Foundation
import SignoffToolSupport
import Testing
import TimingEngine

@Suite(.timeLimit(.minutes(1)))
struct TimedOracleConsumerTests {
    private func request(_ script: String, timeout: Double = 5, output: UInt64 = 65536,
                         cleanup: Double = 5) -> TimingExternalOracleRequest {
        .init(runID: "bounded-oracle", oracleID: "fixture", executablePath: "/bin/sh",
            arguments: ["-c", script], workingDirectory: FileManager.default.temporaryDirectory.path,
            timeoutSeconds: timeout, maximumOutputByteCount: output, cleanupTimeoutSeconds: cleanup)
    }
    @Test func nonzeroAndInvalidOutputRetainExactBytes() async throws {
        let result = try await LocalTimingExternalOracleRunner().execute(request("printf '\\377'; printf '\\376' >&2; exit 7"))
        #expect(result.status == .failed && result.exitCode == 7)
        #expect(result.standardOutputData == Data([0xff]))
        #expect(result.standardErrorData == Data([0xfe]))
        let invalid = try await LocalTimingExternalOracleRunner().execute(request("printf '\\377'"))
        #expect(invalid.status == .failed && invalid.diagnostics == ["external_oracle_output_invalid"])
        #expect(invalid.standardOutputData == Data([0xff]))
    }
    @Test func timeoutAndCancellationPreserveTypedCauseAndBytes() async throws {
        do {
            _ = try await LocalTimingExternalOracleRunner().execute(request("printf '\\377'; exec sleep 5", timeout: 0.15))
            Issue.record("Expected timeout")
        } catch TimedProcessError.executionFailed(let failure) {
            #expect(failure.cause == .timedOut(timeoutSeconds: 0.15))
            #expect(failure.standardOutputData == Data([0xff]))
            if let handle = failure.cleanupHandle { try await handle.close(timeoutSeconds: 5) }
        }
        let value = request("printf '\\376'; exec sleep 5")
        let task = Task { try await LocalTimingExternalOracleRunner().execute(value) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch TimedProcessError.executionFailed(let failure) {
            #expect(failure.cause == .cancelled)
            #expect(failure.standardOutputData == Data([0xfe]))
            if let handle = failure.cleanupHandle { try await handle.close(timeoutSeconds: 5) }
        }
    }
    @Test func outputBudgetFailureRetainsAdmittedBytesAndCleanup() async throws {
        do {
            _ = try await LocalTimingExternalOracleRunner().execute(
                request("trap '' TERM; printf '12345'; exec sleep 5", output: 4, cleanup: 0.000001))
            Issue.record("Expected bounded output refusal")
        } catch TimedProcessError.executionFailed(let failure) {
            #expect(failure.cause == .outputLimitExceeded(maximumByteCount: 4))
            // Overflow chunks are refused atomically by the lower capture contract.
            #expect(failure.standardOutputData.isEmpty)
            if let handle = failure.cleanupHandle { try await handle.close(timeoutSeconds: 5) }
        }
    }
    @Test func realLowerFailureTransfersTheSameOwnerThroughTheOracleProtocol() async throws {
        let failure: TimedProcessFailure
        do {
            _ = try await TimedProcessRunner(timeoutSeconds: 0.02, terminationGraceSeconds: 0,
                maximumOutputByteCount: 1, cleanupTimeoutSeconds: 0.000000001)
                .run(executableURL: URL(filePath: "/bin/sh"), arguments: ["-c",
                    "trap '' TERM; for i in 1 2 3 4; do (trap '' TERM; while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'; done) & done; wait"])
            Issue.record("Expected process failure"); return
        } catch TimedProcessError.executionFailed(let value) { failure = value }
        print("oracle real lower handoff pendingOwnerPresent=\(failure.cleanupHandle != nil)")
        let oracle: any TimingExternalOracleRunning = RetainedOracleFailure(failure: failure)
        do {
            _ = try await oracle.execute(request("unused"))
            Issue.record("Pending failure unexpectedly became a result")
        } catch TimedProcessError.executionFailed(let retained) {
            #expect(retained.cause == failure.cause)
            #expect(retained.standardOutputData == failure.standardOutputData)
            #expect(retained.cleanupHandle == failure.cleanupHandle)
            if let handle = retained.cleanupHandle {
                try await handle.close(timeoutSeconds: 5)
                try await handle.close(timeoutSeconds: 0.1)
            }
        }
    }
}

// This existing-protocol fixture carries a real lower process failure; it is not a process backend.
private struct RetainedOracleFailure: TimingExternalOracleRunning {
    let failure: TimedProcessFailure
    func execute(_ request: TimingExternalOracleRequest) async throws -> TimingExternalOracleResult {
        throw TimedProcessError.executionFailed(failure)
    }
}

import CircuiteFoundation
import Foundation
import STAEngine
import Testing

@Suite("Timing CLI processes")
struct TimingCLIProcessTests {
    @Test("timing CLI invalid invocation exits nonzero")
    func timingCLIInvalidInvocationExitsNonzero() throws {
        let result = try runExecutable(named: "timingengine", arguments: [])

        #expect(result.exitCode != 0)
        #expect(result.standardOutput.contains("error"))
    }

    @Test("OpenSTA adapter invalid invocation exits nonzero")
    func openSTAAdapterInvalidInvocationExitsNonzero() throws {
        let result = try runExecutable(named: "opensta-oracle-adapter", arguments: [])

        #expect(result.exitCode != 0)
        #expect(result.standardOutput.contains("failed"))
    }

    @Test("OpenSTA adapter records the resolved executable SHA-256")
    func openSTAAdapterRecordsExecutableDigest() throws {
        let fixture = try OpenSTAProcessFixture(
            toolBody: """
            printf '%s\n' 'TIMINGENGINE_SETUP_BEGIN'
            printf '%s\n' 'slack (MET) 0.100'
            printf '%s\n' 'TIMINGENGINE_SETUP_END'
            printf '%s\n' 'TIMINGENGINE_HOLD_BEGIN'
            printf '%s\n' 'slack (MET) 0.050'
            printf '%s\n' 'TIMINGENGINE_HOLD_END'
            """
        )
        defer { fixture.remove() }

        let result = try runExecutable(
            named: "opensta-oracle-adapter",
            arguments: fixture.arguments(version: "3.1.0")
        )

        #expect(result.exitCode == 0)
        let execution = try JSONDecoder().decode(
            STAExecutionResult.self,
            from: Data(result.standardOutput.utf8)
        )
        let executableDigest = try SHA256ContentDigester().digest(
            fileAt: fixture.executable,
            using: .sha256
        )
        #expect(execution.status == .completed)
        #expect(execution.evidence.provenance.supportingTools.count == 1)
        #expect(execution.evidence.provenance.supportingTools[0].build == executableDigest.hexadecimalValue)
        let invocationExecutable = try #require(
            execution.evidence.provenance.invocation?.executable
        )
        #expect(invocationExecutable != fixture.executable.path(percentEncoded: false))
        #expect(invocationExecutable.hasPrefix(
            fixture.root.appending(path: ".timingengine/runs/opensta-process-fixture/opensta").path
        ))
        let standardOutput = try #require(execution.artifacts.first {
            $0.artifactID == "opensta-standard-output"
        })
        let standardError = try #require(execution.artifacts.first {
            $0.artifactID == "opensta-standard-error"
        })
        #expect(LocalArtifactVerifier().verify(standardOutput, relativeTo: fixture.root).isVerified)
        #expect(LocalArtifactVerifier().verify(standardError, relativeTo: fixture.root).isVerified)
        let standardOutputURL = try standardOutput.locator.location.resolvedFileURL(
            relativeTo: fixture.root
        )
        #expect(try String(contentsOf: standardOutputURL, encoding: .utf8)
            .contains("TIMINGENGINE_SETUP_BEGIN"))
    }

    @Test("OpenSTA adapter rejects a declared version not reported by the executable")
    func openSTAAdapterRejectsVersionMismatch() throws {
        let fixture = try OpenSTAProcessFixture(toolBody: "exit 0")
        defer { fixture.remove() }

        let result = try runExecutable(
            named: "opensta-oracle-adapter",
            arguments: fixture.arguments(version: "9.9.9")
        )

        #expect(result.exitCode != 0)
        let execution = try JSONDecoder().decode(
            STAExecutionResult.self,
            from: Data(result.standardOutput.utf8)
        )
        #expect(execution.status == .failed)
        #expect(execution.diagnostics.map(\.code.rawValue) == ["OPENSTA_VERSION_MISMATCH"])
    }

    @Test("OpenSTA adapter rejects a non-executable file")
    func openSTAAdapterRejectsNonExecutableFile() throws {
        let fixture = try OpenSTAProcessFixture(toolBody: "exit 0")
        defer { fixture.remove() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.executable.path(percentEncoded: false)
        )

        let result = try runExecutable(
            named: "opensta-oracle-adapter",
            arguments: fixture.arguments(version: "3.1.0")
        )

        #expect(result.exitCode != 0)
        let execution = try JSONDecoder().decode(
            STAExecutionResult.self,
            from: Data(result.standardOutput.utf8)
        )
        #expect(execution.status == .failed)
        #expect(execution.diagnostics.map(\.code.rawValue) == ["OPENSTA_EXECUTABLE_NOT_EXECUTABLE"])
    }

    @Test("OpenSTA adapter rejects executable mutation during analysis")
    func openSTAAdapterRejectsExecutableMutation() throws {
        let fixture = try OpenSTAProcessFixture(
            toolBody: """
            chmod u+w "$0"
            printf '%s\n' '# mutated during analysis' >> "$0"
            printf '%s\n' 'TIMINGENGINE_SETUP_BEGIN'
            printf '%s\n' 'slack (MET) 0.100'
            printf '%s\n' 'TIMINGENGINE_SETUP_END'
            printf '%s\n' 'TIMINGENGINE_HOLD_BEGIN'
            printf '%s\n' 'slack (MET) 0.050'
            printf '%s\n' 'TIMINGENGINE_HOLD_END'
            """
        )
        defer { fixture.remove() }

        let result = try runExecutable(
            named: "opensta-oracle-adapter",
            arguments: fixture.arguments(version: "3.1.0")
        )

        #expect(result.exitCode != 0)
        let execution = try JSONDecoder().decode(
            STAExecutionResult.self,
            from: Data(result.standardOutput.utf8)
        )
        #expect(execution.status == .failed)
        #expect(execution.diagnostics.map(\.code.rawValue) == ["OPENSTA_EXECUTABLE_MUTATED"])
        #expect(execution.artifacts.contains {
            $0.artifactID == "opensta-standard-output"
        })
        #expect(execution.artifacts.contains {
            $0.artifactID == "opensta-standard-error"
        })
    }

    @Test("OpenSTA adapter rejects run identifiers that are not stable path identities")
    func openSTAAdapterRejectsInvalidRunIdentifier() throws {
        let fixture = try OpenSTAProcessFixture(toolBody: "exit 0")
        defer { fixture.remove() }
        var arguments = fixture.arguments(version: "3.1.0")
        let runIDIndex = try #require(arguments.firstIndex(of: "--run-id")).advanced(by: 1)
        arguments[runIDIndex] = "../colliding-run"

        let result = try runExecutable(
            named: "opensta-oracle-adapter",
            arguments: arguments
        )

        #expect(result.exitCode != 0)
        let execution = try JSONDecoder().decode(
            STAExecutionResult.self,
            from: Data(result.standardOutput.utf8)
        )
        #expect(execution.status == .failed)
        #expect(execution.diagnostics.map(\.code.rawValue) == ["OPENSTA_ADAPTER_INPUT_INVALID"])
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appending(path: ".timingengine/runs/__colliding-run").path
        ))
    }

    private func runExecutable(
        named name: String,
        arguments: [String]
    ) throws -> (exitCode: Int32, standardOutput: String) {
        let process = Process()
        process.executableURL = try executableURL(named: name)
        process.arguments = arguments
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func executableURL(named name: String) throws -> URL {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let productsDirectory = environment["BUILT_PRODUCTS_DIR"] {
            candidates.append(URL(fileURLWithPath: productsDirectory).appending(path: name))
        }
        var processAncestor = URL(fileURLWithPath: CommandLine.arguments[0])
        for _ in 0..<8 {
            processAncestor.deleteLastPathComponent()
            candidates.append(processAncestor.appending(path: name))
        }
        var ancestor = Bundle.main.bundleURL
        for _ in 0..<6 {
            ancestor.deleteLastPathComponent()
            candidates.append(ancestor.appending(path: name))
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            var bundleAncestor = bundle.bundleURL
            for _ in 0..<6 {
                bundleAncestor.deleteLastPathComponent()
                candidates.append(bundleAncestor.appending(path: name))
            }
        }
        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false))
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }
}

private struct OpenSTAProcessFixture {
    let root: URL
    let executable: URL
    let design: URL
    let library: URL
    let constraints: URL
    let pdkManifest: URL

    init(toolBody: String, replacementBody: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "OpenSTAProcessFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appending(path: "opensta")
        design = root.appending(path: "design.v")
        library = root.appending(path: "cells.lib")
        constraints = root.appending(path: "constraints.sdc")
        pdkManifest = root.appending(path: "pdk.json")

        let tool = """
        #!/bin/sh
        if [ "$1" = "-version" ]; then
          printf '%s\n' 'OpenSTA 3.1.0'
          exit 0
        fi
        \(toolBody)
        """
        try Data(tool.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        if let replacementBody {
            let replacement = URL(filePath: executable.path(percentEncoded: false) + ".replacement")
            try Data("#!/bin/sh\n\(replacementBody)\n".utf8).write(to: replacement, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: replacement.path(percentEncoded: false)
            )
        }
        try Data("module top(); endmodule\n".utf8).write(to: design, options: .atomic)
        try Data("library(test) { time_unit : \"1ns\"; }\n".utf8).write(to: library, options: .atomic)
        try Data("create_clock -period 1 clk\n".utf8).write(to: constraints, options: .atomic)
        try Data("{}\n".utf8).write(to: pdkManifest, options: .atomic)
    }

    func arguments(version: String) -> [String] {
        [
            "--run-id", "opensta-process-fixture",
            "--oracle-id", "opensta",
            "--oracle-version", version,
            "--sta", executable.path(percentEncoded: false),
            "--design", design.path(percentEncoded: false),
            "--library", library.path(percentEncoded: false),
            "--constraints", constraints.path(percentEncoded: false),
            "--pdk-manifest", pdkManifest.path(percentEncoded: false),
            "--top", "top",
            "--workspace-root", root.path(percentEncoded: false),
            "--timeout", "5"
        ]
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record(error)
        }
    }
}

import CircuiteFoundation
import Foundation
@testable import OpenSTAOracleAdapter
import Testing
import TimingCore

@Suite("OpenSTA execution workspace")
struct OpenSTAExecutionWorkspaceTests {
    @Test("failed preparation leaves no committed workspace and the same run ID can retry")
    func failedPreparationAllowsSameRunIDRetry() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "OpenSTAExecutionWorkspaceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record(error)
            }
        }

        let executableURL = root.appending(path: "opensta")
        let designURL = root.appending(path: "design.json")
        let libraryURL = root.appending(path: "library.lib")
        let constraintsURL = root.appending(path: "constraints.sdc")
        let pdkURL = root.appending(path: "pdk.json")
        let executableData = Data("#!/bin/sh\nexit 0\n".utf8)
        let libraryData = Data("library(test) {}\n".utf8)
        try executableData.write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        try Data("{}\n".utf8).write(to: designURL, options: .atomic)
        try libraryData.write(to: libraryURL, options: .atomic)
        try Data("create_clock -period 1 clk\n".utf8).write(
            to: constraintsURL,
            options: .atomic
        )
        try Data("{}\n".utf8).write(to: pdkURL, options: .atomic)

        let builder = TimingArtifactReferenceBuilder()
        let design = try builder.makeReference(
            path: designURL.path,
            kind: .netlist,
            format: .json
        )
        let library = try builder.makeReference(
            path: libraryURL.path,
            kind: .timingLibrary,
            format: .liberty
        )
        let constraints = try builder.makeReference(
            path: constraintsURL.path,
            kind: .constraints,
            format: .sdc
        )
        let pdk = try builder.makeReference(
            path: pdkURL.path,
            kind: .technology,
            format: .json
        )
        let executable = OpenSTAExecutableValidator.ValidatedExecutable(
            url: executableURL,
            digest: try SHA256ContentDigester().digest(
                fileAt: executableURL,
                using: .sha256
            )
        )
        try FileManager.default.removeItem(at: libraryURL)

        #expect(throws: (any Error).self) {
            _ = try OpenSTAExecutionWorkspace.create(
                workspaceRoot: root,
                runID: "retryable-run",
                executable: executable,
                design: design,
                library: library,
                constraints: constraints,
                pdk: pdk,
                parasitics: nil
            )
        }

        let runRoot = root.appending(path: ".timingengine/runs/retryable-run")
        #expect(!FileManager.default.fileExists(
            atPath: runRoot.appending(path: "opensta").path
        ))
        let residualEntries = try FileManager.default.contentsOfDirectory(
            at: runRoot,
            includingPropertiesForKeys: nil
        )
        #expect(!residualEntries.contains {
            $0.lastPathComponent.hasPrefix(".opensta-preparing-")
        })

        try libraryData.write(to: libraryURL, options: .atomic)
        let retriedWorkspace = try OpenSTAExecutionWorkspace.create(
            workspaceRoot: root,
            runID: "retryable-run",
            executable: executable,
            design: design,
            library: library,
            constraints: constraints,
            pdk: pdk,
            parasitics: nil
        )

        #expect(retriedWorkspace.verifySnapshots())
        #expect(FileManager.default.fileExists(atPath: retriedWorkspace.root.path))
    }
}

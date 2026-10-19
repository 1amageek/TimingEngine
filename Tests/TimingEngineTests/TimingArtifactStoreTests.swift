import Foundation
import Testing
import TimingCore

@Suite("Contained immutable timing artifact storage", .timeLimit(.minutes(1)))
struct TimingArtifactStoreTests {
    private func withParent(_ body: (URL) async throws -> Void) async throws {
        // Every test owns a disjoint directory; no shared mutable fixture exists.
        let parent = URL(fileURLWithPath: "/private/tmp")
            .appending(path: "timing-store-owned-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: parent) }
            catch { Issue.record("Artifact store test cleanup failed: \(error)") }
        }
        try await body(parent)
    }
    private func expectWriteFailure(_ body: () async throws -> Void) async throws {
        do { try await body(); Issue.record("Expected typed artifact write failure.") }
        catch let error as TimingError {
            guard case .artifactWriteFailed = error else { throw error }
        }
    }

    @Test func privateAliasAcceptsMissingNestedOutputAndRoundTrips() async throws {
        try await withParent { parent in
            let root = parent.appending(path: "workspace")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let output = root.appending(path: "missing/nested")
            let store = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: output)
            let data = Data("original contained evidence".utf8)
            let binding = try await store.store(data, artifactName: "report", runID: "run", format: .json)
            #expect(try await FileSystemTimingArtifactReader(workspaceRoot: root).read(binding) == data)
            #expect(FileManager.default.fileExists(atPath: output.appending(path: "run/report.json").path))
        }
    }

    @Test func originalMissingWorkspaceRoundTripRemainsSupported() async throws {
        try await withParent { parent in
            let root = parent.appending(path: "not-created-workspace")
            let store = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: root)
            #expect(!FileManager.default.fileExists(atPath: root.path))
            let data = Data("workspace creation".utf8)
            let binding = try await store.store(data, runID: "run", format: .json)
            #expect(try await FileSystemTimingArtifactReader(workspaceRoot: root).read(binding) == data)
        }
    }

    @Test func outsidePrefixAndExistingOutputSymlinkAreRefused() async throws {
        try await withParent { parent in
            let root = parent.appending(path: "workspace"), outside = parent.appending(path: "workspace-other")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            #expect(throws: TimingError.self) {
                _ = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: outside.appending(path: "missing"))
            }
            let link = root.appending(path: "out")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            #expect(throws: TimingError.self) { _ = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: link) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    @Test func postInitOutputSymlinkRefusesBeforeOutsideDirectoryCreation() async throws {
        try await withParent { parent in
            let root = parent.appending(path: "workspace"), output = root.appending(path: "out")
            let outside = parent.appending(path: "outside")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let store = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: output)
            try FileManager.default.removeItem(at: output)
            try FileManager.default.createSymbolicLink(at: output, withDestinationURL: outside)
            try await expectWriteFailure { _ = try await store.store(Data("evidence".utf8), runID: "must-not-exist", format: .json) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    @Test func runDirectorySymlinkIsNotFollowed() async throws {
        try await withParent { parent in
            let root = parent.appending(path: "workspace"), output = root.appending(path: "out")
            let outside = parent.appending(path: "outside")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let store = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: output)
            try FileManager.default.createSymbolicLink(at: output.appending(path: "run"), withDestinationURL: outside)
            try await expectWriteFailure { _ = try await store.store(Data("evidence".utf8), runID: "run", format: .json) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    @Test func finalSymlinkCannotAlterOutsideFileAndLeavesNoStagingFile() async throws {
        try await withParent { parent in
            let root = parent.appending(path: "workspace"), output = root.appending(path: "out")
            let directory = output.appending(path: "run"), outside = parent.appending(path: "outside.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = Data("outside stays unchanged".utf8)
            try original.write(to: outside)
            let store = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: output)
            try FileManager.default.createSymbolicLink(at: directory.appending(path: "report.json"), withDestinationURL: outside)
            try await expectWriteFailure { _ = try await store.store(Data("different evidence".utf8), artifactName: "report", runID: "run", format: .json) }
            #expect(try Data(contentsOf: outside) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["report.json"])
        }
    }

    private enum Outcome: Sendable {
        case published(TimingArtifactBinding, Data)
        case rejected
        case unexpected(String)
    }
    @Test func concurrentImmutablePublicationHasOneWinnerAndExactReplay() async throws {
        try await withParent { parent in
            let root = parent.appending(path: "workspace")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: root.appending(path: "out"))
            let outcomes = await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
                let first = Data((0..<131_073).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 16)) })
                var second = first
                second[131_072] ^= 0xff
                for data in [first, second] {
                    group.addTask {
                        do { return .published(try await store.store(data, artifactName: "report", runID: "run", format: .json), data) }
                        catch let error as TimingError {
                            if case .artifactWriteFailed = error { return .rejected }
                            return .unexpected(String(describing: error))
                        } catch { return .unexpected(String(describing: error)) }
                    }
                }
                var all: [Outcome] = []
                for await value in group { all.append(value) }
                return all
            }
            let winners = outcomes.compactMap { value -> (TimingArtifactBinding, Data)? in
                if case .published(let binding, let data) = value { return (binding, data) }
                return nil
            }
            #expect(winners.count == 1)
            #expect(outcomes.filter { if case .rejected = $0 { return true }; return false }.count == 1)
            let (binding, data) = try #require(winners.first)
            #expect(try await FileSystemTimingArtifactReader(workspaceRoot: root).read(binding) == data)
            #expect(try await store.store(data, artifactName: "report", runID: "run", format: .json) == binding)
            try await expectWriteFailure { _ = try await store.store(Data("third evidence".utf8), artifactName: "report", runID: "run", format: .json) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "out/run").path) == ["report.json"])
        }
    }

    @Test func preCancelledStoreCreatesNoOutputOrTemporaryFile() async throws {
        try await withParent { parent in
            let root = parent.appending(path: "workspace"), output = root.appending(path: "not-created/out")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: output)
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                return try await store.store(Data("cancelled evidence".utf8), runID: "run", format: .json)
            }
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled store published evidence.") }
            catch is CancellationError {}
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func zeroByteArtifactRoundTripsWithoutPointerAccess() async throws {
        try await withParent { parent in
            let root = parent.appending(path: "workspace")
            let store = try FileSystemTimingArtifactStore(workspaceRoot: root, outputDirectory: root)
            let binding = try await store.store(Data(), artifactName: "empty", runID: "run", format: .json)
            #expect(binding.byteCount == 0)
            #expect(try await FileSystemTimingArtifactReader(workspaceRoot: root).read(binding).isEmpty)
            #expect(try await store.store(Data(), artifactName: "empty", runID: "run", format: .json) == binding)
        }
    }
}

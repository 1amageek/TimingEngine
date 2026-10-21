import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import Foundation
import Darwin

/// Reads an exact content identity from one explicitly bound materialization.
public protocol TimingArtifactReading: Sendable {
    func read(_ artifact: TimingArtifactBinding) async throws -> Data
    func read(_ artifact: TimingArtifactBinding, resources: any LibertySourceResourceAccounting)
        async throws -> TimingArtifactRead
}

/// Stores immutable artifacts and returns content identity plus its materialization binding.
public protocol TimingArtifactStoring: Sendable {
    func store(
        _ data: Data,
        artifactName: String?,
        runID: String,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) async throws -> TimingArtifactBinding
}

public struct FileSystemTimingArtifactReader: TimingArtifactReading {
    public let workspaceRoot: URL?
    public let readBudget: ArtifactAccessBudget
    /// Explicit caller grant for controlled local-file-system availability.
    /// Workspace-relative reads require only the separately supplied workspace root.
    public let allowControlledLocalFileSystemRoot: Bool

    public init(
        workspaceRoot: URL? = nil,
        readBudget: ArtifactAccessBudget = FileSystemTimingArtifactReader.defaultReadBudget,
        allowControlledLocalFileSystemRoot: Bool = false
    ) {
        self.workspaceRoot = workspaceRoot?.standardizedFileURL
        self.readBudget = readBudget
        self.allowControlledLocalFileSystemRoot = allowControlledLocalFileSystemRoot
    }

    public func read(_ artifact: TimingArtifactBinding) async throws -> Data {
        let local: (rootID: ArtifactRootID, relativePath: ArtifactRelativePath)
        do {
            local = try artifact.requireLocalAvailability()
        } catch {
            throw TimingError.artifactReadFailed(
                path: artifact.materializationDescription,
                message: error.localizedDescription
            )
        }
        let rootURL: URL
        switch local.rootID.rawValue {
        case TimingArtifactBinding.workspaceRootIdentifier:
            guard let workspaceRoot else {
                throw TimingError.artifactReadFailed(
                    path: artifact.materializationDescription,
                    message: "A workspace-root availability requires an exact workspace root."
                )
            }
            rootURL = workspaceRoot
        case TimingArtifactBinding.localFileSystemRootIdentifier:
            rootURL = URL(filePath: "/", directoryHint: .isDirectory)
        default:
            throw TimingError.artifactReadFailed(
                path: artifact.materializationDescription,
                message: "The local artifact root is not registered for this reader."
            )
        }

        let access: ArtifactRootCapability
        do {
            access = try ArtifactRootCapability(
                rootID: local.rootID,
                directoryURL: rootURL,
                digester: SHA256ContentDigester()
            )
        } catch {
            throw TimingError.artifactReadFailed(
                path: artifact.materializationDescription,
                message: String(describing: error)
            )
        }

        let data: Data
        do {
            data = try await read(artifact, using: access)
        } catch let primaryError {
            do {
                _ = try await access.close().wait()
            } catch let closeError {
                throw TimingError.artifactReadFailed(
                    path: artifact.materializationDescription,
                    message: "read failed: \(primaryError); root close failed: \(closeError)"
                )
            }
            throw primaryError
        }
        do {
            _ = try await access.close().wait()
        } catch {
            throw TimingError.artifactReadFailed(
                path: artifact.materializationDescription,
                message: "Artifact root close failed: \(error)"
            )
        }
        return data
    }

    private func read(
        _ artifact: TimingArtifactBinding,
        using access: ArtifactRootCapability
    ) async throws -> Data {
        let intent: ArtifactAccessIntent
        do {
            intent = try ArtifactAccessIntent(
                expectedReference: artifact.reference,
                availability: artifact.availability,
                operation: .read,
                budget: readBudget
            )
        } catch {
            throw TimingError.artifactReadFailed(
                path: artifact.materializationDescription,
                message: String(describing: error)
            )
        }

        let session: any ArtifactReadSession
        do {
            session = try await access.open(intent)
        } catch {
            throw TimingError.artifactReadFailed(
                path: artifact.materializationDescription,
                message: String(describing: error)
            )
        }

        do {
            var data = Data()
            var offset: UInt64 = 0
            while true {
                let page = try await session.readPage(
                    ArtifactReadPageRequest(
                        offset: offset,
                        maximumByteCount: readBudget.maximumPageByteCount
                    )
                )
                page.bytes.withUnsafeBytes { bytes in
                    data.append(contentsOf: bytes)
                }
                offset = page.cumulativeByteCount
                if page.completion == .complete {
                    guard page.finalReceipt?.observedArtifactID == artifact.id,
                          page.finalReceipt?.totalByteCount == artifact.byteCount else {
                        throw TimingError.invariantViolation(
                            "The terminal artifact receipt does not match the requested identity."
                        )
                    }
                    break
                }
            }
            _ = try await session.close().wait()
            return data
        } catch let primaryError {
            do {
                _ = try await session.close().wait()
            } catch let closeError {
                throw TimingError.artifactReadFailed(
                    path: artifact.materializationDescription,
                    message: "read failed: \(primaryError); session close failed: \(closeError)"
                )
            }
            if let timingError = primaryError as? TimingError {
                throw timingError
            }
            throw TimingError.artifactReadFailed(
                path: artifact.materializationDescription,
                message: String(describing: primaryError)
            )
        }
    }

    public static let defaultReadBudget: ArtifactAccessBudget = {
        do {
            return try ArtifactAccessBudget(
                maximumPageByteCount: 1_048_576,
                maximumTotalByteCount: 1_073_741_824,
                maximumPageCount: 1_024,
                maximumWorkUnitCount: 4_096,
                maximumDurationNanoseconds: 60_000_000_000
            )
        } catch {
            preconditionFailure("The static timing artifact read budget is invalid: \(error)")
        }
    }()
}

public struct FileSystemTimingArtifactStore: TimingArtifactStoring {
    public let workspaceRoot: URL
    public let outputDirectory: URL
    public let rootID: ArtifactRootID

    public init(
        workspaceRoot: URL,
        outputDirectory: URL,
        rootID: ArtifactRootID = FileSystemTimingArtifactStore.defaultRootID
    ) throws {
        let canonicalRoot = try Self.canonicalDirectoryPath(workspaceRoot)
        let canonicalOutput = try Self.canonicalDirectoryPath(outputDirectory)
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard canonicalOutput.path == canonicalRoot.path || canonicalOutput.path.hasPrefix(rootPrefix) else {
            throw TimingError.invalidInput("Timing artifact output directory is outside the workspace root.")
        }
        self.workspaceRoot = canonicalRoot
        self.outputDirectory = canonicalOutput
        self.rootID = rootID
    }

    public func store(
        _ data: Data,
        artifactName: String? = nil,
        runID: String,
        kind: ArtifactKind = .report,
        format: ArtifactFormat
    ) async throws -> TimingArtifactBinding {
        try Task.checkCancellation()
        try validatePathComponent(runID, label: "run ID")
        let digest = try SHA256ContentDigester().digest(data: data, using: .sha256)
        let artifactToken = artifactName ?? digest.hexadecimalValue
        try validatePathComponent(artifactToken, label: "artifact name")
        let filename = "\(artifactToken).\(format.rawValue)"
        guard !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TimingError.invalidInput("Invalid artifact filename.")
        }
        let rootPrefix = workspaceRoot.path.hasSuffix("/") ? workspaceRoot.path : workspaceRoot.path + "/"
        let outputComponents = outputDirectory.path == workspaceRoot.path ? []
            : String(outputDirectory.path.dropFirst(rootPrefix.count)).split(separator: "/").map(String.init)
        let relativeComponents = outputComponents + [runID, filename]
        let descriptor = ArtifactDescriptor(role: .output, kind: kind, format: format)
        let reference = try ArtifactReference(digest: digest, byteCount: UInt64(data.count), descriptor: descriptor)
        let binding = try TimingArtifactBinding(reference: reference, availability: .local(
            artifactID: reference.id, rootID: rootID,
            relativePath: ArtifactRelativePath(segments: relativeComponents)))
        let finalURL = outputDirectory.appending(path: runID).appending(path: filename)
        let rootComponents = workspaceRoot.path.split(separator: "/").map(String.init)
        let filesystemRoot = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard filesystemRoot >= 0 else { throw failure(finalURL.path, "Opening filesystem root: " + Self.reason()) }
        // Each scope consumes every descriptor exactly once. No descriptor/pointer escapes.
        // Only the final missing workspace component is created, preserving the public roundtrip.
        try withDirectory(filesystemRoot, components: rootComponents, createOnlyLast: true, path: finalURL.path) { workspace in
            let copy = fcntl(workspace, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw failure(finalURL.path, "Retaining workspace: " + Self.reason()) }
            try withDirectory(copy, components: outputComponents + [runID], createOnlyLast: false, path: finalURL.path) { directory in
                try publish(data, filename: filename, in: directory, path: finalURL.path)
            }
        }
        return binding
    }

    private static func canonicalDirectoryPath(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw TimingError.invalidInput("Timing artifact directories require absolute file URLs without NUL bytes.")
        }
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while true {
            var information = stat()
            let status = ancestor.path.withCString { lstat($0, &information) }
            if status == 0 { break }
            guard errno == ENOENT else {
                throw TimingError.invalidInput("Cannot inspect timing artifact directory: " + reason())
            }
            let component = ancestor.lastPathComponent
            guard !component.isEmpty, component != ".", component != ".." else {
                throw TimingError.invalidInput("Invalid timing artifact directory component.")
            }
            missing.append(component)
            ancestor.deleteLastPathComponent()
        }
        // realpath owns one allocated NUL-terminated result. The input is borrowed
        // only for this call; the result is copied to URL and freed exactly once.
        let resolved = ancestor.path.withCString { realpath($0, nil) }
        guard let resolved else {
            throw TimingError.invalidInput("Cannot resolve timing artifact directory: " + reason())
        }
        defer { free(resolved) }
        var result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        for component in missing.reversed() { result.appendPathComponent(component, isDirectory: true) }
        return result
    }

    private func withDirectory<Result>(
        _ initial: Int32, components: [String], createOnlyLast: Bool, path: String,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        var current = initial
        var ownsCurrent = true
        do {
            for (index, component) in components.enumerated() {
                try Task.checkCancellation()
                var next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if next < 0, errno == ENOENT, !createOnlyLast || index == components.count - 1 {
                    try Task.checkCancellation()
                    let created = component.withCString { mkdirat(current, $0, 0o755) }
                    guard created == 0 || errno == EEXIST else {
                        throw failure(path, "Creating artifact directory: " + Self.reason())
                    }
                    next = component.withCString {
                        openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                }
                guard next >= 0 else { throw failure(path, "Opening no-follow artifact directory: " + Self.reason()) }
                let previous = current
                current = next
                try closeDescriptor(previous, path: path)
            }
            let result = try body(current)
            ownsCurrent = false
            try closeDescriptor(current, path: path)
            return result
        } catch let primary {
            if ownsCurrent {
                ownsCurrent = false
                do { try closeDescriptor(current, path: path) }
                catch let cleanup { throw failure(path, "\(primary); directory cleanup failed: \(cleanup)") }
            }
            throw primary
        }
    }

    private func publish(_ data: Data, filename: String, in directory: Int32, path: String) throws {
        try Task.checkCancellation()
        let temporary = ".timing-" + UUID().uuidString + ".tmp"
        let file = temporary.withCString {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard file >= 0 else { throw failure(path, "Creating exclusive artifact staging file: " + Self.reason()) }
        var ownsFile = true
        var ownsTemporaryName = true
        do {
            // Data's contiguous bytes are borrowed only in this closure. Checked
            // offsets stay within count; no pointer survives the synchronous write.
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let amount = min(bytes.count - offset, 65_536)
                    let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), amount)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw failure(path, "Writing artifact bytes: " + Self.reason()) }
                    offset += count
                }
            }
            var staged = stat()
            guard fstat(file, &staged) == 0, staged.st_mode & S_IFMT == S_IFREG,
                  staged.st_size == off_t(data.count) else {
                throw failure(path, "The staged artifact is not the complete regular file.")
            }
            try Task.checkCancellation()
            let published = temporary.withCString { source in
                filename.withCString { destination in linkat(directory, source, directory, destination, 0) }
            }
            if published != 0 {
                guard errno == EEXIST else { throw failure(path, "Publishing immutable artifact: " + Self.reason()) }
                try requireExactExisting(data, filename: filename, directory: directory, path: path)
            } else {
                var final = stat()
                let inspected = filename.withCString { fstatat(directory, $0, &final, AT_SYMLINK_NOFOLLOW) }
                guard inspected == 0, final.st_mode & S_IFMT == S_IFREG,
                      final.st_dev == staged.st_dev, final.st_ino == staged.st_ino,
                      final.st_size == staged.st_size else {
                    throw failure(path, "Published artifact entry no longer matches its owned staging descriptor.")
                }
            }
            ownsFile = false
            try closeDescriptor(file, path: path)
            // Publication is the commit point. Cleanup failure is reported; a
            // cancellation arriving afterwards does not claim the artifact is absent.
            ownsTemporaryName = false
            try removeTemporary(temporary, directory: directory, path: path)
        } catch let primary {
            var cleanupFailures: [String] = []
            if ownsFile {
                ownsFile = false
                do { try closeDescriptor(file, path: path) }
                catch { cleanupFailures.append(String(describing: error)) }
            }
            if ownsTemporaryName {
                ownsTemporaryName = false
                do { try removeTemporary(temporary, directory: directory, path: path) }
                catch { cleanupFailures.append(String(describing: error)) }
            }
            if !cleanupFailures.isEmpty {
                throw failure(path, "\(primary); staging cleanup failed: " + cleanupFailures.joined(separator: "; "))
            }
            throw primary
        }
    }

    private func requireExactExisting(_ data: Data, filename: String, directory: Int32, path: String) throws {
        let file = filename.withCString { openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard file >= 0 else { throw failure(path, "Opening existing immutable artifact: " + Self.reason()) }
        var ownsFile = true
        do {
            var information = stat()
            guard fstat(file, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
                  information.st_size == off_t(data.count) else {
                throw failure(path, "An immutable artifact entry is nonregular or has different content.")
            }
            // One initialized comparison buffer; each source/destination borrow is
            // synchronous and offsets are checked against the retained Data count.
            var buffer = [UInt8](repeating: 0, count: min(max(1, data.count), 65_536))
            try data.withUnsafeBytes { expected in
                var offset = 0
                while offset < expected.count {
                    try Task.checkCancellation()
                    let amount = min(expected.count - offset, buffer.count)
                    let count = buffer.withUnsafeMutableBytes { pread(file, $0.baseAddress, amount, off_t(offset)) }
                    if count < 0, errno == EINTR { continue }
                    guard count == amount else { throw failure(path, "Reading immutable artifact content failed.") }
                    let equal = buffer.withUnsafeBytes { memcmp($0.baseAddress!, expected.baseAddress!.advanced(by: offset), amount) == 0 }
                    guard equal else { throw failure(path, "An immutable artifact with the same identity already exists with different content.") }
                    offset += amount
                }
            }
            ownsFile = false
            try closeDescriptor(file, path: path)
        } catch let primary {
            if ownsFile {
                ownsFile = false
                do { try closeDescriptor(file, path: path) }
                catch let cleanup { throw failure(path, "\(primary); immutable read cleanup failed: \(cleanup)") }
            }
            throw primary
        }
    }

    private func removeTemporary(_ name: String, directory: Int32, path: String) throws {
        let result = name.withCString { unlinkat(directory, $0, 0) }
        guard result == 0 || errno == ENOENT else { throw failure(path, "Removing artifact staging file: " + Self.reason()) }
    }
    private func closeDescriptor(_ descriptor: Int32, path: String) throws {
        // Consume once even if close reports failure; retrying can close a reused descriptor.
        guard Darwin.close(descriptor) == 0 else { throw failure(path, "Closing artifact descriptor: " + Self.reason()) }
    }
    private func failure(_ path: String, _ reason: String) -> TimingError {
        .artifactWriteFailed(path: path, message: reason)
    }
    private static func reason() -> String { String(cString: strerror(errno)) }
    private func validatePathComponent(_ value: String, label: String) throws {
        guard !value.isEmpty, !value.contains("/"), !value.contains("\\"), !value.contains(".."),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TimingError.invalidInput("Invalid \(label) path component.")
        }
    }
    public static let defaultRootID: ArtifactRootID = {
        do { return try ArtifactRootID(rawValue: TimingArtifactBinding.workspaceRootIdentifier) }
        catch { preconditionFailure("The static timing artifact root ID is invalid: \(error)") }
    }()
}

public struct InMemoryTimingArtifactReader: TimingArtifactReading {
    public var artifacts: [ArtifactID: Data]

    public init(artifacts: [ArtifactID: Data]) {
        self.artifacts = artifacts
    }

    public func read(_ artifact: TimingArtifactBinding) async throws -> Data {
        let reference = artifact.reference
        guard let data = artifacts[reference.id] else {
            throw TimingError.artifactReadFailed(
                path: artifact.materializationDescription,
                message: "No in-memory artifact was registered for the exact content identity."
            )
        }
        if UInt64(data.count) != reference.byteCount {
            throw TimingError.artifactSizeMismatch(path: artifact.materializationDescription, expected: Int64(reference.byteCount), actual: Int64(data.count))
        }
        let actual = try SHA256ContentDigester().digest(data: data, using: reference.digest.algorithm)
        guard actual == reference.digest else {
            throw TimingError.artifactDigestMismatch(path: artifact.materializationDescription)
        }
        return data
    }
}

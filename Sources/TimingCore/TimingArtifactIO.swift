import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import Foundation

/// Reads an exact content identity from one explicitly bound materialization.
public protocol TimingArtifactReading: Sendable {
    func read(_ artifact: TimingArtifactBinding) async throws -> Data
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

    public init(
        workspaceRoot: URL? = nil,
        readBudget: ArtifactAccessBudget = FileSystemTimingArtifactReader.defaultReadBudget
    ) {
        self.workspaceRoot = workspaceRoot?.standardizedFileURL
        self.readBudget = readBudget
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
        let canonicalRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalOutput = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        guard canonicalOutput.path == canonicalRoot.path
            || canonicalOutput.path.hasPrefix(rootPrefix) else {
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
        try validatePathComponent(runID, label: "run ID")
        let digest = try SHA256ContentDigester().digest(data: data, using: .sha256)
        let artifactToken = artifactName ?? digest.hexadecimalValue
        try validatePathComponent(artifactToken, label: "artifact name")
        let directory = outputDirectory.appending(path: runID, directoryHint: .isDirectory)
        let url = directory.appending(path: "\(artifactToken).\(format.rawValue)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try requireContainedWithoutSymlink(directory)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try requireContainedWithoutSymlink(url)
                let existingData = try Data(contentsOf: url)
                let existingDigest = try SHA256ContentDigester().digest(data: existingData, using: .sha256)
                guard existingData.count == data.count,
                      existingDigest == digest else {
                    throw TimingError.artifactWriteFailed(
                        path: url.path(percentEncoded: false),
                        message: "An immutable artifact with the same identity already exists with different content."
                    )
                }
            } else {
                try data.write(to: url, options: .atomic)
                try requireContainedWithoutSymlink(url)
            }
        } catch {
            if let timingError = error as? TimingError {
                throw timingError
            }
            throw TimingError.artifactWriteFailed(path: url.path(percentEncoded: false), message: error.localizedDescription)
        }
        do {
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let rootPrefix = workspaceRoot.path.hasSuffix("/")
                ? workspaceRoot.path
                : workspaceRoot.path + "/"
            guard canonicalURL.path.hasPrefix(rootPrefix) else {
                throw TimingError.artifactWriteFailed(
                    path: canonicalURL.path(percentEncoded: false),
                    message: "Artifact path escaped the workspace root."
                )
            }
            let relativePath = String(canonicalURL.path.dropFirst(rootPrefix.count))
            let descriptor = ArtifactDescriptor(
                role: .output,
                kind: kind,
                format: format
            )
            let reference = try ArtifactReference(
                digest: digest,
                byteCount: UInt64(data.count),
                descriptor: descriptor
            )
            return try TimingArtifactBinding(
                reference: reference,
                availability: .local(
                    artifactID: reference.id,
                    rootID: rootID,
                    relativePath: ArtifactRelativePath(
                        segments: relativePath.split(separator: "/").map(String.init)
                    )
                )
            )
        } catch {
            throw TimingError.artifactWriteFailed(path: url.path(percentEncoded: false), message: error.localizedDescription)
        }
    }

    private func validatePathComponent(_ value: String, label: String) throws {
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains(".."),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TimingError.invalidInput("Invalid \(label) path component.")
        }
    }

    private func requireContainedWithoutSymlink(_ url: URL) throws {
        let lexicalURL = url.standardizedFileURL
        let resolvedURL = lexicalURL.resolvingSymlinksInPath()
        let rootPrefix = workspaceRoot.path.hasSuffix("/")
            ? workspaceRoot.path
            : workspaceRoot.path + "/"
        guard lexicalURL.path == resolvedURL.path,
              resolvedURL.path == workspaceRoot.path || resolvedURL.path.hasPrefix(rootPrefix) else {
            throw TimingError.artifactWriteFailed(
                path: lexicalURL.path(percentEncoded: false),
                message: "Artifact path escaped the workspace root or traversed a symbolic link."
            )
        }
    }

    public static let defaultRootID: ArtifactRootID = {
        do {
            return try ArtifactRootID(
                rawValue: TimingArtifactBinding.workspaceRootIdentifier
            )
        } catch {
            preconditionFailure("The static timing artifact root ID is invalid: \(error)")
        }
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

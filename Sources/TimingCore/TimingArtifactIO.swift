import CryptoKit
import CircuiteFoundation
import Foundation
import ToolQualification

/// Reads immutable artifacts addressed by the canonical Foundation contract.
public protocol TimingArtifactReading: Sendable {
    func read(_ reference: ArtifactReference) async throws -> Data
}

/// Stores immutable artifacts and returns their canonical Foundation identity.
public protocol TimingArtifactStoring: Sendable {
    func store(
        _ data: Data,
        artifactID: ArtifactID?,
        runID: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        producer: ProducerIdentity?
    ) async throws -> ArtifactReference
}

public struct FileSystemTimingArtifactReader: TimingArtifactReading, ToolQualificationArtifactReading {
    public let workspaceRoot: URL?

    public init(workspaceRoot: URL? = nil) {
        self.workspaceRoot = workspaceRoot?.standardizedFileURL
    }

    public func read(_ reference: ArtifactReference) async throws -> Data {
        let integrity = LocalArtifactVerifier().verify(reference, relativeTo: workspaceRoot)
        guard integrity.isVerified else {
            let message = integrity.issues
                .map { $0.detail ?? $0.code.rawValue }
                .joined(separator: "; ")
            throw TimingError.artifactReadFailed(
                path: reference.locator.location.value,
                message: message
            )
        }
        let url: URL
        do {
            url = try reference.locator.location.resolvedFileURL(relativeTo: workspaceRoot)
        } catch {
            throw TimingError.artifactReadFailed(
                path: reference.locator.location.value,
                message: error.localizedDescription
            )
        }
        let data = try readData(at: url, expectedByteCount: reference.byteCount, expectedDigest: reference.digest.hexadecimalValue)
        return data
    }

    public func verifiedData(for reference: ArtifactReference) async throws -> Data {
        try await read(reference)
    }

    private func readData(
        at url: URL,
        expectedByteCount: UInt64?,
        expectedDigest: String?
    ) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TimingError.artifactReadFailed(path: url.path(percentEncoded: false), message: error.localizedDescription)
        }
        if let byteCount = expectedByteCount, byteCount != UInt64(data.count) {
            throw TimingError.artifactSizeMismatch(path: url.path(percentEncoded: false), expected: Int64(byteCount), actual: Int64(data.count))
        }
        if let digest = expectedDigest {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(digest) == .orderedSame else {
                throw TimingError.artifactDigestMismatch(path: url.path(percentEncoded: false))
            }
        }
        return data
    }
}

public struct FileSystemTimingArtifactStore: TimingArtifactStoring {
    public let workspaceRoot: URL
    public let outputDirectory: URL

    public init(workspaceRoot: URL, outputDirectory: URL) throws {
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
    }

    public func store(
        _ data: Data,
        artifactID: ArtifactID? = nil,
        runID: String,
        kind: ArtifactKind = .report,
        format: ArtifactFormat,
        producer: ProducerIdentity? = nil
    ) async throws -> ArtifactReference {
        try validatePathComponent(runID, label: "run ID")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let resolvedArtifactID = artifactID ?? ArtifactID(stableKey: "timing-artifact:\(runID):\(digest)")
        let artifactToken = resolvedArtifactID.rawValue
        try validatePathComponent(artifactToken, label: "artifact ID")
        let directory = outputDirectory.appending(path: runID, directoryHint: .isDirectory)
        let url = directory.appending(path: "\(artifactToken).\(format.rawValue)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try requireContainedWithoutSymlink(directory)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try requireContainedWithoutSymlink(url)
                let existingData = try Data(contentsOf: url)
                let existingDigest = SHA256.hash(data: existingData).map { String(format: "%02x", $0) }.joined()
                guard existingData.count == data.count,
                      existingDigest.caseInsensitiveCompare(digest) == .orderedSame else {
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
            return ArtifactReference(
                id: resolvedArtifactID,
                locator: ArtifactLocator(
                    location: try ArtifactLocation(workspaceRelativePath: relativePath),
                    role: .output,
                    kind: kind,
                    format: format
                ),
                digest: try ContentDigest(algorithm: .sha256, hexadecimalValue: digest),
                byteCount: UInt64(data.count),
                producer: producer
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
}

public struct InMemoryTimingArtifactReader: TimingArtifactReading, ToolQualificationArtifactReading {
    public var artifacts: [String: Data]

    public init(artifacts: [String: Data]) {
        self.artifacts = artifacts
    }

    public func read(_ reference: ArtifactReference) async throws -> Data {
        let keys = [
            reference.locator.location.value,
            reference.locator.location.value.replacingOccurrences(of: "file://", with: ""),
            URL(string: reference.locator.location.value)?.lastPathComponent ?? ""
        ]
        guard let data = keys.lazy.compactMap({ artifacts[$0] }).first else {
            throw TimingError.artifactReadFailed(path: reference.locator.location.value, message: "No in-memory artifact was registered.")
        }
        if UInt64(data.count) != reference.byteCount {
            throw TimingError.artifactSizeMismatch(path: reference.locator.location.value, expected: Int64(reference.byteCount), actual: Int64(data.count))
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(reference.digest.hexadecimalValue) == .orderedSame else {
            throw TimingError.artifactDigestMismatch(path: reference.locator.location.value)
        }
        return data
    }

    public func verifiedData(for reference: ArtifactReference) async throws -> Data {
        try await read(reference)
    }

}

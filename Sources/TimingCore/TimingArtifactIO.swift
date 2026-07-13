import CryptoKit
import CircuiteFoundation
import Foundation
import DesignFlowKernel

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

public struct FileSystemTimingArtifactReader: TimingArtifactReading {
    public let workspaceRoot: URL?

    public init(workspaceRoot: URL? = nil) {
        self.workspaceRoot = workspaceRoot?.standardizedFileURL
    }

    public func read(_ reference: ArtifactReference) async throws -> Data {
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
    public var outputDirectory: URL

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
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
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
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
            }
        } catch {
            if let timingError = error as? TimingError {
                throw timingError
            }
            throw TimingError.artifactWriteFailed(path: url.path(percentEncoded: false), message: error.localizedDescription)
        }
        do {
            return ArtifactReference(
                id: resolvedArtifactID,
                locator: ArtifactLocator(
                    location: try ArtifactLocation(fileURL: url),
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
}

public struct InMemoryTimingArtifactReader: TimingArtifactReading {
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

}

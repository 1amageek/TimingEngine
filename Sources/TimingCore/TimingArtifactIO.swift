import CryptoKit
import Foundation
import XcircuitePackage

public protocol TimingArtifactReading: Sendable {
    func read(_ reference: XcircuiteFileReference) async throws -> Data
}

public protocol TimingArtifactStoring: Sendable {
    func store(
        _ data: Data,
        artifactID: String,
        runID: String,
        format: XcircuiteFileFormat
    ) async throws -> XcircuiteFileReference
}

public struct FileSystemTimingArtifactReader: TimingArtifactReading {
    public init() {}

    public func read(_ reference: XcircuiteFileReference) async throws -> Data {
        let url = URL(filePath: reference.path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TimingError.artifactReadFailed(path: reference.path, message: error.localizedDescription)
        }
        if let byteCount = reference.byteCount, byteCount != Int64(data.count) {
            throw TimingError.artifactSizeMismatch(path: reference.path, expected: byteCount, actual: Int64(data.count))
        }
        if let digest = reference.sha256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(digest) == .orderedSame else {
                throw TimingError.artifactDigestMismatch(path: reference.path)
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
        artifactID: String,
        runID: String,
        format: XcircuiteFileFormat
    ) async throws -> XcircuiteFileReference {
        let directory = outputDirectory.appending(path: runID, directoryHint: .isDirectory)
        let fileExtension: String
        switch format {
        case .json:
            fileExtension = "json"
        case .sdf:
            fileExtension = "sdf"
        case .spef:
            fileExtension = "spef"
        default:
            fileExtension = "dat"
        }
        let url = directory.appending(path: "\(artifactID).\(fileExtension)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw TimingError.artifactWriteFailed(path: url.path(percentEncoded: false), message: error.localizedDescription)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return XcircuiteFileReference(
            artifactID: artifactID,
            path: url.path(percentEncoded: false),
            kind: .report,
            format: format,
            sha256: digest,
            byteCount: Int64(data.count),
            producedByRunID: runID
        )
    }
}

public struct InMemoryTimingArtifactReader: TimingArtifactReading {
    public var artifacts: [String: Data]

    public init(artifacts: [String: Data]) {
        self.artifacts = artifacts
    }

    public func read(_ reference: XcircuiteFileReference) async throws -> Data {
        guard let data = artifacts[reference.path] else {
            throw TimingError.artifactReadFailed(path: reference.path, message: "No in-memory artifact was registered.")
        }
        return data
    }
}

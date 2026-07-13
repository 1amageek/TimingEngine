import CryptoKit
import CircuiteFoundation
import Foundation
import XcircuitePackage

public struct TimingArtifactReferenceBuilder: Sendable {
    public init() {}

    /// Creates an immutable reference in the canonical Foundation model.
    public func makeReference(
        path: String,
        kind: ArtifactKind,
        format: ArtifactFormat,
        artifactID: String? = nil
    ) throws -> ArtifactReference {
        let url = URL(filePath: path).standardizedFileURL
        let location = try ArtifactLocation(fileURL: url)
        let locator = ArtifactLocator(location: location, kind: kind, format: format)
        let id = try artifactID.map { try ArtifactID(rawValue: $0) }
        do {
            let referenced = try LocalArtifactReferencer().reference(locator, relativeTo: nil, producer: nil)
            return ArtifactReference(
                id: id ?? referenced.id,
                locator: referenced.locator,
                digest: referenced.digest,
                byteCount: referenced.byteCount,
                producer: referenced.producer
            )
        } catch {
            if let error = error as? TimingError {
                throw error
            }
            throw TimingError.artifactReadFailed(path: url.path(percentEncoded: false), message: error.localizedDescription)
        }
    }

    @available(*, deprecated, message: "Use makeReference(path:kind:format:artifactID:) with Foundation types.")
    public func makeReference(
        path: String,
        kind: XcircuiteFileKind,
        format: XcircuiteFileFormat,
        artifactID: String? = nil
    ) throws -> XcircuiteFileReference {
        let url = URL(filePath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TimingError.artifactReadFailed(path: path, message: error.localizedDescription)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return XcircuiteFileReference(
            artifactID: artifactID,
            path: url.standardizedFileURL.path(percentEncoded: false),
            kind: kind,
            format: format,
            sha256: digest,
            byteCount: Int64(data.count)
        )
    }
}

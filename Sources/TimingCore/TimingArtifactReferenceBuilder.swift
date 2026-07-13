import CryptoKit
import CircuiteFoundation
import Foundation
import DesignFlowKernel

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
        let locator = ArtifactLocator(
            location: location,
            role: .input,
            kind: kind,
            format: format
        )
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
}

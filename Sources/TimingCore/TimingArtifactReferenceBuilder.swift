import CryptoKit
import CircuiteFoundation
import Foundation

public struct TimingArtifactReferenceBuilder: Sendable {
    public init() {}

    /// Creates an immutable reference in the canonical Foundation model.
    public func makeReference(
        path: String,
        role: ArtifactRole = .input,
        kind: ArtifactKind,
        format: ArtifactFormat,
        artifactID: String? = nil
    ) throws -> ArtifactReference {
        let url = URL(filePath: path).standardizedFileURL
        let location = try ArtifactLocation(fileURL: url)
        let locator = ArtifactLocator(
            location: location,
            role: role,
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

    /// Creates a workspace-relative immutable reference and rejects containment escapes.
    public func makeReference(
        at fileURL: URL,
        relativeTo workspaceRoot: URL,
        role: ArtifactRole = .input,
        kind: ArtifactKind,
        format: ArtifactFormat,
        artifactID: String? = nil
    ) throws -> ArtifactReference {
        let canonicalRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        guard canonicalFile.path.hasPrefix(rootPrefix) else {
            throw TimingError.invalidInput("Artifact is outside the declared workspace root.")
        }
        let relativePath = String(canonicalFile.path.dropFirst(rootPrefix.count))
        let locator = ArtifactLocator(
            location: try ArtifactLocation(workspaceRelativePath: relativePath),
            role: role,
            kind: kind,
            format: format
        )
        let id = try artifactID.map { try ArtifactID(rawValue: $0) }
        do {
            let referenced = try LocalArtifactReferencer().reference(
                locator,
                relativeTo: canonicalRoot,
                producer: nil
            )
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
            throw TimingError.artifactReadFailed(
                path: canonicalFile.path(percentEncoded: false),
                message: error.localizedDescription
            )
        }
    }
}

import CircuiteFoundation
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import Foundation

public struct TimingArtifactReferenceBuilder: Sendable {
    public init() {}

    /// Attests content and binds it to an execution-scoped local-filesystem availability.
    public func makeBinding(
        path: String,
        role: ArtifactRole = .input,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> TimingArtifactBinding {
        let url = try canonicalFileURL(URL(filePath: path))
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw TimingError.invalidInput("Timing artifact paths must be absolute file paths.")
        }
        let locator = ArtifactLocator(
            location: try ArtifactLocation(fileURL: url),
            role: role,
            kind: kind,
            format: format
        )
        do {
            let reference = try LocalArtifactReferencer().reference(locator, relativeTo: nil)
            return try TimingArtifactBinding(
                reference: reference,
                availability: .local(
                    artifactID: reference.id,
                    rootID: ArtifactRootID(
                        rawValue: TimingArtifactBinding.localFileSystemRootIdentifier
                    ),
                    relativePath: ArtifactRelativePath(
                        segments: url.pathComponents.filter { $0 != "/" }
                    )
                )
            )
        } catch {
            if let error = error as? TimingError {
                throw error
            }
            throw TimingError.artifactReadFailed(
                path: url.path(percentEncoded: false),
                message: error.localizedDescription
            )
        }
    }

    /// Attests content and binds it to a workspace-root availability.
    public func makeBinding(
        at fileURL: URL,
        relativeTo workspaceRoot: URL,
        role: ArtifactRole = .input,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> TimingArtifactBinding {
        let canonicalRoot = try canonicalFileURL(workspaceRoot)
        let canonicalFile = try canonicalFileURL(fileURL)
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
        do {
            let reference = try LocalArtifactReferencer().reference(
                locator,
                relativeTo: canonicalRoot
            )
            return try TimingArtifactBinding(
                reference: reference,
                availability: .local(
                    artifactID: reference.id,
                    rootID: ArtifactRootID(
                        rawValue: TimingArtifactBinding.workspaceRootIdentifier
                    ),
                    relativePath: ArtifactRelativePath(
                        segments: relativePath.split(separator: "/").map(String.init)
                    )
                )
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

    private func canonicalFileURL(_ input: URL) throws -> URL {
        guard input.isFileURL, input.path.hasPrefix("/") else {
            throw TimingError.invalidInput("Timing artifact paths must be absolute file paths.")
        }
        var unresolved = input.standardizedFileURL.pathComponents.filter { $0 != "/" }
        var resolved = URL(filePath: "/", directoryHint: .isDirectory)
        var symlinkCount = 0
        while !unresolved.isEmpty {
            let component = unresolved.removeFirst()
            let candidate = resolved.appending(path: component)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(
                    atPath: candidate.path(percentEncoded: false)
                )
            } catch {
                throw TimingError.artifactReadFailed(
                    path: candidate.path(percentEncoded: false),
                    message: error.localizedDescription
                )
            }
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                resolved = candidate
                continue
            }
            symlinkCount += 1
            guard symlinkCount <= 64 else {
                throw TimingError.artifactReadFailed(
                    path: candidate.path(percentEncoded: false),
                    message: "Artifact path contains too many symbolic-link expansions."
                )
            }
            let destination: String
            do {
                destination = try FileManager.default.destinationOfSymbolicLink(
                    atPath: candidate.path(percentEncoded: false)
                )
            } catch {
                throw TimingError.artifactReadFailed(
                    path: candidate.path(percentEncoded: false),
                    message: error.localizedDescription
                )
            }
            let destinationURL = destination.hasPrefix("/")
                ? URL(filePath: destination)
                : resolved.appending(path: destination)
            unresolved = destinationURL.pathComponents
                .filter { $0 != "/" } + unresolved
            resolved = URL(filePath: "/", directoryHint: .isDirectory)
        }
        return resolved
    }
}

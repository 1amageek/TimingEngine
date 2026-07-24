import CircuiteFoundation
import Foundation
import TimingCore

struct OpenSTAExecutionWorkspace {
    let root: URL
    let executable: OpenSTAExecutableValidator.ValidatedExecutable
    let designURL: URL
    let libraryURL: URL
    let constraintsURL: URL
    let pdkURL: URL
    let spefURL: URL?
    let snapshotReferences: [ArtifactReference]

    static func create(
        workspaceRoot: URL,
        runID: String,
        executable: OpenSTAExecutableValidator.ValidatedExecutable,
        design: ArtifactReference,
        library: ArtifactReference,
        constraints: ArtifactReference,
        pdk: ArtifactReference,
        parasitics: ArtifactReference?
    ) throws -> Self {
        let fileManager = FileManager.default
        let canonicalWorkspaceRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let allowedRunIDScalars = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !runID.isEmpty,
              runID.count <= 128,
              runID != ".",
              runID != "..",
              runID.unicodeScalars.allSatisfy({ allowedRunIDScalars.contains($0) }) else {
            throw TimingError.invalidInput("OpenSTA run ID is not a valid immutable path identity.")
        }
        let runsRoot = canonicalWorkspaceRoot
            .appending(path: ".timingengine", directoryHint: .isDirectory)
            .appending(path: "runs", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        let canonicalRunsRoot = runsRoot.resolvingSymlinksInPath()
        guard canonicalRunsRoot.path == canonicalWorkspaceRoot.path
            || canonicalRunsRoot.path.hasPrefix(canonicalWorkspaceRoot.path + "/") else {
            throw TimingError.invalidInput("OpenSTA output root escapes the workspace.")
        }
        let root = canonicalRunsRoot
            .appending(path: runID, directoryHint: .isDirectory)
            .appending(path: "opensta", directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw TimingError.artifactWriteFailed(
                path: root.path,
                message: "The immutable OpenSTA run workspace already exists."
            )
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let inputs = root.appending(path: "inputs", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: inputs, withIntermediateDirectories: false)

        let executableURL = inputs.appending(path: "opensta")
        try fileManager.copyItem(at: executable.url, to: executableURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: executableURL.path
        )
        let executableSnapshot = OpenSTAExecutableValidator.ValidatedExecutable(
            url: executableURL,
            digest: executable.digest
        )
        try OpenSTAExecutableValidator().revalidate(executableSnapshot)

        var references: [ArtifactReference] = []
        let designURL = try snapshot(
            design,
            named: "design.\(design.locator.format.rawValue)",
            in: inputs,
            relativeTo: canonicalWorkspaceRoot
        )
        references.append(try snapshotReference(design, at: designURL))
        let libraryURL = try snapshot(
            library,
            named: "library.lib",
            in: inputs,
            relativeTo: canonicalWorkspaceRoot
        )
        references.append(try snapshotReference(library, at: libraryURL))
        let constraintsURL = try snapshot(
            constraints,
            named: "constraints.sdc",
            in: inputs,
            relativeTo: canonicalWorkspaceRoot
        )
        references.append(try snapshotReference(constraints, at: constraintsURL))
        let pdkURL = try snapshot(
            pdk,
            named: "pdk.json",
            in: inputs,
            relativeTo: canonicalWorkspaceRoot
        )
        references.append(try snapshotReference(pdk, at: pdkURL))
        let spefURL: URL?
        if let parasitics {
            let url = try snapshot(
                parasitics,
                named: "parasitics.spef",
                in: inputs,
                relativeTo: canonicalWorkspaceRoot
            )
            references.append(try snapshotReference(parasitics, at: url))
            spefURL = url
        } else {
            spefURL = nil
        }

        return Self(
            root: root,
            executable: executableSnapshot,
            designURL: designURL,
            libraryURL: libraryURL,
            constraintsURL: constraintsURL,
            pdkURL: pdkURL,
            spefURL: spefURL,
            snapshotReferences: references
        )
    }

    func verifySnapshots() -> Bool {
        let verifier = LocalArtifactVerifier()
        return snapshotReferences.allSatisfy { verifier.verify($0).isVerified }
    }

    private static func snapshot(
        _ reference: ArtifactReference,
        named name: String,
        in directory: URL,
        relativeTo workspaceRoot: URL
    ) throws -> URL {
        let source = try reference.locator.location.resolvedFileURL(relativeTo: workspaceRoot)
        let destination = directory.appending(path: name)
        // External STA requires filesystem paths. An owned immutable copy closes
        // the digest-check-to-process-use mutation window.
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: destination.path
        )
        let snapshot = try snapshotReference(reference, at: destination)
        guard LocalArtifactVerifier().verify(snapshot).isVerified else {
            throw TimingError.artifactReadFailed(
                path: source.path,
                message: "OpenSTA input snapshot failed integrity verification."
            )
        }
        return destination
    }

    private static func snapshotReference(
        _ reference: ArtifactReference,
        at url: URL
    ) throws -> ArtifactReference {
        ArtifactReference(
            locator: ArtifactLocator(
                location: try ArtifactLocation(fileURL: url),
                role: .input,
                kind: reference.locator.kind,
                format: reference.locator.format
            ),
            digest: reference.digest,
            byteCount: reference.byteCount,
            producer: reference.producer
        )
    }
}

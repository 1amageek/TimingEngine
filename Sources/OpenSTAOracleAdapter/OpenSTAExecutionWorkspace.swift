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
        let runRoot = canonicalRunsRoot
            .appending(path: runID, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let canonicalRunRoot = runRoot.resolvingSymlinksInPath()
        guard canonicalRunRoot.path.hasPrefix(canonicalRunsRoot.path + "/") else {
            throw TimingError.invalidInput("OpenSTA run workspace escapes the timing runs directory.")
        }
        let root = canonicalRunRoot
            .appending(path: "opensta", directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw TimingError.artifactWriteFailed(
                path: root.path,
                message: "The immutable OpenSTA run workspace already exists."
            )
        }
        let stagingRoot = canonicalRunRoot.appending(
            path: ".opensta-preparing-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        do {
            let stagingInputs = stagingRoot.appending(path: "inputs", directoryHint: .isDirectory)
            try fileManager.createDirectory(
                at: stagingInputs,
                withIntermediateDirectories: false
            )

            let stagingExecutableURL = stagingInputs.appending(path: "opensta")
            try fileManager.copyItem(at: executable.url, to: stagingExecutableURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: stagingExecutableURL.path
            )
            try OpenSTAExecutableValidator().revalidate(
                OpenSTAExecutableValidator.ValidatedExecutable(
                    url: stagingExecutableURL,
                    digest: executable.digest
                )
            )

            let designName = "design.\(design.locator.format.rawValue)"
            _ = try snapshot(
                design,
                named: designName,
                in: stagingInputs,
                relativeTo: canonicalWorkspaceRoot
            )
            _ = try snapshot(
                library,
                named: "library.lib",
                in: stagingInputs,
                relativeTo: canonicalWorkspaceRoot
            )
            _ = try snapshot(
                constraints,
                named: "constraints.sdc",
                in: stagingInputs,
                relativeTo: canonicalWorkspaceRoot
            )
            _ = try snapshot(
                pdk,
                named: "pdk.json",
                in: stagingInputs,
                relativeTo: canonicalWorkspaceRoot
            )
            if let parasitics {
                _ = try snapshot(
                    parasitics,
                    named: "parasitics.spef",
                    in: stagingInputs,
                    relativeTo: canonicalWorkspaceRoot
                )
            }

            try fileManager.moveItem(at: stagingRoot, to: root)
            let inputs = root.appending(path: "inputs", directoryHint: .isDirectory)
            let executableURL = inputs.appending(path: "opensta")
            let executableSnapshot = OpenSTAExecutableValidator.ValidatedExecutable(
                url: executableURL,
                digest: executable.digest
            )
            try OpenSTAExecutableValidator().revalidate(executableSnapshot)

            let designURL = inputs.appending(path: designName)
            let libraryURL = inputs.appending(path: "library.lib")
            let constraintsURL = inputs.appending(path: "constraints.sdc")
            let pdkURL = inputs.appending(path: "pdk.json")
            var references = [
                try snapshotReference(design, at: designURL),
                try snapshotReference(library, at: libraryURL),
                try snapshotReference(constraints, at: constraintsURL),
                try snapshotReference(pdk, at: pdkURL),
            ]
            let spefURL: URL?
            if let parasitics {
                let url = inputs.appending(path: "parasitics.spef")
                references.append(try snapshotReference(parasitics, at: url))
                spefURL = url
            } else {
                spefURL = nil
            }
            guard references.allSatisfy({
                LocalArtifactVerifier().verify($0).isVerified
            }) else {
                throw TimingError.artifactReadFailed(
                    path: root.path,
                    message: "Committed OpenSTA snapshots failed integrity verification."
                )
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
        } catch {
            if fileManager.fileExists(atPath: stagingRoot.path) {
                do {
                    try fileManager.removeItem(at: stagingRoot)
                } catch let cleanupError {
                    throw TimingError.artifactWriteFailed(
                        path: stagingRoot.path,
                        message: "\(error.localizedDescription); staging cleanup failed: \(cleanupError.localizedDescription)"
                    )
                }
            } else if fileManager.fileExists(atPath: root.path) {
                do {
                    try fileManager.removeItem(at: root)
                } catch let cleanupError {
                    throw TimingError.artifactWriteFailed(
                        path: root.path,
                        message: "\(error.localizedDescription); committed workspace cleanup failed: \(cleanupError.localizedDescription)"
                    )
                }
            }
            throw error
        }
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

import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import Foundation

public extension TimingArtifactReading {
    func read(_ artifact: TimingArtifactBinding, resources: any LibertySourceResourceAccounting)
        async throws -> TimingArtifactRead {
        throw TimingTransformError.unsupportedCapability("Reader has no controlled artifact intake")
    }
}

public extension FileSystemTimingArtifactReader {
    func read(_ artifact: TimingArtifactBinding, resources: any LibertySourceResourceAccounting)
        async throws -> TimingArtifactRead {
        try resources.check()
        guard artifact.digest.algorithm == .sha256 else {
            throw TimingTransformError.unsupportedCapability("Controlled discovery requires SHA-256 content identity")
        }
        let diagnostics = try TimingControlledDiagnostics(resources: resources, retaining: artifact)
        let local = try artifact.requireLocalAvailability()
        let pathBytes = try TimingDiagnosticTextCapacity.description(literal: "local:/", ints: 0, doubles: 0,
            booleans: 0, additionalUTF8: UInt64(local.rootID.rawValue.utf8.count))
        var relativeBytes = UInt64(local.relativePath.segments.count - 1)
        for segment in local.relativePath.segments {
            try resources.check(); try resources.chargeWork(UInt64(segment.utf8.count)); try resources.check()
            let sum = relativeBytes.addingReportingOverflow(UInt64(segment.utf8.count))
            guard !sum.overflow else { throw LibertySourceError.arithmeticOverflow }
            relativeBytes = sum.partialValue
        }
        let totalPath = pathBytes.addingReportingOverflow(relativeBytes)
        guard !totalPath.overflow else { throw LibertySourceError.arithmeticOverflow }
        func pathFailure(_ construct: () -> TimingError) throws -> TimingControlledTransformFailure {
            // materializationDescription constructs the joined relative path
            // before interpolation. Both payloads coexist during construction.
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: relativeBytes)
            try resources.check(); try resources.chargeWork(relativeBytes); try resources.check()
            let result = try diagnostics.sourceFailure(utf8ByteCount: totalPath.partialValue, construct)
            withExtendedLifetime(scratch) {}
            return result
        }
        let rootURL: URL
        switch local.rootID.rawValue {
        case TimingArtifactBinding.workspaceRootIdentifier:
            guard let workspaceRoot else {
                throw try pathFailure {
                    TimingError.artifactReadFailed(path: artifact.materializationDescription,
                        message: "A workspace-root availability requires an exact workspace root.")
                }
            }
            rootURL = workspaceRoot
        case TimingArtifactBinding.localFileSystemRootIdentifier:
            guard allowControlledLocalFileSystemRoot else {
                throw TimingTransformError.unsupportedCapability("Controlled file-system-root access requires an explicit reader grant")
            }
            rootURL = URL(filePath: "/", directoryHint: .isDirectory)
        default:
            throw try pathFailure {
                TimingError.artifactReadFailed(path: artifact.materializationDescription,
                    message: "The local artifact root is not registered for this reader.")
            }
        }
        let control = try TimingArtifactSourceControl(resources: resources)
        let rootDescriptor = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: UInt64(MemoryLayout<Int32>.stride))
        defer { withExtendedLifetime(rootDescriptor) {} }
        try resources.check()
        let access = try ArtifactRootCapability(rootID: local.rootID, directoryURL: rootURL,
            digester: SHA256ContentDigester())
        let result: TimingArtifactRead
        do {
            let source = try await access.discover(.init(rootID: local.rootID,
                relativePath: local.relativePath, descriptor: artifact.descriptor, budget: readBudget),
                control: control)
            guard source.reference == artifact.reference else {
                throw try pathFailure {
                    TimingError.artifactDigestMismatch(path: artifact.materializationDescription)
                }
            }
            result = try source.withAccountedUnsafeBytes { bytes in
                try resources.check()
                let payload = try resources.reserveStorage(kind: .liveOwnedBytes,
                    byteCount: UInt64(bytes.count))
                try resources.check()
                let metadata = try resources.reserveStorage(kind: .liveOwnedBytes,
                    byteCount: TimingArtifactRead.metadataBytes())
                try resources.check()
                try resources.chargeWork(UInt64(bytes.count))
                try resources.check()
                let data = Data(bytes)
                try resources.check()
                return TimingArtifactRead(data: data, reference: source.reference,
                    payload: payload, metadata: metadata)
            }
        } catch let failure {
            let primary = control.preservingCause(failure)
            do { _ = try await access.close().wait() }
            catch let secondary {
                throw TimingTransformError.cleanupFailed(primary: primary, secondary: secondary)
            }
            throw primary
        }
        do { _ = try await access.close().wait() }
        catch { throw error }
        try resources.check()
        return result
    }
}

public extension InMemoryTimingArtifactReader {
    func read(_ artifact: TimingArtifactBinding, resources: any LibertySourceResourceAccounting)
        async throws -> TimingArtifactRead {
        try resources.check()
        let diagnostics = try TimingControlledDiagnostics(resources: resources, retaining: artifact)
        func pathFailure(_ construct: () -> TimingError) throws -> TimingControlledTransformFailure {
            let outputBytes: UInt64
            let temporaryBytes: UInt64
            switch artifact.availability {
            case .local(_, let rootID, let path):
                var relativeBytes = UInt64(path.segments.count - 1)
                for segment in path.segments {
                    let count = UInt64(segment.utf8.count)
                    try resources.chargeWork(count); try resources.check()
                    let next = relativeBytes.addingReportingOverflow(count)
                    guard !next.overflow else { throw LibertySourceError.arithmeticOverflow }
                    relativeBytes = next.partialValue
                }
                outputBytes = try TimingDiagnosticTextCapacity.description(literal: "local:/",
                    ints: 0, doubles: 0, booleans: 0,
                    additionalUTF8: UInt64(rootID.rawValue.utf8.count))
                let total = outputBytes.addingReportingOverflow(relativeBytes)
                guard !total.overflow else { throw LibertySourceError.arithmeticOverflow }
                temporaryBytes = relativeBytes
                let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: temporaryBytes)
                defer { withExtendedLifetime(scratch) {} }
                try resources.check(); try resources.chargeWork(temporaryBytes); try resources.check()
                return try diagnostics.sourceFailure(utf8ByteCount: total.partialValue, construct)
            case .service:
                let cost = try artifact.controlledServiceDescriptionCost()
                outputBytes = cost.output
                temporaryBytes = cost.temporary
            }
            // Decimal rendering and the final service display coexist.
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: temporaryBytes)
            defer { withExtendedLifetime(scratch) {} }
            try resources.check(); try resources.chargeWork(temporaryBytes); try resources.check()
            return try diagnostics.sourceFailure(utf8ByteCount: outputBytes, construct)
        }
        let reference = artifact.reference
        guard let data = artifacts[reference.id] else {
            throw try pathFailure {
                TimingError.artifactReadFailed(path: artifact.controlledMaterializationDescription,
                    message: "No in-memory artifact was registered for the exact content identity.")
            }
        }
        guard UInt64(data.count) == reference.byteCount else {
            guard let expected = Int64(exactly: reference.byteCount),
                  let actual = Int64(exactly: data.count) else {
                throw diagnostics.failure(TimingError.invalidInput(
                    "Controlled in-memory artifact byte counts must fit Int64."))
            }
            throw try pathFailure {
                TimingError.artifactSizeMismatch(path: artifact.controlledMaterializationDescription,
                    expected: expected, actual: actual)
            }
        }
        // Existing input storage belongs to the reader/caller. This invocation
        // retains one exact Data payload and its anchor without rematerializing it.
        let payload = try resources.reserveStorage(kind: .liveOwnedBytes,
            byteCount: artifact.byteCount)
        try resources.check()
        let metadata = try resources.reserveStorage(kind: .liveOwnedBytes,
            byteCount: TimingArtifactRead.metadataBytes())
        try resources.check()
        try resources.chargeWork(artifact.byteCount)
        try resources.check()
        let digester = SHA256ContentDigester()
        let copyCost = try digester.foundationDataCopyCost(byteCount: artifact.byteCount)
        let hashCost = try SHA256ContentDigester.managedCost(byteCount: artifact.byteCount)
        let temporary = copyCost.temporaryByteCount.addingReportingOverflow(hashCost.temporaryByteCount)
        let work = copyCost.workUnits.addingReportingOverflow(hashCost.workUnits)
        guard !temporary.overflow, !work.overflow else { throw LibertySourceError.arithmeticOverflow }
        let matches: Bool
        do {
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: temporary.partialValue)
            try resources.check()
            let digestOutput = try resources.reserveStorage(kind: .liveOwnedBytes,
                byteCount: hashCost.retainedByteCount)
            defer { withExtendedLifetime((scratch, digestOutput)) {} }
            try resources.check()
            try resources.chargeWork(work.partialValue)
            try resources.check()
            let actual = try digester.digest(data: data, using: reference.digest.algorithm)
            try resources.check()
            matches = actual == reference.digest
            // The deferred owners cover digest headers/output through comparison.
        }
        guard matches else {
            throw try pathFailure {
                TimingError.artifactDigestMismatch(path: artifact.controlledMaterializationDescription)
            }
        }
        try resources.check()
        return TimingArtifactRead(data: data, reference: artifact.reference,
            payload: payload, metadata: metadata)
    }
}

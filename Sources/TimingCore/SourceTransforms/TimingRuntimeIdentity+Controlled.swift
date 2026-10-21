import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import Foundation

public extension TimingRuntimeIdentity {
    static func currentExecutableDigest(resources original: any LibertySourceResourceAccounting,
        readBudget: ArtifactAccessBudget) async throws -> TimingTransformValue<String> {
        let resources = try TimingCheckedSourceResources(original)
        let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        // URL infrastructure owns its representation. Percent-encoded URL text
        // bounds the decoded last-component payload before its publication.
        let pathLease = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: UInt64(executable.absoluteString.utf8.count))
        try resources.chargeWork(UInt64(executable.absoluteString.utf8.count))
        try resources.check()
        let name = executable.lastPathComponent
        let segments = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: LibertySourceCapacity.byteCount(of: String.self, capacity: 1))
        try resources.chargeWork(UInt64(name.utf8.count)); try resources.check()
        let path = try ArtifactRelativePath(segments: [name])
        let rootID = try ArtifactRootID(rawValue: "timing-runtime-executable")
        let control = try TimingArtifactSourceControl(resources: resources)
        let descriptor = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: UInt64(MemoryLayout<Int32>.stride))
        try resources.check()
        let access = try ArtifactRootCapability(rootID: rootID,
            directoryURL: executable.deletingLastPathComponent(), digester: SHA256ContentDigester())
        let result: TimingTransformValue<String>
        do {
            let source = try await access.discover(.init(rootID: rootID, relativePath: path,
                descriptor: ArtifactDescriptor(role: .input, kind: .other, format: .raw), budget: readBudget), control: control)
            let digest = source.reference.digest.hexadecimalValue
            let payload = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(digest.utf8.count))
            try resources.chargeWork(UInt64(digest.utf8.count)); try resources.check()
            let text = String(decoding: digest.utf8, as: UTF8.self)
            try resources.check()
            result = try TimingTransformValue(value: text, retaining: payload, resources: resources)
        } catch {
            let primary = control.preservingCause(error)
            do { _ = try await access.close().wait() }
            catch { throw TimingTransformError.cleanupFailed(primary: primary, secondary: error) }
            throw primary
        }
        do { _ = try await access.close().wait() }
        catch { throw error }
        try resources.check()
        withExtendedLifetime((pathLease, segments, descriptor)) {}
        return result
    }

    static func environmentFingerprint(toolchain: String,
        resources original: any LibertySourceResourceAccounting) throws -> TimingTransformValue<ExecutionEnvironmentFingerprint> {
        let resources = try TimingCheckedSourceResources(original)
        #if os(macOS)
        let name = "macOS"
        #elseif os(Linux)
        let name = "Linux"
        #elseif os(Windows)
        let name = "Windows"
        #else
        let name = "unknown-platform"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #elseif arch(arm)
        let architecture = "arm"
        #elseif arch(i386)
        let architecture = "i386"
        #else
        let architecture = "unknown-architecture"
        #endif
        let numeric = try TimingDiagnosticTextCapacity.description(literal: "-..", ints: 3, doubles: 0,
            booleans: 0, additionalUTF8: UInt64(name.utf8.count))
        let platformLease = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: numeric)
        try resources.chargeWork(numeric); try resources.check()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let platform = "\(name)-\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let environment = "LANG=C\nLC_ALL=C\nTZ=UTC\n"
        let bytesLease = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(environment.utf8.count))
        try resources.chargeWork(UInt64(environment.utf8.count)); try resources.check()
        let data = Data(environment.utf8)
        let digester = SHA256ContentDigester()
        let hash = try SHA256ContentDigester.managedCost(byteCount: UInt64(data.count))
        let copy = try digester.foundationDataCopyCost(byteCount: UInt64(data.count))
        let temporary = hash.temporaryByteCount.addingReportingOverflow(copy.temporaryByteCount)
        let work = hash.workUnits.addingReportingOverflow(copy.workUnits)
        guard !temporary.overflow, !work.overflow else { throw LibertySourceError.arithmeticOverflow }
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: temporary.partialValue)
        let digestLease = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: hash.retainedByteCount)
        try resources.chargeWork(work.partialValue); try resources.check()
        try resources.chargeWork(UInt64(platform.utf8.count))
        try resources.chargeWork(UInt64(architecture.utf8.count))
        try resources.chargeWork(UInt64(toolchain.utf8.count)); try resources.check()
        let fingerprint = try ExecutionEnvironmentFingerprint(platform: platform, architecture: architecture, toolchain: toolchain,
            environmentDigest: digester.digest(data: data, using: .sha256))
        try resources.check()
        let result = try TimingTransformValue(value: fingerprint, retaining: (platformLease, digestLease), resources: resources)
        withExtendedLifetime((bytesLease, scratch)) {}
        return result
    }
}

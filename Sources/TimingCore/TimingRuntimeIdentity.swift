import CircuiteFoundation
import Foundation

public enum TimingRuntimeIdentity {
    private static let executableDigest: String? = {
        let executableURL = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        do {
            return try SHA256ContentDigester().digest(
                fileAt: executableURL,
                using: .sha256
            ).hexadecimalValue
        } catch {
            return nil
        }
    }()

    public static func currentExecutableDigest() throws -> String {
        guard let executableDigest else {
            throw TimingError.invariantViolation(
                "The executable carrying the native timing implementation could not be attested."
            )
        }
        return executableDigest
    }

    public static func environmentFingerprint(
        toolchain: String
    ) throws -> ExecutionEnvironmentFingerprint {
        try ExecutionEnvironmentFingerprint(
            platform: platform,
            architecture: architecture,
            toolchain: toolchain,
            environmentDigest: SHA256ContentDigester().digest(
                data: Data("LANG=C\nLC_ALL=C\nTZ=UTC\n".utf8),
                using: .sha256
            )
        )
    }

    private static var platform: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let name = "macOS"
        #elseif os(Linux)
        let name = "Linux"
        #elseif os(Windows)
        let name = "Windows"
        #else
        let name = "unknown-platform"
        #endif
        return "\(name)-\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #elseif arch(arm)
        "arm"
        #elseif arch(i386)
        "i386"
        #else
        "unknown-architecture"
        #endif
    }
}

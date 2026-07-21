import CircuiteFoundation
import Foundation
import SignoffToolSupport

struct OpenSTAExecutableValidator: Sendable {
    struct ValidatedExecutable: Sendable, Hashable {
        let url: URL
        let digest: ContentDigest
    }

    private let digester: SHA256ContentDigester

    init(digester: SHA256ContentDigester = SHA256ContentDigester()) {
        self.digester = digester
    }

    func validate(
        path: String,
        expectedVersion: String,
        timeoutSeconds: Double
    ) async throws -> ValidatedExecutable {
        let executableURL = URL(filePath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let executablePath = executableURL.path(percentEncoded: false)
        guard executableURL.isFileURL, !executablePath.isEmpty else {
            throw OpenSTAExecutableValidationError.invalidPath(path)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: executablePath)
        } catch {
            throw OpenSTAExecutableValidationError.invalidPath(executablePath)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw OpenSTAExecutableValidationError.notRegularFile(executablePath)
        }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw OpenSTAExecutableValidationError.notExecutable(executablePath)
        }

        let initialDigest = try digest(executableURL)
        let versionResult: TimedProcessResult
        do {
            versionResult = try await TimedProcessRunner(
                timeoutSeconds: min(timeoutSeconds, 30)
            ).run(executableURL: executableURL, arguments: ["-version"])
        } catch {
            throw OpenSTAExecutableValidationError.versionProbeFailed(
                path: executablePath,
                message: error.localizedDescription
            )
        }
        guard versionResult.exitCode == 0 else {
            throw OpenSTAExecutableValidationError.versionProbeExited(
                path: executablePath,
                exitCode: versionResult.exitCode
            )
        }

        let reportedVersion = [versionResult.standardOutput, versionResult.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsVersion(expectedVersion, in: reportedVersion) else {
            throw OpenSTAExecutableValidationError.versionMismatch(
                expected: expectedVersion,
                observed: String(reportedVersion.prefix(256))
            )
        }

        let digestAfterVersionProbe = try digest(executableURL)
        guard digestAfterVersionProbe == initialDigest else {
            throw OpenSTAExecutableValidationError.executableChanged(
                expected: initialDigest.hexadecimalValue,
                actual: digestAfterVersionProbe.hexadecimalValue
            )
        }
        return ValidatedExecutable(url: executableURL, digest: initialDigest)
    }

    func revalidate(
        _ executable: ValidatedExecutable
    ) throws {
        let executablePath = executable.url.path(percentEncoded: false)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: executablePath)
        } catch {
            throw OpenSTAExecutableValidationError.executableChanged(
                expected: executable.digest.hexadecimalValue,
                actual: "unavailable"
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw OpenSTAExecutableValidationError.executableChanged(
                expected: executable.digest.hexadecimalValue,
                actual: "invalid-file-metadata"
            )
        }
        let actual: ContentDigest
        do {
            actual = try digest(executable.url)
        } catch {
            throw OpenSTAExecutableValidationError.executableChanged(
                expected: executable.digest.hexadecimalValue,
                actual: "unreadable"
            )
        }
        guard actual == executable.digest else {
            throw OpenSTAExecutableValidationError.executableChanged(
                expected: executable.digest.hexadecimalValue,
                actual: actual.hexadecimalValue
            )
        }
    }

    private func digest(
        _ executableURL: URL
    ) throws -> ContentDigest {
        do {
            return try digester.digest(fileAt: executableURL, using: .sha256)
        } catch {
            throw OpenSTAExecutableValidationError.digestFailed(
                path: executableURL.path(percentEncoded: false),
                message: error.localizedDescription
            )
        }
    }

    private func containsVersion(_ expectedVersion: String, in output: String) -> Bool {
        let tokenCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".-_+")
        )
        return output
            .components(separatedBy: tokenCharacters.inverted)
            .contains(expectedVersion)
    }
}

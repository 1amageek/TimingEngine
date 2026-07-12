import Foundation

public enum TimingError: Error, LocalizedError, Sendable, Hashable, Codable {
    case invalidInput(String)
    case unsupportedSemantic(format: String, semantic: String)
    case parseFailure(format: String, line: Int, message: String)
    case artifactReadFailed(path: String, message: String)
    case artifactWriteFailed(path: String, message: String)
    case artifactDigestMismatch(path: String)
    case artifactSizeMismatch(path: String, expected: Int64, actual: Int64)
    case missingArtifact(role: String)
    case invariantViolation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .unsupportedSemantic(let format, let semantic):
            return "Unsupported \(format) semantic: \(semantic)."
        case .parseFailure(let format, let line, let message):
            return "Failed to parse \(format) at line \(line): \(message)"
        case .artifactReadFailed(let path, let message):
            return "Failed to read timing artifact at \(path): \(message)"
        case .artifactWriteFailed(let path, let message):
            return "Failed to write timing artifact at \(path): \(message)"
        case .artifactDigestMismatch(let path):
            return "Timing artifact digest mismatch at \(path)."
        case .artifactSizeMismatch(let path, let expected, let actual):
            return "Timing artifact size mismatch at \(path): expected \(expected), got \(actual)."
        case .missingArtifact(let role):
            return "Required timing artifact is missing: \(role)."
        case .invariantViolation(let message):
            return "Timing invariant violation: \(message)"
        }
    }
}

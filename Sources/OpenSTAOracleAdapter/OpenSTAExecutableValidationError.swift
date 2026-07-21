import Foundation

enum OpenSTAExecutableValidationError: Error, LocalizedError, Sendable, Equatable {
    case invalidPath(String)
    case notRegularFile(String)
    case notExecutable(String)
    case digestFailed(path: String, message: String)
    case versionProbeFailed(path: String, message: String)
    case versionProbeExited(path: String, exitCode: Int32)
    case versionMismatch(expected: String, observed: String)
    case executableChanged(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "OpenSTA executable path is invalid: \(path)."
        case .notRegularFile(let path):
            return "OpenSTA executable is not a regular file: \(path)."
        case .notExecutable(let path):
            return "OpenSTA executable is not executable: \(path)."
        case .digestFailed(let path, let message):
            return "Failed to hash OpenSTA executable at \(path): \(message)"
        case .versionProbeFailed(let path, let message):
            return "Failed to query OpenSTA version at \(path): \(message)"
        case .versionProbeExited(let path, let exitCode):
            return "OpenSTA version query exited with status \(exitCode): \(path)."
        case .versionMismatch(let expected, let observed):
            return "OpenSTA version mismatch: expected \(expected), observed \(observed)."
        case .executableChanged(let expected, let actual):
            return "OpenSTA executable changed during execution: expected \(expected), observed \(actual)."
        }
    }

    var diagnosticCode: String {
        switch self {
        case .invalidPath:
            return "OPENSTA_EXECUTABLE_PATH_INVALID"
        case .notRegularFile:
            return "OPENSTA_EXECUTABLE_NOT_REGULAR"
        case .notExecutable:
            return "OPENSTA_EXECUTABLE_NOT_EXECUTABLE"
        case .digestFailed:
            return "OPENSTA_EXECUTABLE_DIGEST_FAILED"
        case .versionProbeFailed:
            return "OPENSTA_VERSION_PROBE_FAILED"
        case .versionProbeExited:
            return "OPENSTA_VERSION_PROBE_NONZERO_EXIT"
        case .versionMismatch:
            return "OPENSTA_VERSION_MISMATCH"
        case .executableChanged:
            return "OPENSTA_EXECUTABLE_MUTATED"
        }
    }

    var suggestedActions: [String] {
        switch self {
        case .versionMismatch:
            return ["verify_qualified_opensta_version", "refresh_tool_qualification"]
        case .executableChanged:
            return ["restore_qualified_opensta_binary", "investigate_executable_mutation"]
        default:
            return ["inspect_opensta_executable", "verify_tool_qualification"]
        }
    }
}

import CircuiteFoundation
import Foundation

public enum TimingFoundationBoundaryError: Error, Sendable, Equatable, LocalizedError {
    case workspaceRootRequired(String)
    case invalidArtifactLocation(String, reason: String)
    case byteCountOutOfRange(String)
    case missingArtifactDigest(String)
    case invalidArtifactDigest(String)
    case unsupportedDigestAlgorithm(String)
    case unsupportedArtifactFormat(String)
    case invalidDiagnosticCode(String)
    case invalidArtifactIdentity(String)
    case resultIdentityMismatch(expected: String, actual: String)
    case unsupportedSchemaVersion(expected: SchemaVersion, actual: SchemaVersion)

    public var errorDescription: String? {
        switch self {
        case .workspaceRootRequired(let path):
            "A workspace root is required for the Foundation artifact: \(path)"
        case .invalidArtifactLocation(let path, let reason):
            "The Foundation artifact location is invalid for '\(path)': \(reason)"
        case .byteCountOutOfRange(let path):
            "The Foundation artifact byte count cannot be represented by the legacy boundary: \(path)"
        case .missingArtifactDigest(let path):
            "The legacy artifact has no digest and cannot be promoted to Foundation evidence: \(path)"
        case .invalidArtifactDigest(let path):
            "The legacy artifact digest is invalid and cannot be promoted to Foundation evidence: \(path)"
        case .unsupportedDigestAlgorithm(let algorithm):
            "The timing compatibility boundary supports SHA-256 artifacts only: \(algorithm)"
        case .unsupportedArtifactFormat(let format):
            "The artifact format cannot be represented at the timing Foundation boundary: \(format)"
        case .invalidDiagnosticCode(let code):
            "The diagnostic code cannot be represented at the timing Foundation boundary: \(code)"
        case .invalidArtifactIdentity(let identity):
            "The artifact identity cannot be represented at the timing Foundation boundary: \(identity)"
        case .resultIdentityMismatch(let expected, let actual):
            "The engine result run ID does not match the request: expected \(expected), received \(actual)"
        case .unsupportedSchemaVersion(let expected, let actual):
            "The Foundation request schema version is unsupported: expected \(expected), received \(actual)"
        }
    }
}

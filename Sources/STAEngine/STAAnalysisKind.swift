import Foundation

public enum STAAnalysisKind: String, Sendable, Hashable, Codable {
    case setup
    case hold
    case recovery
    case removal
    case pulseWidth
}

import Foundation

public enum TimingParasiticReductionError: Error, LocalizedError, Sendable, Hashable, Codable {
    case invalidInventory(String)
    case missingCapacitanceRecords(net: String)
    case ambiguousMirroredListings(first: TimingParasitics.Endpoint, second: TimingParasitics.Endpoint)
    case numericOverflow(net: String)

    public var errorDescription: String? {
        switch self {
        case .invalidInventory(let message): return "Invalid parasitic source inventory: \(message)"
        case .missingCapacitanceRecords(let net): return "Network '\(net)' declares positive capacitance but has no CAP records to reduce."
        case .ambiguousMirroredListings(let first, let second):
            return "Contradictory mirrored capacitance listings between '\(first.name)' and '\(second.name)'."
        case .numericOverflow(let net): return "Parasitic reduction aggregate overflow for '\(net)'."
        }
    }
}

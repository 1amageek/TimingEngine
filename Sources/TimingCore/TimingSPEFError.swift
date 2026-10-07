import Foundation

public enum TimingSPEFError: Error, LocalizedError, Sendable, Hashable, Codable {
    case unknownNameMapReference(line: Int, reference: String)
    case duplicateNameMapReference(line: Int, reference: String)
    case duplicateNetwork(line: Int, net: String)
    case conflictingConnection(line: Int, endpoint: String, firstNet: String, secondNet: String)
    case ambiguousEndpoint(line: Int, endpoint: String, nets: [String])
    case unknownEndpoint(line: Int, endpoint: String)
    case invalidCapacitanceOwner(line: Int, endpoint: String, declaringNet: String)

    public var errorDescription: String? {
        switch self {
        case .unknownNameMapReference(let line, let reference):
            return "SPEF line \(line): unknown name-map reference '\(reference)'."
        case .duplicateNameMapReference(let line, let reference):
            return "SPEF line \(line): duplicate name-map reference '\(reference)'."
        case .duplicateNetwork(let line, let net):
            return "SPEF line \(line): duplicate network '\(net)'."
        case .conflictingConnection(let line, let endpoint, let firstNet, let secondNet):
            return "SPEF line \(line): connection '\(endpoint)' belongs to both '\(firstNet)' and '\(secondNet)'."
        case .ambiguousEndpoint(let line, let endpoint, let nets):
            return "SPEF line \(line): endpoint '\(endpoint)' has ambiguous owning nets: \(nets.joined(separator: ", "))."
        case .unknownEndpoint(let line, let endpoint):
            return "SPEF line \(line): scoped endpoint '\(endpoint)' has no declared owner."
        case .invalidCapacitanceOwner(let line, let endpoint, let declaringNet):
            return "SPEF line \(line): capacitance endpoint '\(endpoint)' is not owned by declaring network '\(declaringNet)'."
        }
    }
}

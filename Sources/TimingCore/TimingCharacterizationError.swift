import Foundation

public enum TimingCharacterizationError: Error, LocalizedError, Sendable, Equatable {
    case missingSourceFact(String)
    case unsupportedSemantic(String)
    case ambiguousSource(String)
    case invalidValue(String)
    case inputOutOfRange(axis: String, value: Double, minimum: Double, maximum: Double)

    public var errorDescription: String? {
        switch self {
        case .missingSourceFact(let fact): return "Missing Liberty characterization source fact: \(fact)."
        case .unsupportedSemantic(let semantic): return "Unsupported Liberty characterization semantic: \(semantic)."
        case .ambiguousSource(let fact): return "Ambiguous Liberty characterization source: \(fact)."
        case .invalidValue(let fact): return "Invalid Liberty characterization value: \(fact)."
        case .inputOutOfRange(let axis, let value, let minimum, let maximum):
            return "Characterization \(axis) \(value) is outside [\(minimum), \(maximum)]."
        }
    }
}

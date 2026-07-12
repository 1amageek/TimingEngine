import Foundation

public struct TimingPin: Sendable, Hashable, Codable {
    public enum Direction: String, Sendable, Hashable, Codable {
        case input
        case output
        case bidirectional = "inout"
        case internalPin = "internal"
        case unknown
    }

    public var name: String
    public var direction: Direction
    public var capacitance: Double
    public var maxCapacitance: Double?
    public var function: String?
    public var isClock: Bool
    public var isData: Bool

    public init(
        name: String,
        direction: Direction,
        capacitance: Double = 0,
        maxCapacitance: Double? = nil,
        function: String? = nil,
        isClock: Bool = false,
        isData: Bool = false
    ) {
        self.name = name
        self.direction = direction
        self.capacitance = capacitance
        self.maxCapacitance = maxCapacitance
        self.function = function
        self.isClock = isClock
        self.isData = isData
    }
}

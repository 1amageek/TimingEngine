import Foundation

public struct TimingOperatingCondition: Sendable, Hashable, Codable {
    public var name: String
    public var process: Double?
    public var voltage: Double?
    public var temperature: Double?

    public init(
        name: String,
        process: Double? = nil,
        voltage: Double? = nil,
        temperature: Double? = nil
    ) {
        self.name = name
        self.process = process
        self.voltage = voltage
        self.temperature = temperature
    }
}

public struct TimingLibrary: Sendable, Hashable, Codable {
    public var name: String
    public var timeUnitScale: Double
    public var capacitanceUnitScale: Double
    public var powerUnitScale: Double
    public var cells: [String: TimingCell]
    public var operatingConditions: [String: TimingOperatingCondition]

    public init(
        name: String,
        timeUnitScale: Double = 1,
        capacitanceUnitScale: Double = 1,
        powerUnitScale: Double = 1,
        cells: [String: TimingCell] = [:],
        operatingConditions: [String: TimingOperatingCondition] = [:]
    ) {
        self.name = name
        self.timeUnitScale = timeUnitScale
        self.capacitanceUnitScale = capacitanceUnitScale
        self.powerUnitScale = powerUnitScale
        self.cells = cells
        self.operatingConditions = operatingConditions
    }

    public func cell(named name: String) throws -> TimingCell {
        guard let cell = cells[name] else {
            throw TimingError.invalidInput("Timing library has no cell model for '\(name)'.")
        }
        return cell
    }

    public func merged(with other: TimingLibrary) -> TimingLibrary {
        var merged = self
        merged.cells.merge(other.cells) { _, newer in newer }
        merged.operatingConditions.merge(other.operatingConditions) { _, newer in newer }
        return merged
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case timeUnitScale
        case capacitanceUnitScale
        case powerUnitScale
        case cells
        case operatingConditions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            timeUnitScale: try container.decodeIfPresent(Double.self, forKey: .timeUnitScale) ?? 1,
            capacitanceUnitScale: try container.decodeIfPresent(Double.self, forKey: .capacitanceUnitScale) ?? 1,
            powerUnitScale: try container.decodeIfPresent(Double.self, forKey: .powerUnitScale) ?? 1,
            cells: try container.decodeIfPresent([String: TimingCell].self, forKey: .cells) ?? [:],
            operatingConditions: try container.decodeIfPresent([String: TimingOperatingCondition].self, forKey: .operatingConditions) ?? [:]
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(timeUnitScale, forKey: .timeUnitScale)
        try container.encode(capacitanceUnitScale, forKey: .capacitanceUnitScale)
        try container.encode(powerUnitScale, forKey: .powerUnitScale)
        try container.encode(cells, forKey: .cells)
        try container.encode(operatingConditions, forKey: .operatingConditions)
    }
}

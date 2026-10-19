import Foundation

public struct TimingCell: Sendable, Hashable, Codable {
    public var name: String
    public var area: Double?
    public var pins: [TimingPin]
    public var arcs: [TimingArc]
    public var sequentialModel: TimingSequentialModel?
    public var powerModel: TimingPowerModel?
    public var pulseWidthConstraints: [TimingPulseWidthConstraint]
    public var directionalControlArcs: [TimingDirectionalControlArc]

    public init(
        name: String,
        area: Double? = nil,
        pins: [TimingPin] = [],
        arcs: [TimingArc] = [],
        sequentialModel: TimingSequentialModel? = nil,
        powerModel: TimingPowerModel? = nil,
        pulseWidthConstraints: [TimingPulseWidthConstraint] = [],
        directionalControlArcs: [TimingDirectionalControlArc] = []
    ) {
        self.name = name
        self.area = area
        self.pins = pins
        self.arcs = arcs
        self.sequentialModel = sequentialModel
        self.powerModel = powerModel
        self.pulseWidthConstraints = pulseWidthConstraints
        self.directionalControlArcs = directionalControlArcs
    }

    public var inputPins: [TimingPin] {
        pins.filter { $0.direction == .input || $0.direction == .bidirectional }
    }

    public var outputPins: [TimingPin] {
        pins.filter { $0.direction == .output || $0.direction == .bidirectional }
    }

    public func pin(named name: String) -> TimingPin? {
        pins.first { $0.name == name }
    }

    public func arcs(from pin: String, to output: String) -> [TimingArc] {
        arcs.filter { $0.fromPin == pin && $0.toPin == output && !$0.isConstraint }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case area
        case pins
        case arcs
        case sequentialModel
        case powerModel
        case pulseWidthConstraints
        case directionalControlArcs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            area: try container.decodeIfPresent(Double.self, forKey: .area),
            pins: try container.decode([TimingPin].self, forKey: .pins),
            arcs: try container.decode([TimingArc].self, forKey: .arcs),
            sequentialModel: try container.decodeIfPresent(TimingSequentialModel.self, forKey: .sequentialModel),
            powerModel: try container.decodeIfPresent(TimingPowerModel.self, forKey: .powerModel),
            pulseWidthConstraints: try container.decodeIfPresent([TimingPulseWidthConstraint].self, forKey: .pulseWidthConstraints) ?? [],
            directionalControlArcs: try container.decodeIfPresent([TimingDirectionalControlArc].self, forKey: .directionalControlArcs) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(area, forKey: .area)
        try container.encode(pins, forKey: .pins)
        try container.encode(arcs, forKey: .arcs)
        try container.encodeIfPresent(sequentialModel, forKey: .sequentialModel)
        try container.encodeIfPresent(powerModel, forKey: .powerModel)
        if !pulseWidthConstraints.isEmpty { try container.encode(pulseWidthConstraints, forKey: .pulseWidthConstraints) }
        if !directionalControlArcs.isEmpty { try container.encode(directionalControlArcs, forKey: .directionalControlArcs) }
    }
}

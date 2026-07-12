import Foundation

public struct TimingConstraintSet: Sendable, Hashable, Codable {
    public struct Clock: Sendable, Hashable, Codable {
        public var name: String
        public var source: String
        public var period: Double
        public var waveform: [Double]
        public var uncertainty: Double

        public init(
            name: String,
            source: String,
            period: Double,
            waveform: [Double] = [],
            uncertainty: Double = 0
        ) {
            self.name = name
            self.source = source
            self.period = period
            self.waveform = waveform
            self.uncertainty = uncertainty
        }
    }

    public struct GeneratedClock: Sendable, Hashable, Codable {
        public var name: String
        public var source: String
        public var masterClock: String
        public var divideBy: Int
        public var multiplyBy: Int

        public init(
            name: String,
            source: String,
            masterClock: String,
            divideBy: Int = 1,
            multiplyBy: Int = 1
        ) {
            self.name = name
            self.source = source
            self.masterClock = masterClock
            self.divideBy = divideBy
            self.multiplyBy = multiplyBy
        }
    }

    public struct PortDelay: Sendable, Hashable, Codable {
        public var port: String
        public var clock: String?
        public var rise: Double
        public var fall: Double
        public var isMax: Bool

        public init(port: String, clock: String? = nil, rise: Double, fall: Double, isMax: Bool) {
            self.port = port
            self.clock = clock
            self.rise = rise
            self.fall = fall
            self.isMax = isMax
        }
    }

    public struct PathException: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            case falsePath
            case multicycle
            case maxDelay
            case minDelay
        }

        public var kind: Kind
        public var from: [String]
        public var to: [String]
        public var through: [String]
        public var cycles: Int?
        public var delay: Double?

        public init(
            kind: Kind,
            from: [String] = [],
            to: [String] = [],
            through: [String] = [],
            cycles: Int? = nil,
            delay: Double? = nil
        ) {
            self.kind = kind
            self.from = from
            self.to = to
            self.through = through
            self.cycles = cycles
            self.delay = delay
        }
    }

    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var modeID: String
    public var clocks: [Clock]
    public var generatedClocks: [GeneratedClock]
    public var inputDelays: [PortDelay]
    public var outputDelays: [PortDelay]
    public var exceptions: [PathException]
    public var pathGroups: [TimingPathGroup]
    public var clockGroups: [TimingClockGroup]
    public var defaultInputSlew: Double
    public var defaultOutputLoad: Double

    public init(
        modeID: String = "default",
        clocks: [Clock] = [],
        generatedClocks: [GeneratedClock] = [],
        inputDelays: [PortDelay] = [],
        outputDelays: [PortDelay] = [],
        exceptions: [PathException] = [],
        pathGroups: [TimingPathGroup] = [],
        clockGroups: [TimingClockGroup] = [],
        defaultInputSlew: Double = 1e-10,
        defaultOutputLoad: Double = 0
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.modeID = modeID
        self.clocks = clocks
        self.generatedClocks = generatedClocks
        self.inputDelays = inputDelays
        self.outputDelays = outputDelays
        self.exceptions = exceptions
        self.pathGroups = pathGroups
        self.clockGroups = clockGroups
        self.defaultInputSlew = defaultInputSlew
        self.defaultOutputLoad = defaultOutputLoad
    }

    public func clock(named name: String) -> Clock? {
        clocks.first { $0.name == name } ?? generatedClocks.compactMap { generated in
            guard generated.name == name,
                  let master = clocks.first(where: { $0.name == generated.masterClock }) else { return nil }
            let period = master.period * Double(generated.divideBy) / Double(generated.multiplyBy)
            return Clock(name: generated.name, source: generated.source, period: period, uncertainty: master.uncertainty)
        }.first
    }

    public func clock(for source: String) -> Clock? {
        clocks.first { $0.source == source } ?? generatedClocks.first { $0.source == source }.flatMap { clock(named: $0.name) }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case modeID
        case clocks
        case generatedClocks
        case inputDelays
        case outputDelays
        case exceptions
        case pathGroups
        case clockGroups
        case defaultInputSlew
        case defaultOutputLoad
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            modeID: try container.decodeIfPresent(String.self, forKey: .modeID) ?? "default",
            clocks: try container.decodeIfPresent([Clock].self, forKey: .clocks) ?? [],
            generatedClocks: try container.decodeIfPresent([GeneratedClock].self, forKey: .generatedClocks) ?? [],
            inputDelays: try container.decodeIfPresent([PortDelay].self, forKey: .inputDelays) ?? [],
            outputDelays: try container.decodeIfPresent([PortDelay].self, forKey: .outputDelays) ?? [],
            exceptions: try container.decodeIfPresent([PathException].self, forKey: .exceptions) ?? [],
            pathGroups: try container.decodeIfPresent([TimingPathGroup].self, forKey: .pathGroups) ?? [],
            clockGroups: try container.decodeIfPresent([TimingClockGroup].self, forKey: .clockGroups) ?? [],
            defaultInputSlew: try container.decodeIfPresent(Double.self, forKey: .defaultInputSlew) ?? 1e-10,
            defaultOutputLoad: try container.decodeIfPresent(Double.self, forKey: .defaultOutputLoad) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(modeID, forKey: .modeID)
        try container.encode(clocks, forKey: .clocks)
        try container.encode(generatedClocks, forKey: .generatedClocks)
        try container.encode(inputDelays, forKey: .inputDelays)
        try container.encode(outputDelays, forKey: .outputDelays)
        try container.encode(exceptions, forKey: .exceptions)
        try container.encode(pathGroups, forKey: .pathGroups)
        try container.encode(clockGroups, forKey: .clockGroups)
        try container.encode(defaultInputSlew, forKey: .defaultInputSlew)
        try container.encode(defaultOutputLoad, forKey: .defaultOutputLoad)
    }
}

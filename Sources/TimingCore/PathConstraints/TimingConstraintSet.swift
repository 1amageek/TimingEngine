import Foundation

public struct TimingConstraintSet: Sendable, Hashable, Codable {
    /// An explicit declaration of the complete currently admitted primary-input profile.
    public enum InputTransition: Sendable, Hashable, Codable {
        case allInputsBothEdges(slew: Double)
    }

    public struct Clock: Sendable, Hashable, Codable {
        public var name: String
        public var source: String
        public var period: Double
        public var waveform: [Double]
        public var uncertainty: Double
        public var sourceRiseTransition: Double?
        public var sourceFallTransition: Double?
        public var isPropagated: Bool

        public init(
            name: String,
            source: String,
            period: Double,
            waveform: [Double] = [],
            uncertainty: Double = 0,
            sourceRiseTransition: Double? = nil,
            sourceFallTransition: Double? = nil,
            isPropagated: Bool = false
        ) {
            self.name = name
            self.source = source
            self.period = period
            self.waveform = waveform
            self.uncertainty = uncertainty
            self.sourceRiseTransition = sourceRiseTransition; self.sourceFallTransition = sourceFallTransition
            self.isPropagated = isPropagated
        }

        public var hasValidPropagatedSource: Bool {
            guard waveform.count == 2, period.isFinite, period > 0,
                  waveform.allSatisfy(\.isFinite), waveform[0] >= 0, waveform[0] < waveform[1], waveform[1] < period,
                  let rise = sourceRiseTransition, let fall = sourceFallTransition else { return false }
            return rise.isFinite && rise > 0 && fall.isFinite && fall > 0
        }
        private enum CodingKeys: String, CodingKey {
            case name, source, period, waveform, uncertainty, sourceRiseTransition, sourceFallTransition, isPropagated
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decode(String.self, forKey: .name), source: try c.decode(String.self, forKey: .source),
                period: try c.decode(Double.self, forKey: .period), waveform: try c.decode([Double].self, forKey: .waveform),
                uncertainty: try c.decode(Double.self, forKey: .uncertainty),
                sourceRiseTransition: try c.decodeIfPresent(Double.self, forKey: .sourceRiseTransition),
                sourceFallTransition: try c.decodeIfPresent(Double.self, forKey: .sourceFallTransition),
                isPropagated: try c.decodeIfPresent(Bool.self, forKey: .isPropagated) ?? false)
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

        public enum CheckScope: String, Sendable, Hashable, Codable { case both, setup, hold }
        public enum ClockReference: String, Sendable, Hashable, Codable { case start, end }
        public var kind: Kind
        public var from: [TimingPathObject]
        public var to: [TimingPathObject]
        public var through: [[TimingPathObject]]
        public var cycles: Int?
        public var delay: Double?
        public var scope: CheckScope
        public var clockReference: ClockReference

        public init(kind: Kind, from: [TimingPathObject] = [], to: [TimingPathObject] = [],
                    through: [[TimingPathObject]] = [], cycles: Int? = nil, delay: Double? = nil,
                    scope: CheckScope = .both, clockReference: ClockReference? = nil) {
            self.kind = kind; self.from = from; self.to = to; self.through = through
            self.cycles = cycles; self.delay = delay; self.scope = scope
            self.clockReference = clockReference ?? (scope == .hold ? .start : .end)
        }
    }

    public struct CaseAnalysis: Sendable, Hashable, Codable {
        public enum Value: Int, Sendable, Hashable, Codable {
            case zero = 0
            case one = 1
        }

        public var target: String
        public var value: Value

        public init(target: String, value: Value) {
            self.target = target
            self.value = value
        }
    }

    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var modeID: String
    public var clocks: [Clock]
    public var generatedClocks: [GeneratedClock]
    public var inputDelays: [PortDelay]
    public var outputDelays: [PortDelay]
    public var caseAnalyses: [CaseAnalysis]
    public var exceptions: [PathException]
    public var pathGroups: [TimingPathGroup]
    public var clockGroups: [TimingClockGroup]
    public var defaultInputSlew: Double
    public var defaultOutputLoad: Double
    public var inputTransition: InputTransition?

    public init(
        modeID: String = "default",
        clocks: [Clock] = [],
        generatedClocks: [GeneratedClock] = [],
        inputDelays: [PortDelay] = [],
        outputDelays: [PortDelay] = [],
        caseAnalyses: [CaseAnalysis] = [],
        exceptions: [PathException] = [],
        pathGroups: [TimingPathGroup] = [],
        clockGroups: [TimingClockGroup] = [],
        defaultInputSlew: Double = 1e-10,
        defaultOutputLoad: Double = 0,
        inputTransition: InputTransition? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.modeID = modeID
        self.clocks = clocks
        self.generatedClocks = generatedClocks
        self.inputDelays = inputDelays
        self.outputDelays = outputDelays
        self.caseAnalyses = caseAnalyses
        self.exceptions = exceptions
        self.pathGroups = pathGroups
        self.clockGroups = clockGroups
        self.defaultInputSlew = defaultInputSlew
        self.defaultOutputLoad = defaultOutputLoad
        self.inputTransition = inputTransition
    }

    public func clock(named name: String) -> Clock? {
        if let clock = clocks.first(where: { $0.name == name }) {
            return clock
        }

        guard let generated = generatedClocks.first(where: { $0.name == name }),
              let master = clocks.first(where: { $0.name == generated.masterClock }) else {
            return nil
        }

        let period = master.period * Double(generated.divideBy) / Double(generated.multiplyBy)
        return Clock(name: generated.name, source: generated.source, period: period, uncertainty: master.uncertainty)
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
        case caseAnalyses
        case exceptions
        case pathGroups
        case clockGroups
        case defaultInputSlew
        case defaultOutputLoad
        case inputTransition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        if version == 1 {
            var old = try container.nestedUnkeyedContainer(forKey: .exceptions)
            guard old.isAtEnd else {
                throw DecodingError.dataCorruptedError(forKey: .exceptions, in: container,
                    debugDescription: "Legacy string exceptions require explicit source reparsing")
            }
        } else if version != Self.currentSchemaVersion {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                debugDescription: "Unsupported timing constraint schema")
        }
        self.init(
            modeID: try container.decode(String.self, forKey: .modeID),
            clocks: try container.decode([Clock].self, forKey: .clocks),
            generatedClocks: try container.decode([GeneratedClock].self, forKey: .generatedClocks),
            inputDelays: try container.decode([PortDelay].self, forKey: .inputDelays),
            outputDelays: try container.decode([PortDelay].self, forKey: .outputDelays),
            caseAnalyses: try container.decodeIfPresent(
                [CaseAnalysis].self,
                forKey: .caseAnalyses
            ) ?? [],
            exceptions: try container.decode([PathException].self, forKey: .exceptions),
            pathGroups: try container.decode([TimingPathGroup].self, forKey: .pathGroups),
            clockGroups: try container.decode([TimingClockGroup].self, forKey: .clockGroups),
            defaultInputSlew: try container.decode(Double.self, forKey: .defaultInputSlew),
            defaultOutputLoad: try container.decode(Double.self, forKey: .defaultOutputLoad),
            inputTransition: try container.decodeIfPresent(InputTransition.self, forKey: .inputTransition)
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
        try container.encode(caseAnalyses, forKey: .caseAnalyses)
        try container.encode(exceptions, forKey: .exceptions)
        try container.encode(pathGroups, forKey: .pathGroups)
        try container.encode(clockGroups, forKey: .clockGroups)
        try container.encode(defaultInputSlew, forKey: .defaultInputSlew)
        try container.encode(defaultOutputLoad, forKey: .defaultOutputLoad)
        try container.encodeIfPresent(inputTransition, forKey: .inputTransition)
    }
}

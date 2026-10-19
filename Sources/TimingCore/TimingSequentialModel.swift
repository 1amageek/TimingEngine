import Foundation

public struct TimingSequentialModel: Sendable, Hashable, Codable {
    public struct LegacyPins: Sendable, Hashable, Codable {
        public let dataPin: String
        public let clockPin: String
        public let outputPin: String
        public init(dataPin: String, clockPin: String, outputPin: String) {
            self.dataPin = dataPin; self.clockPin = clockPin; self.outputPin = outputPin
        }
    }
    public enum Definition: Sendable, Hashable, Codable {
        case legacy(LegacyPins)
        case source(TimingSequentialSource)
    }
    public var definition: Definition
    public var dataPin: String? {
        switch definition {
        case .legacy(let pins): return pins.dataPin
        case .source(let source): return source.singleInput(for: .data, allowingInversion: false)
        }
    }
    public var clockPin: String? {
        switch definition {
        case .legacy(let pins): return pins.clockPin
        case .source(let source):
            guard source.declarations.count == 1, source.declarations[0].kind == .flipFlop else { return nil }
            return source.singleInput(for: .control, allowingInversion: true)
        }
    }
    public var outputPin: String? {
        switch definition {
        case .legacy(let pins): return pins.outputPin
        case .source(let source): return source.singleOutput
        }
    }
    public var simpleEdgeTriggeredPins: LegacyPins? {
        switch definition {
        case .legacy(let pins): return pins
        case .source(let source): return source.simpleEdgeTriggeredPins
        }
    }
    public var clockToQ: TimingArc?
    public var setupTime: Double
    public var holdTime: Double
    public var recoveryTime: Double?
    public var removalTime: Double?
    /// Compatibility summary of explicit scalar laws only; use cell pulseWidthConstraints for source evidence.
    public var minPulseWidth: Double?
    /// Nil denotes a caller-declared legacy scalar model; parsed sources always retain a check set.
    public var timingChecks: [TimingCheckArc]?
    public var clockToQEdge: TimingEdge?
    public var clockEdge: TimingEdge?

    public init(
        dataPin: String,
        clockPin: String,
        outputPin: String,
        clockToQ: TimingArc? = nil,
        setupTime: Double = 0,
        holdTime: Double = 0,
        recoveryTime: Double? = nil,
        removalTime: Double? = nil,
        minPulseWidth: Double? = nil,
        timingChecks: [TimingCheckArc]? = nil,
        clockEdge: TimingEdge? = nil,
        clockToQEdge: TimingEdge? = nil
    ) {
        self.definition = .legacy(.init(dataPin: dataPin, clockPin: clockPin, outputPin: outputPin))
        self.clockToQ = clockToQ
        self.setupTime = setupTime
        self.holdTime = holdTime
        self.recoveryTime = recoveryTime
        self.removalTime = removalTime
        self.minPulseWidth = minPulseWidth
        self.timingChecks = timingChecks
        self.clockEdge = clockEdge
        self.clockToQEdge = clockToQEdge
    }

    internal init(source: TimingSequentialSource, numerical: TimingSequentialModel?) {
        definition = .source(source)
        clockToQ = numerical?.clockToQ
        setupTime = numerical?.setupTime ?? 0
        holdTime = numerical?.holdTime ?? 0
        recoveryTime = numerical?.recoveryTime
        removalTime = numerical?.removalTime
        minPulseWidth = numerical?.minPulseWidth
        timingChecks = numerical?.timingChecks ?? []
        clockEdge = numerical?.clockEdge
        clockToQEdge = numerical?.clockToQEdge
    }
}

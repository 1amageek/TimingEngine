import Foundation

public struct TimingSequentialModel: Sendable, Hashable, Codable {
    public var dataPin: String
    public var clockPin: String
    public var outputPin: String
    public var clockToQ: TimingArc?
    public var setupTime: Double
    public var holdTime: Double
    public var recoveryTime: Double?
    public var removalTime: Double?
    public var minPulseWidth: Double?

    public init(
        dataPin: String,
        clockPin: String,
        outputPin: String,
        clockToQ: TimingArc? = nil,
        setupTime: Double = 0,
        holdTime: Double = 0,
        recoveryTime: Double? = nil,
        removalTime: Double? = nil,
        minPulseWidth: Double? = nil
    ) {
        self.dataPin = dataPin
        self.clockPin = clockPin
        self.outputPin = outputPin
        self.clockToQ = clockToQ
        self.setupTime = setupTime
        self.holdTime = holdTime
        self.recoveryTime = recoveryTime
        self.removalTime = removalTime
        self.minPulseWidth = minPulseWidth
    }
}

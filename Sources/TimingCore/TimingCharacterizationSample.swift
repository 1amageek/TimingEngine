public struct TimingCharacterizationSample: Sendable, Equatable {
    public let delay: Double
    public let outputSlew: Double

    init(delay: Double, outputSlew: Double) {
        self.delay = delay
        self.outputSlew = outputSlew
    }
}

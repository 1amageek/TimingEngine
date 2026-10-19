/// The two actual selected-edge observations from one checked source propagation query.
public struct TimingSourcePropagationSample: Sendable, Hashable, Codable {
    public let delay: TimingSourceEvaluationSample
    public let outputSlew: TimingSourceEvaluationSample

    init(delay: TimingSourceEvaluationSample, outputSlew: TimingSourceEvaluationSample) {
        self.delay = delay; self.outputSlew = outputSlew
    }
}

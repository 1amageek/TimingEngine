/// Independently enclosed delay and output transition for one selected source edge.
public struct TimingSourcePropagationRangeSample: Sendable, Hashable, Codable {
    public let delay: TimingSourceEvaluationRangeSample
    public let outputSlew: TimingSourceEvaluationRangeSample

    init(delay: TimingSourceEvaluationRangeSample, outputSlew: TimingSourceEvaluationRangeSample) {
        self.delay = delay; self.outputSlew = outputSlew
    }
}

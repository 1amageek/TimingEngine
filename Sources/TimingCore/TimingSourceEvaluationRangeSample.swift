/// Independent numerical bounds from one exact retained source table.
/// Decoding this receipt grants no source authority; the original owner must validate it.
public struct TimingSourceEvaluationRangeSample: Sendable, Hashable, Codable {
    public let source: LibertyTimingSourceIdentity
    public let table: LibertyTimingTableIdentity
    public let quantity: TimingSourceEvaluationSample.Quantity
    public let firstInput: ClosedRange<Double>
    public let secondInput: ClosedRange<Double>
    public let firstDomain: ClosedRange<Double>
    public let secondDomain: ClosedRange<Double>
    public let result: ClosedRange<Double>

    init(source: LibertyTimingSourceIdentity, table: LibertyTimingTableIdentity,
         quantity: TimingSourceEvaluationSample.Quantity, firstInput: ClosedRange<Double>,
         secondInput: ClosedRange<Double>, firstDomain: ClosedRange<Double>,
         secondDomain: ClosedRange<Double>, result: ClosedRange<Double>) {
        self.source = source; self.table = table; self.quantity = quantity
        self.firstInput = firstInput; self.secondInput = secondInput
        self.firstDomain = firstDomain; self.secondDomain = secondDomain; self.result = result
    }
}

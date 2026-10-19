/// A retained numerical observation; decoding it does not grant source qualification.
public struct TimingSourceEvaluationSample: Sendable, Hashable, Codable {
    public enum Quantity: String, Sendable, Hashable, Codable {
        case cellDelay, outputSlew, constraint
    }

    public let source: LibertyTimingSourceIdentity
    public let table: LibertyTimingTableIdentity
    public let quantity: Quantity
    public let firstInput: Double
    public let secondInput: Double
    public let firstMinimum: Double
    public let firstMaximum: Double
    public let secondMinimum: Double
    public let secondMaximum: Double
    public let result: Double

    // Only an admitted evaluator constructs observations. Revalidation uses that same source owner.
    init(source: LibertyTimingSourceIdentity, table: LibertyTimingTableIdentity, quantity: Quantity,
         firstInput: Double, secondInput: Double, firstMinimum: Double, firstMaximum: Double,
         secondMinimum: Double, secondMaximum: Double, result: Double) {
        self.source = source; self.table = table; self.quantity = quantity
        self.firstInput = firstInput; self.secondInput = secondInput
        self.firstMinimum = firstMinimum; self.firstMaximum = firstMaximum
        self.secondMinimum = secondMinimum; self.secondMaximum = secondMaximum; self.result = result
    }
}

/// Source-bound pulse limit evaluation. Scalar laws have no fictitious slew axis or query.
public struct TimingPulseWidthSample: Sendable, Hashable, Codable {
    public let source: LibertyTimingSourceIdentity
    public let table: LibertyTimingTableIdentity
    public let openingEdge: TimingEdge
    public let inputSlew: Double?
    public let minimumSlew: Double?
    public let maximumSlew: Double?
    public let result: Double

    internal init(source: LibertyTimingSourceIdentity, table: LibertyTimingTableIdentity,
                  openingEdge: TimingEdge, inputSlew: Double?, minimumSlew: Double?, maximumSlew: Double?, result: Double) {
        self.source = source; self.table = table; self.openingEdge = openingEdge
        self.inputSlew = inputSlew; self.minimumSlew = minimumSlew; self.maximumSlew = maximumSlew
        self.result = result
    }
}

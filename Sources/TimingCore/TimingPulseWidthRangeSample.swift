/// Exact source pulse law evaluated over a slew interval; scalar laws have no axis.
public struct TimingPulseWidthRangeSample: Sendable, Hashable, Codable {
    public let source: LibertyTimingSourceIdentity
    public let table: LibertyTimingTableIdentity
    public let openingEdge: TimingEdge
    public let inputSlew: ClosedRange<Double>?
    public let slewDomain: ClosedRange<Double>?
    public let result: ClosedRange<Double>

    init(source: LibertyTimingSourceIdentity, table: LibertyTimingTableIdentity, openingEdge: TimingEdge,
         inputSlew: ClosedRange<Double>?, slewDomain: ClosedRange<Double>?, result: ClosedRange<Double>) {
        self.source = source; self.table = table; self.openingEdge = openingEdge
        self.inputSlew = inputSlew; self.slewDomain = slewDomain; self.result = result
    }
}

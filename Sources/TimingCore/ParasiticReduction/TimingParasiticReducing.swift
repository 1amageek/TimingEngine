public protocol TimingParasiticReducing: Sendable {
    func reduce(_ source: TimingParasitics) throws -> TimingLumpedParasitics
    func reduce(_ source: TimingParasitics, resources: any LibertySourceResourceAccounting)
        throws -> TimingTransformValue<TimingLumpedParasitics>
}

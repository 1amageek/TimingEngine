public protocol TimingParasiticReducing: Sendable {
    func reduce(_ source: TimingParasitics) throws -> TimingLumpedParasitics
}

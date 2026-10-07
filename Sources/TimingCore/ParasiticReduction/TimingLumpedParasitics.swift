public struct TimingLumpedParasitics: Sendable, Hashable {
    public struct Coupling: Sendable, Hashable {
        public let firstNet: String
        public let secondNet: String
        public let capacitance: Double
        public let declaredVictims: [String]
        public let sourceIDs: [TimingParasitics.SourceID]
    }

    public let effectiveLoads: [String: Double]
    public let groundCapacitances: [String: Double]
    public let couplings: [Coupling]
    public let evidence: TimingParasiticReductionEvidence
}

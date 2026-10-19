import TimingCore

/// Bounded failure-only facts from the unchanged residual unique-transition inequality.
internal struct NativeSTAConservativeTransitionDiagnostic: Sendable, Equatable {
    struct Contribution: Sendable, Equatable {
        let source: TimingParasitics.Endpoint
        let isAggressor: Bool
        let slopeUpperBound: Double
        let directMagnitudeUpperBound: Double
        let hL1UpperBound: Double
        let hErrorUpperBound: Double
        let derivativeUpperBound: Double
    }

    let voltageErrorUpperBound: Double
    let querySlope: ClosedRange<Double>
    let ownHistorySlopeUpperBound: Double
    let deltaLowerBound: Double
    let ownTailUpperBound: Double
    let ownHErrorUpperBound: Double
    let ownTermUpperBound: Double
    let aggressorDerivativeUpperBound: Double
    let minimumDerivative: ClosedRange<Double>
    let maximumDerivativeUpperBound: Double
    let horizon: Double
    let segmentCount: Int
    let contributions: [Contribution]
}

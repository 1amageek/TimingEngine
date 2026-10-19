package enum TimingNumericBoundsError: Error, Sendable, Equatable {
    case invalidInterval
    case nonfiniteResult
    case zeroDivisor
}

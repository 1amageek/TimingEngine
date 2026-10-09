import TimingCore

public enum STAPreparationError: Error, Sendable {
    case input(TimingError)
    case liberty(LibertySourceError)
    case configurationMismatch
    case unsupportedRandomSeed
    case unsupportedBoundedTransformAccounting
    case characterization(String)
    case capacity(String)
    case cancelled
    case underlying(any Error)
}

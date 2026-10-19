public enum STADistributedCoverageError: Error, Sendable, Equatable {
    case invalidRequiredScope
    case incompleteExecution
    case candidateMismatch
    case configurationMismatch
    case cornerMismatch
    case missingModeledNet(net: String, mode: String, corner: String)
    case missingClockObservation(clock: String, mode: String, corner: String)
    case missingWireObservation(net: String, mode: String, corner: String)
}

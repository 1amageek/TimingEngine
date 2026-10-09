public enum STAExecutionError: Error, Sendable {
    case cancelled
    case underlying(any Error)
}

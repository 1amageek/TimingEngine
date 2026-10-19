public enum STADesignBindingError: Error, Sendable {
    case mismatch(String)
    case capacity
    case resource(any Error)
}

public enum STAPathAnalysisError: Error, Sendable, Equatable {
    case capacity(resource: String, limit: UInt64)
}

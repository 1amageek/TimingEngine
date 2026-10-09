public protocol STAPreparedExecuting: Sendable {
    func execute(_ prepared: PreparedSTAExecution)
        async throws(STAExecutionError) -> STAExecutionResult
}

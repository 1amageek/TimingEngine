public protocol STAExecutionPreparing: Sendable {
    func prepare(_ request: STARequest, resources: STAExecutionResources)
        async throws(STAPreparationError) -> PreparedSTAExecution
}

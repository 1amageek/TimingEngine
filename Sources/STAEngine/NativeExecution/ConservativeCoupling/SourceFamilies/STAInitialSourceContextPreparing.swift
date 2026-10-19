/// Projects retained initial source families without computing a wire response.
public protocol STAInitialSourceContextPreparing: Sendable {
    func initialSourceContexts(_ prepared: PreparedSTAExecution)
        throws(STAExecutionError) -> [STAConservativeSourceContext]
    func validateInitialSourceContext(_ record: STAConservativeSourceContextRecord,
        against prepared: PreparedSTAExecution) throws(STAExecutionError) -> STAConservativeSourceContext
}

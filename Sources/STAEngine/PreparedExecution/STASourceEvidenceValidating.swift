/// Validates saved strict observations against independently reconstructed exact inputs.
public protocol STASourceEvidenceValidating: Sendable {
    func validateSourceEvidence(_ result: STAExecutionResult, against prepared: PreparedSTAExecution)
        async throws(STAExecutionError)
}

/// Host-owned required net/corner scope is checked against exact candidate-bound observations.
public protocol STADistributedCoverageValidating: Sendable {
    func validate(_ result: STAExecutionResult, request: STARequest,
                  requiredNetNames: [String], requiredCornerIDs: [String]) throws(STADistributedCoverageError)
}

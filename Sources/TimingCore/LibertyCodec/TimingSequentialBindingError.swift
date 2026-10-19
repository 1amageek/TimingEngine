/// An unavailable source model remains stateful and cannot become a combinational fallback.
public enum TimingSequentialBindingError: Error, Sendable, Hashable, Codable {
    case multipleDeclarations
    case invalidStateVariables
    case ambiguousSymbol(String)
    case unresolvedSymbol(String)
    case missingFunction(TimingSequentialFunctionBinding.Role)
    case unsupportedFunction(TimingSequentialFunctionBinding.Role, LibertyBooleanFunctionIssue)
    case legacyModel
}

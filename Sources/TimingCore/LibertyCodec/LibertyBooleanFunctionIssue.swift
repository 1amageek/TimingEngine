public enum LibertyBooleanFunctionIssue: String, Error, Sendable, Hashable, Codable {
    case malformedExpression
    case unsupportedIdentifier
    case unsupportedSyntax
}

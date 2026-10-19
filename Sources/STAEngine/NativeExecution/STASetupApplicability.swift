/// Source-owned applicability of the setup optimization objective after prepared validation.
public enum STASetupApplicability: String, Sendable, Hashable, Codable {
    case measured
    case sourceNotApplicable
    case unknown
}

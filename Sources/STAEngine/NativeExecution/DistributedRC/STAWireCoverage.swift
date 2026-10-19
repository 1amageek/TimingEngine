/// Exact modeled scope; an ideal clock declaration does not establish routed clock delay.
public struct STAWireCoverage: Sendable, Hashable, Codable {
    public enum Model: String, Sendable, Hashable, Codable {
        case conservativeCoupledRC
        case distributedRC
        case propagatedClock
        case idealClock
        case uncovered
        case staticNoTransition
    }
    public let modeID: String
    public let cornerID: String
    public let net: String
    public let model: Model
}

/// Exact candidate-derived receiver inventory bound into the effective configuration.
public struct STAClockReceiverScope: Sendable, Hashable, Codable {
    public let modeID: String
    public let cornerID: String
    public let rootClock: String
    public let receiver: String
}

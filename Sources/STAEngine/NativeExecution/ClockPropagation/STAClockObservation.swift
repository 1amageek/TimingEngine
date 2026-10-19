import TimingCore

/// Actual characterized receiving-clock edge and its root/physical timing relationship.
public struct STAClockObservation: Sendable, Hashable, Codable {
    public struct Segment: Sendable, Hashable, Codable {
        public let physicalIdentity: String
        public let lateDelay: Double
        public let earlyDelay: Double
    }
    public let modeID: String
    public let cornerID: String
    public let receiver: String
    public let rootClock: String
    public let edge: TimingEdge
    public let rootEdge: TimingEdge
    public let rootPhase: Double
    public let period: Double
    public let lateArrival: Double
    public let earlyArrival: Double
    public let lateSlew: Double
    public let earlySlew: Double
    public let segments: [Segment]
}

import TimingCore

/// Observed grid agreement under the explicit prescribed linear source model.
public struct STADistributedRCObservation: Sendable, Hashable, Codable {
    public enum Method: String, Sendable, Hashable, Codable { case backwardEuler, idealConstraint }
    public let modeID: String
    public let cornerID: String
    public let net: String
    public let source: String
    public let sink: String
    public let edge: TimingEdge
    public let sourceSlew: Double
    public let sourceThreshold: Double
    public let sinkThreshold: Double
    public let lowerThreshold: Double
    public let upperThreshold: Double
    public let wireDelay: Double
    public let sinkSlew: Double
    public let observedCrossingDifference: Double?
    public let finalMaximumTimeStep: Double?
    public let cumulativeSteps: UInt64
    public var period: Double? = nil
    public var observedCycleDifference: Double? = nil
    public var method: Method = .backwardEuler
    public var modelIdentity: String {
        if method == .idealConstraint { return period == nil ? "prescribed-linear-ramp.ideal-constraint.v1" : "prescribed-periodic-linear-ramp.ideal-constraint.v1" }
        return period == nil ? "prescribed-linear-ramp.backward-euler.v1" : "prescribed-periodic-linear-ramp.backward-euler.v1"
    }
    private enum CodingKeys: String, CodingKey {
        case modeID, cornerID, net, source, sink, edge, sourceSlew, sourceThreshold, sinkThreshold, lowerThreshold, upperThreshold
        case wireDelay, sinkSlew, observedCrossingDifference, finalMaximumTimeStep, cumulativeSteps, period, observedCycleDifference, method
    }
}

extension STADistributedRCObservation {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(modeID: try c.decode(String.self, forKey: .modeID), cornerID: try c.decode(String.self, forKey: .cornerID),
            net: try c.decode(String.self, forKey: .net), source: try c.decode(String.self, forKey: .source), sink: try c.decode(String.self, forKey: .sink),
            edge: try c.decode(TimingEdge.self, forKey: .edge), sourceSlew: try c.decode(Double.self, forKey: .sourceSlew),
            sourceThreshold: try c.decode(Double.self, forKey: .sourceThreshold), sinkThreshold: try c.decode(Double.self, forKey: .sinkThreshold),
            lowerThreshold: try c.decode(Double.self, forKey: .lowerThreshold), upperThreshold: try c.decode(Double.self, forKey: .upperThreshold),
            wireDelay: try c.decode(Double.self, forKey: .wireDelay), sinkSlew: try c.decode(Double.self, forKey: .sinkSlew),
            observedCrossingDifference: try c.decodeIfPresent(Double.self, forKey: .observedCrossingDifference),
            finalMaximumTimeStep: try c.decodeIfPresent(Double.self, forKey: .finalMaximumTimeStep),
            cumulativeSteps: try c.decode(UInt64.self, forKey: .cumulativeSteps), period: try c.decodeIfPresent(Double.self, forKey: .period),
            observedCycleDifference: try c.decodeIfPresent(Double.self, forKey: .observedCycleDifference),
            method: try c.decodeIfPresent(Method.self, forKey: .method) ?? .backwardEuler)
    }
}

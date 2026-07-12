import Foundation
import TimingCore

public struct SINetSummary: Sendable, Hashable, Codable {
    public var victimNet: String
    public var aggressorNet: String
    public var couplingCapacitance: Double
    public var noiseRatio: Double
    public var deltaDelay: Double

    public init(
        victimNet: String,
        aggressorNet: String,
        couplingCapacitance: Double,
        noiseRatio: Double,
        deltaDelay: Double
    ) {
        self.victimNet = victimNet
        self.aggressorNet = aggressorNet
        self.couplingCapacitance = couplingCapacitance
        self.noiseRatio = noiseRatio
        self.deltaDelay = deltaDelay
    }
}

public struct SIViolation: Sendable, Hashable, Codable {
    public var victimNet: String
    public var aggressorNet: String
    public var deltaDelay: Double
    public var noiseRatio: Double
    public var suggestedActions: [String]

    public init(
        victimNet: String,
        aggressorNet: String,
        deltaDelay: Double,
        noiseRatio: Double,
        suggestedActions: [String] = []
    ) {
        self.victimNet = victimNet
        self.aggressorNet = aggressorNet
        self.deltaDelay = deltaDelay
        self.noiseRatio = noiseRatio
        self.suggestedActions = suggestedActions
    }
}

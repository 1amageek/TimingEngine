import Foundation
import TimingCore

/// Caller-owned finite numerical settings for prescribed-ramp passive RC propagation.
public struct STADistributedRCOptions: Sendable, Hashable, Codable {
    public let maximumTimeStep: Double
    public let stopTime: Double
    public let crossingTolerance: Double
    public let maximumRefinements: Int
    public let maximumNodes: Int
    public let maximumSteps: UInt64

    public init(maximumTimeStep: Double, stopTime: Double, crossingTolerance: Double,
                maximumRefinements: Int, maximumNodes: Int, maximumSteps: UInt64) throws {
        guard [maximumTimeStep, stopTime, crossingTolerance].allSatisfy({ $0.isFinite && $0 > 0 }),
              maximumTimeStep <= stopTime, maximumRefinements > 0, maximumNodes > 0, maximumSteps > 0 else {
            throw TimingError.invalidInput("Distributed RC requires finite positive grid, horizon, tolerance and budgets")
        }
        self.maximumTimeStep = maximumTimeStep; self.stopTime = stopTime; self.crossingTolerance = crossingTolerance
        self.maximumRefinements = maximumRefinements; self.maximumNodes = maximumNodes; self.maximumSteps = maximumSteps
    }

    private enum CodingKeys: String, CodingKey {
        case maximumTimeStep, stopTime, crossingTolerance, maximumRefinements, maximumNodes, maximumSteps
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumTimeStep: c.decode(Double.self, forKey: .maximumTimeStep),
            stopTime: c.decode(Double.self, forKey: .stopTime), crossingTolerance: c.decode(Double.self, forKey: .crossingTolerance),
            maximumRefinements: c.decode(Int.self, forKey: .maximumRefinements),
            maximumNodes: c.decode(Int.self, forKey: .maximumNodes), maximumSteps: c.decode(UInt64.self, forKey: .maximumSteps))
    }
}

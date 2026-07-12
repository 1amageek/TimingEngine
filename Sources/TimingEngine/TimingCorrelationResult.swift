import Foundation

public struct TimingCorrelationResult: Sendable, Hashable, Codable {
    public var oracleID: String
    public var status: Status
    public var setupSlackDifference: Double?
    public var holdSlackDifference: Double?
    public var passed: Bool
    public var tolerance: Double
    public var diagnostics: [String]

    public enum Status: String, Sendable, Hashable, Codable {
        case passed
        case failed
        case blocked
    }

    public init(
        oracleID: String,
        status: Status,
        setupSlackDifference: Double? = nil,
        holdSlackDifference: Double? = nil,
        passed: Bool,
        tolerance: Double,
        diagnostics: [String] = []
    ) {
        self.oracleID = oracleID
        self.status = status
        self.setupSlackDifference = setupSlackDifference
        self.holdSlackDifference = holdSlackDifference
        self.passed = passed
        self.tolerance = tolerance
        self.diagnostics = diagnostics
    }
}

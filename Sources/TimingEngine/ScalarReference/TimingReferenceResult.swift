import Foundation

public struct TimingReferenceResult: Sendable, Hashable, Codable {
    public var oracleID: String
    public var worstSetupSlack: Double?
    public var worstHoldSlack: Double?

    public init(
        oracleID: String,
        worstSetupSlack: Double?,
        worstHoldSlack: Double?
    ) {
        self.oracleID = oracleID
        self.worstSetupSlack = worstSetupSlack
        self.worstHoldSlack = worstHoldSlack
    }
}

import Foundation

public struct TimingExternalOracleEvidence: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        case available
        case unavailable
        case notEvaluated
    }

    public var oracleID: String
    public var status: Status
    public var executablePath: String?
    public var version: String?
    public var details: String

    public init(
        oracleID: String,
        status: Status,
        executablePath: String? = nil,
        version: String? = nil,
        details: String
    ) {
        self.oracleID = oracleID
        self.status = status
        self.executablePath = executablePath
        self.version = version
        self.details = details
    }
}

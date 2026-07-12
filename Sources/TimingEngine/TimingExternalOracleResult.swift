import Foundation
import STAEngine

public struct TimingExternalOracleResult: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        case completed
        case blocked
        case failed
    }

    public var runID: String
    public var oracleID: String
    public var status: Status
    public var exitCode: Int32?
    public var stdout: String
    public var stderr: String
    public var payload: STAPayload?
    public var diagnostics: [String]

    public init(
        runID: String,
        oracleID: String,
        status: Status,
        exitCode: Int32? = nil,
        stdout: String = "",
        stderr: String = "",
        payload: STAPayload? = nil,
        diagnostics: [String] = []
    ) {
        self.runID = runID
        self.oracleID = oracleID
        self.status = status
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.payload = payload
        self.diagnostics = diagnostics
    }
}

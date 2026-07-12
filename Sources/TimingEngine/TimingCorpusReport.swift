import Foundation

public struct TimingCorpusReport: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var suiteID: String
    public var processID: String
    public var version: String
    public var isValid: Bool
    public var caseResults: [TimingCorpusCaseResult]
    public var limitations: [String]

    public init(
        suiteID: String,
        processID: String,
        version: String,
        isValid: Bool,
        caseResults: [TimingCorpusCaseResult],
        limitations: [String]
    ) {
        self.schemaVersion = 1
        self.suiteID = suiteID
        self.processID = processID
        self.version = version
        self.isValid = isValid
        self.caseResults = caseResults
        self.limitations = limitations
    }
}

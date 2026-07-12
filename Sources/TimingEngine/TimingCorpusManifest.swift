import Foundation

public struct TimingCorpusManifest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var suiteID: String
    public var processID: String
    public var version: String
    public var cases: [TimingCorpusCase]

    public init(
        suiteID: String,
        processID: String,
        version: String,
        cases: [TimingCorpusCase]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.suiteID = suiteID
        self.processID = processID
        self.version = version
        self.cases = cases
    }
}

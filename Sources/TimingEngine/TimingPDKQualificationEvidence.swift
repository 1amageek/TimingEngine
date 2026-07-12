import Foundation

public struct TimingPDKQualificationEvidence: Sendable, Hashable, Codable {
    public var processID: String
    public var version: String
    public var manifestDigest: String
    public var manifestIsValid: Bool
    public var cornerIDs: [String]
    public var assets: [TimingPDKAssetEvidence]
    public var findings: [String]
    public var isComplete: Bool

    public init(
        processID: String,
        version: String,
        manifestDigest: String,
        manifestIsValid: Bool,
        cornerIDs: [String],
        assets: [TimingPDKAssetEvidence],
        findings: [String],
        isComplete: Bool
    ) {
        self.processID = processID
        self.version = version
        self.manifestDigest = manifestDigest
        self.manifestIsValid = manifestIsValid
        self.cornerIDs = cornerIDs
        self.assets = assets
        self.findings = findings
        self.isComplete = isComplete
    }
}

import Foundation

public struct TimingPDKEvidence: Sendable, Hashable, Codable {
    public var processID: String
    public var version: String
    public var manifestDigest: String
    public var cornerIDs: [String]
    public var assets: [TimingPDKAssetEvidence]
    public var findings: [String]

    public init(
        processID: String,
        version: String,
        manifestDigest: String,
        cornerIDs: [String],
        assets: [TimingPDKAssetEvidence],
        findings: [String]
    ) {
        self.processID = processID
        self.version = version
        self.manifestDigest = manifestDigest
        self.cornerIDs = cornerIDs
        self.assets = assets
        self.findings = findings
    }

    public var isComplete: Bool {
        findings.isEmpty
            && assets.filter(\.required).allSatisfy(\.isVerified)
    }
}

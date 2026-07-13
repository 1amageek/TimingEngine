import CircuiteFoundation
import Foundation

/// Capability declaration for the canonical TimingEngine API.
public struct TimingEngineCapability: Sendable, Hashable, Codable {
    public let engineID: String
    public let contractVersion: Int
    public let supportedInputFormats: [ArtifactFormat]
    public let supportedOutputFormats: [ArtifactFormat]
    public let features: [String]
    public let limitations: [String]

    public init(
        engineID: String,
        contractVersion: Int,
        supportedInputFormats: [ArtifactFormat],
        supportedOutputFormats: [ArtifactFormat],
        features: [String] = [],
        limitations: [String] = []
    ) {
        self.engineID = engineID
        self.contractVersion = contractVersion
        self.supportedInputFormats = supportedInputFormats
        self.supportedOutputFormats = supportedOutputFormats
        self.features = features
        self.limitations = limitations
    }
}

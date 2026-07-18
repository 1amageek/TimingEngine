import CircuiteFoundation
import Foundation

/// Describes the inputs, outputs, and analysis coverage of a timing engine.
public struct TimingCapability: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let engineID: String
    public let supportedInputFormats: [ArtifactFormat]
    public let supportedOutputFormats: [ArtifactFormat]
    public let features: [String]
    public let limitations: [String]

    public init(
        engineID: String,
        supportedInputFormats: [ArtifactFormat],
        supportedOutputFormats: [ArtifactFormat],
        features: [String] = [],
        limitations: [String] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.engineID = engineID
        self.supportedInputFormats = supportedInputFormats
        self.supportedOutputFormats = supportedOutputFormats
        self.features = features
        self.limitations = limitations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case engineID
        case supportedInputFormats
        case supportedOutputFormats
        case features
        case limitations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported timing capability schema version \(schemaVersion)."
            )
        }
        self.schemaVersion = schemaVersion
        self.engineID = try container.decode(String.self, forKey: .engineID)
        self.supportedInputFormats = try container.decode([ArtifactFormat].self, forKey: .supportedInputFormats)
        self.supportedOutputFormats = try container.decode([ArtifactFormat].self, forKey: .supportedOutputFormats)
        self.features = try container.decode([String].self, forKey: .features)
        self.limitations = try container.decode([String].self, forKey: .limitations)
    }
}

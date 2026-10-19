import Foundation

public struct TimingExternalOracleRequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 3
    public static let defaultTimeoutSeconds = 300.0

    public var schemaVersion: Int
    public var runID: String
    public var oracleID: String
    public var executablePath: String
    public var arguments: [String]
    public var workingDirectory: String
    public var timeoutSeconds: Double
    public var maximumOutputByteCount: UInt64
    public var cleanupTimeoutSeconds: Double

    public init(
        runID: String,
        oracleID: String,
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String,
        timeoutSeconds: Double = Self.defaultTimeoutSeconds,
        maximumOutputByteCount: UInt64,
        cleanupTimeoutSeconds: Double
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.oracleID = oracleID
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.maximumOutputByteCount = maximumOutputByteCount
        self.cleanupTimeoutSeconds = cleanupTimeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID
        case oracleID
        case executablePath
        case arguments
        case workingDirectory
        case timeoutSeconds, maximumOutputByteCount, cleanupTimeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported timing external oracle request schema version."
            )
        }
        self.runID = try container.decode(String.self, forKey: .runID)
        self.oracleID = try container.decode(String.self, forKey: .oracleID)
        self.executablePath = try container.decode(String.self, forKey: .executablePath)
        self.arguments = try container.decode([String].self, forKey: .arguments)
        self.workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        self.timeoutSeconds = try container.decode(Double.self, forKey: .timeoutSeconds)
        self.maximumOutputByteCount = try container.decode(UInt64.self, forKey: .maximumOutputByteCount)
        self.cleanupTimeoutSeconds = try container.decode(Double.self, forKey: .cleanupTimeoutSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(runID, forKey: .runID)
        try container.encode(oracleID, forKey: .oracleID)
        try container.encode(executablePath, forKey: .executablePath)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(maximumOutputByteCount, forKey: .maximumOutputByteCount)
        try container.encode(cleanupTimeoutSeconds, forKey: .cleanupTimeoutSeconds)
    }
}

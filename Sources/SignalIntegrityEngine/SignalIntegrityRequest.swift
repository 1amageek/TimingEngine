import CircuiteFoundation
import Foundation

/// Inputs for coupling-aware signal-integrity analysis.
public struct SignalIntegrityRequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = SchemaVersion.v1

    public let schemaVersion: SchemaVersion
    public let runID: String
    public let inputs: [ArtifactReference]
    public let design: ArtifactReference
    public let topDesignName: String
    public let designRevision: ContentDigest?
    public let constraints: ArtifactReference
    public let requestedModeIDs: [String]
    public let pdkManifest: ArtifactReference
    public let processID: String
    public let pdkVersion: String
    public let pdkDigest: ContentDigest?
    public let parasitics: ArtifactReference
    public let maxDeltaDelay: Double
    public let maxNoiseRatio: Double
    public let configurationDigest: ContentDigest?
    public let randomSeed: UInt64?

    public init(
        runID: String,
        design: ArtifactReference,
        topDesignName: String,
        designRevision: ContentDigest? = nil,
        constraints: ArtifactReference,
        requestedModeIDs: [String] = [],
        pdkManifest: ArtifactReference,
        processID: String,
        pdkVersion: String,
        pdkDigest: ContentDigest? = nil,
        parasitics: ArtifactReference,
        maxDeltaDelay: Double = .greatestFiniteMagnitude,
        maxNoiseRatio: Double = .greatestFiniteMagnitude,
        configurationDigest: ContentDigest? = nil,
        randomSeed: UInt64? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.design = design
        self.topDesignName = topDesignName
        self.designRevision = designRevision
        self.constraints = constraints
        self.requestedModeIDs = requestedModeIDs
        self.pdkManifest = pdkManifest
        self.processID = processID
        self.pdkVersion = pdkVersion
        self.pdkDigest = pdkDigest
        self.parasitics = parasitics
        self.maxDeltaDelay = maxDeltaDelay
        self.maxNoiseRatio = maxNoiseRatio
        self.configurationDigest = configurationDigest
        self.randomSeed = randomSeed
        self.inputs = [design, constraints, pdkManifest, parasitics]
    }
}

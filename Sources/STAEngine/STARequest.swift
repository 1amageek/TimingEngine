import CircuiteFoundation
import Foundation
import TimingCore

/// Inputs for a static timing analysis execution.
public struct STARequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = SchemaVersion.v1

    public let schemaVersion: SchemaVersion
    public let runID: String
    public let inputs: [ArtifactReference]
    public let design: ArtifactReference
    public let topDesignName: String
    public let designRevision: ContentDigest?
    public let libraries: [TimingLibraryReference]
    public let constraints: ArtifactReference
    public let requestedModeIDs: [String]
    public let requestedCornerIDs: [String]
    public let pdkManifest: ArtifactReference
    public let processID: String
    public let pdkVersion: String
    public let pdkDigest: ContentDigest?
    public let parasitics: ArtifactReference?
    public let analysisKinds: [STAAnalysisKind]
    public let maxPaths: Int
    public let requiresPostLayoutInputs: Bool
    public let variation: STAVariation
    public let configurationDigest: ContentDigest?
    public let randomSeed: UInt64?

    public init(
        runID: String,
        design: ArtifactReference,
        topDesignName: String,
        designRevision: ContentDigest? = nil,
        libraries: [TimingLibraryReference],
        constraints: ArtifactReference,
        requestedModeIDs: [String] = [],
        requestedCornerIDs: [String] = [],
        pdkManifest: ArtifactReference,
        processID: String,
        pdkVersion: String,
        pdkDigest: ContentDigest? = nil,
        parasitics: ArtifactReference? = nil,
        analysisKinds: [STAAnalysisKind] = [.setup, .hold],
        maxPaths: Int = 20,
        requiresPostLayoutInputs: Bool = false,
        variation: STAVariation = STAVariation(),
        configurationDigest: ContentDigest? = nil,
        randomSeed: UInt64? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.design = design
        self.topDesignName = topDesignName
        self.designRevision = designRevision
        self.libraries = libraries
        self.constraints = constraints
        self.requestedModeIDs = requestedModeIDs
        self.requestedCornerIDs = requestedCornerIDs
        self.pdkManifest = pdkManifest
        self.processID = processID
        self.pdkVersion = pdkVersion
        self.pdkDigest = pdkDigest
        self.parasitics = parasitics
        self.analysisKinds = analysisKinds
        self.maxPaths = max(1, maxPaths)
        self.requiresPostLayoutInputs = requiresPostLayoutInputs
        self.variation = variation
        self.configurationDigest = configurationDigest
        self.randomSeed = randomSeed
        self.inputs = [design]
            + libraries.map(\.artifact)
            + [constraints, pdkManifest]
            + (parasitics.map { [$0] } ?? [])
    }
}

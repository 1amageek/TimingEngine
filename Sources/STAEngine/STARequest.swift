import CircuiteFoundation
import Foundation
import TimingCore

/// Inputs for a static timing analysis execution.
public struct STARequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = SchemaVersion.v3

    public let schemaVersion: SchemaVersion
    public let runID: String
    public let inputs: [ArtifactReference]
    public let design: TimingArtifactBinding
    public let topDesignName: String
    public let canonicalDesignDigest: ContentDigest?
    public let libraries: [TimingLibraryReference]
    public let constraints: TimingArtifactBinding
    public let requestedModeIDs: [String]
    public let requestedCornerIDs: [String]
    public let pdkManifest: TimingArtifactBinding
    public let processID: String
    public let pdkVersion: String
    public let pdkDigest: ContentDigest?
    public let parasitics: TimingArtifactBinding?
    public let analysisKinds: [STAAnalysisKind]
    public let maxPaths: Int
    public let requiresPostLayoutInputs: Bool
    public let variation: STAVariation
    public let configurationDigest: ContentDigest?
    public let randomSeed: UInt64?

    public var artifactBindings: [TimingArtifactBinding] {
        [design]
            + libraries.map(\.artifact)
            + [constraints, pdkManifest]
            + (parasitics.map { [$0] } ?? [])
    }

    public init(
        runID: String,
        design: TimingArtifactBinding,
        topDesignName: String,
        canonicalDesignDigest: ContentDigest? = nil,
        libraries: [TimingLibraryReference],
        constraints: TimingArtifactBinding,
        requestedModeIDs: [String] = [],
        requestedCornerIDs: [String] = [],
        pdkManifest: TimingArtifactBinding,
        processID: String,
        pdkVersion: String,
        pdkDigest: ContentDigest? = nil,
        parasitics: TimingArtifactBinding? = nil,
        analysisKinds: [STAAnalysisKind] = [.setup, .hold],
        maxPaths: Int = 20,
        requiresPostLayoutInputs: Bool = false,
        variation: STAVariation = STAVariation(),
        configurationDigest: ContentDigest? = nil,
        randomSeed: UInt64? = nil
    ) throws {
        guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !topDesignName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !processID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pdkVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimingError.invalidInput(
                "STA run, design, process, and PDK version identities must not be empty."
            )
        }
        guard maxPaths > 0 else {
            throw TimingError.invalidInput("STA maximum path count must be positive.")
        }
        guard !analysisKinds.isEmpty else {
            throw TimingError.invalidInput("STA requires at least one analysis kind.")
        }
        guard variation.isValid else {
            throw TimingError.invalidInput("STA variation derates must be finite and positive.")
        }
        guard pdkDigest == nil || pdkDigest == pdkManifest.digest else {
            throw TimingError.invalidInput("STA PDK digest must match the bound manifest artifact.")
        }
        try Self.validateUniqueNonempty(requestedModeIDs, label: "mode")
        try Self.validateUniqueNonempty(requestedCornerIDs, label: "corner")
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.design = design
        self.topDesignName = topDesignName
        self.canonicalDesignDigest = canonicalDesignDigest
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
        self.maxPaths = maxPaths
        self.requiresPostLayoutInputs = requiresPostLayoutInputs
        self.variation = variation
        self.configurationDigest = configurationDigest
        self.randomSeed = randomSeed
        self.inputs = ([design]
            + libraries.map(\.artifact)
            + [constraints, pdkManifest]
            + (parasitics.map { [$0] } ?? [])).map(\.reference)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported STA request schema version."
            )
        }
        let decodedInputs = try container.decode([ArtifactReference].self, forKey: .inputs)
        try self.init(
            runID: container.decode(String.self, forKey: .runID),
            design: container.decode(TimingArtifactBinding.self, forKey: .design),
            topDesignName: container.decode(String.self, forKey: .topDesignName),
            canonicalDesignDigest: container.decodeIfPresent(
                ContentDigest.self,
                forKey: .canonicalDesignDigest
            ),
            libraries: container.decode([TimingLibraryReference].self, forKey: .libraries),
            constraints: container.decode(TimingArtifactBinding.self, forKey: .constraints),
            requestedModeIDs: container.decode([String].self, forKey: .requestedModeIDs),
            requestedCornerIDs: container.decode([String].self, forKey: .requestedCornerIDs),
            pdkManifest: container.decode(TimingArtifactBinding.self, forKey: .pdkManifest),
            processID: container.decode(String.self, forKey: .processID),
            pdkVersion: container.decode(String.self, forKey: .pdkVersion),
            pdkDigest: container.decodeIfPresent(ContentDigest.self, forKey: .pdkDigest),
            parasitics: container.decodeIfPresent(TimingArtifactBinding.self, forKey: .parasitics),
            analysisKinds: container.decode([STAAnalysisKind].self, forKey: .analysisKinds),
            maxPaths: container.decode(Int.self, forKey: .maxPaths),
            requiresPostLayoutInputs: container.decode(
                Bool.self,
                forKey: .requiresPostLayoutInputs
            ),
            variation: container.decode(STAVariation.self, forKey: .variation),
            configurationDigest: container.decodeIfPresent(
                ContentDigest.self,
                forKey: .configurationDigest
            ),
            randomSeed: container.decodeIfPresent(UInt64.self, forKey: .randomSeed)
        )
        guard decodedInputs == inputs else {
            throw DecodingError.dataCorruptedError(
                forKey: .inputs,
                in: container,
                debugDescription: "STA input references do not match the exact materialization bindings."
            )
        }
    }

    private static func validateUniqueNonempty(
        _ values: [String],
        label: String
    ) throws {
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(values).count == values.count else {
            throw TimingError.invalidInput("STA \(label) identities must be nonempty and unique.")
        }
    }
}

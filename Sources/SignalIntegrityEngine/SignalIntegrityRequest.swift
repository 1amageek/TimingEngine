import CircuiteFoundation
import Foundation
import TimingCore

/// Inputs for coupling-aware signal-integrity analysis.
public struct SignalIntegrityRequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = SchemaVersion.v2

    public let schemaVersion: SchemaVersion
    public let runID: String
    public let inputs: [ArtifactReference]
    public let design: TimingArtifactBinding
    public let topDesignName: String
    public let canonicalDesignDigest: ContentDigest?
    public let constraints: TimingArtifactBinding
    public let requestedModeIDs: [String]
    public let pdkManifest: TimingArtifactBinding
    public let processID: String
    public let pdkVersion: String
    public let pdkDigest: ContentDigest?
    public let parasitics: TimingArtifactBinding
    public let maxDeltaDelay: Double
    public let maxNoiseRatio: Double
    public let configurationDigest: ContentDigest?
    public let randomSeed: UInt64?

    public var artifactBindings: [TimingArtifactBinding] {
        [design, constraints, pdkManifest, parasitics]
    }

    public init(
        runID: String,
        design: TimingArtifactBinding,
        topDesignName: String,
        canonicalDesignDigest: ContentDigest? = nil,
        constraints: TimingArtifactBinding,
        requestedModeIDs: [String] = [],
        pdkManifest: TimingArtifactBinding,
        processID: String,
        pdkVersion: String,
        pdkDigest: ContentDigest? = nil,
        parasitics: TimingArtifactBinding,
        maxDeltaDelay: Double = .greatestFiniteMagnitude,
        maxNoiseRatio: Double = .greatestFiniteMagnitude,
        configurationDigest: ContentDigest? = nil,
        randomSeed: UInt64? = nil
    ) throws {
        guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !topDesignName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !processID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pdkVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimingError.invalidInput(
                "Signal-integrity run, design, process, and PDK version identities must not be empty."
            )
        }
        guard maxDeltaDelay.isFinite, maxDeltaDelay >= 0,
              maxNoiseRatio.isFinite, maxNoiseRatio >= 0 else {
            throw TimingError.invalidInput(
                "Signal-integrity thresholds must be finite and nonnegative."
            )
        }
        guard pdkDigest == nil || pdkDigest == pdkManifest.digest else {
            throw TimingError.invalidInput(
                "Signal-integrity PDK digest must match the bound manifest artifact."
            )
        }
        guard requestedModeIDs.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), Set(requestedModeIDs).count == requestedModeIDs.count else {
            throw TimingError.invalidInput(
                "Signal-integrity mode identities must be nonempty and unique."
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.design = design
        self.topDesignName = topDesignName
        self.canonicalDesignDigest = canonicalDesignDigest
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
        self.inputs = [design, constraints, pdkManifest, parasitics].map(\.reference)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported signal-integrity request schema version."
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
            constraints: container.decode(TimingArtifactBinding.self, forKey: .constraints),
            requestedModeIDs: container.decode([String].self, forKey: .requestedModeIDs),
            pdkManifest: container.decode(TimingArtifactBinding.self, forKey: .pdkManifest),
            processID: container.decode(String.self, forKey: .processID),
            pdkVersion: container.decode(String.self, forKey: .pdkVersion),
            pdkDigest: container.decodeIfPresent(ContentDigest.self, forKey: .pdkDigest),
            parasitics: container.decode(TimingArtifactBinding.self, forKey: .parasitics),
            maxDeltaDelay: container.decode(Double.self, forKey: .maxDeltaDelay),
            maxNoiseRatio: container.decode(Double.self, forKey: .maxNoiseRatio),
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
                debugDescription: "Signal-integrity inputs do not match the exact materialization bindings."
            )
        }
    }
}

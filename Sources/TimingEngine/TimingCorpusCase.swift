import Foundation

public struct TimingCorpusCase: Sendable, Hashable, Codable {
    public enum Engine: String, Sendable, Hashable, Codable {
        case sta
        case signalIntegrity
    }

    public var caseID: String
    public var engine: Engine
    public var description: String
    public var expectedOutcome: TimingCorpusExpectedOutcome
    public var expectedDiagnosticCodes: [String]
    public var designPath: String
    public var topDesignName: String
    public var libraryPaths: [String]
    public var constraintPath: String
    public var pdkManifestPath: String
    public var processID: String
    public var pdkVersion: String
    public var pdkDigest: String?
    public var parasiticsPath: String?
    public var modeIDs: [String]
    public var cornerIDs: [String]
    public var requiresPostLayoutInputs: Bool
    public var expectedWorstSetupSlack: Double?
    public var expectedWorstHoldSlack: Double?

    public init(
        caseID: String,
        engine: Engine = .sta,
        description: String,
        expectedOutcome: TimingCorpusExpectedOutcome,
        expectedDiagnosticCodes: [String] = [],
        designPath: String,
        topDesignName: String,
        libraryPaths: [String] = [],
        constraintPath: String,
        pdkManifestPath: String,
        processID: String,
        pdkVersion: String,
        pdkDigest: String? = nil,
        parasiticsPath: String? = nil,
        modeIDs: [String] = [],
        cornerIDs: [String] = [],
        requiresPostLayoutInputs: Bool = false,
        expectedWorstSetupSlack: Double? = nil,
        expectedWorstHoldSlack: Double? = nil
    ) {
        self.caseID = caseID
        self.engine = engine
        self.description = description
        self.expectedOutcome = expectedOutcome
        self.expectedDiagnosticCodes = expectedDiagnosticCodes
        self.designPath = designPath
        self.topDesignName = topDesignName
        self.libraryPaths = libraryPaths
        self.constraintPath = constraintPath
        self.pdkManifestPath = pdkManifestPath
        self.processID = processID
        self.pdkVersion = pdkVersion
        self.pdkDigest = pdkDigest
        self.parasiticsPath = parasiticsPath
        self.modeIDs = modeIDs
        self.cornerIDs = cornerIDs
        self.requiresPostLayoutInputs = requiresPostLayoutInputs
        self.expectedWorstSetupSlack = expectedWorstSetupSlack
        self.expectedWorstHoldSlack = expectedWorstHoldSlack
    }

    private enum CodingKeys: String, CodingKey {
        case caseID
        case engine
        case description
        case expectedOutcome
        case expectedDiagnosticCodes
        case designPath
        case topDesignName
        case libraryPaths
        case constraintPath
        case pdkManifestPath
        case processID
        case pdkVersion
        case pdkDigest
        case parasiticsPath
        case modeIDs
        case cornerIDs
        case requiresPostLayoutInputs
        case expectedWorstSetupSlack
        case expectedWorstHoldSlack
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            caseID: try container.decode(String.self, forKey: .caseID),
            engine: try container.decode(Engine.self, forKey: .engine),
            description: try container.decode(String.self, forKey: .description),
            expectedOutcome: try container.decode(TimingCorpusExpectedOutcome.self, forKey: .expectedOutcome),
            expectedDiagnosticCodes: try container.decode([String].self, forKey: .expectedDiagnosticCodes),
            designPath: try container.decode(String.self, forKey: .designPath),
            topDesignName: try container.decode(String.self, forKey: .topDesignName),
            libraryPaths: try container.decode([String].self, forKey: .libraryPaths),
            constraintPath: try container.decode(String.self, forKey: .constraintPath),
            pdkManifestPath: try container.decode(String.self, forKey: .pdkManifestPath),
            processID: try container.decode(String.self, forKey: .processID),
            pdkVersion: try container.decode(String.self, forKey: .pdkVersion),
            pdkDigest: try container.decodeIfPresent(String.self, forKey: .pdkDigest),
            parasiticsPath: try container.decodeIfPresent(String.self, forKey: .parasiticsPath),
            modeIDs: try container.decode([String].self, forKey: .modeIDs),
            cornerIDs: try container.decode([String].self, forKey: .cornerIDs),
            requiresPostLayoutInputs: try container.decode(Bool.self, forKey: .requiresPostLayoutInputs),
            expectedWorstSetupSlack: try container.decodeIfPresent(Double.self, forKey: .expectedWorstSetupSlack),
            expectedWorstHoldSlack: try container.decodeIfPresent(Double.self, forKey: .expectedWorstHoldSlack)
        )
    }
}

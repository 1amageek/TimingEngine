import Foundation
import DesignFlowKernel
import LogicIR
import TimingCore
import PDKCore

@available(*, deprecated, message: "Use STAFoundationRequest for all new executions.")
public struct LegacySTARequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var runID: String
    public var inputs: [ArtifactReference]

    public var design: LogicDesignReference
    public var libraries: [TimingLibraryReference]
    public var constraints: TimingConstraintReference
    public var pdk: PDKReference
    public var parasitics: ArtifactReference?
    public var requestedModeIDs: [String]
    public var requestedCornerIDs: [String]
    public var analysisKinds: [STAAnalysisKind]
    public var maxPaths: Int
    public var requiresSignoff: Bool
    public var variation: STAVariation

    public init(
        runID: String,
        inputs: [ArtifactReference],
        design: LogicDesignReference,
        libraries: [TimingLibraryReference],
        constraints: TimingConstraintReference,
        pdk: PDKReference,
        parasitics: ArtifactReference? = nil,
        requestedModeIDs: [String] = [],
        requestedCornerIDs: [String] = [],
        analysisKinds: [STAAnalysisKind] = [.setup, .hold],
        maxPaths: Int = 20,
        requiresSignoff: Bool = false,
        variation: STAVariation = STAVariation()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.inputs = inputs
        self.design = design
        self.libraries = libraries
        self.constraints = constraints
        self.pdk = pdk
        self.parasitics = parasitics
        self.requestedModeIDs = requestedModeIDs
        self.requestedCornerIDs = requestedCornerIDs
        self.analysisKinds = analysisKinds
        self.maxPaths = max(1, maxPaths)
        self.requiresSignoff = requiresSignoff
        self.variation = variation
    }
}

@available(*, deprecated, message: "Use STAFoundationRequest for all new executions.")
public typealias STARequest = LegacySTARequest

import Foundation
import XcircuitePackage
import LogicIR
import TimingCore
import PDKCore

public struct STARequest: XcircuiteEngineRequest {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var runID: String
    public var inputs: [XcircuiteFileReference]

    public var design: LogicDesignReference
    public var libraries: [TimingLibraryReference]
    public var constraints: TimingConstraintReference
    public var pdk: PDKReference
    public var parasitics: XcircuiteFileReference?
    public var requestedModeIDs: [String]
    public var requestedCornerIDs: [String]
    public var analysisKinds: [STAAnalysisKind]
    public var maxPaths: Int
    public var requiresSignoff: Bool
    public var variation: STAVariation

    public init(
        runID: String,
        inputs: [XcircuiteFileReference],
        design: LogicDesignReference,
        libraries: [TimingLibraryReference],
        constraints: TimingConstraintReference,
        pdk: PDKReference,
        parasitics: XcircuiteFileReference? = nil,
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

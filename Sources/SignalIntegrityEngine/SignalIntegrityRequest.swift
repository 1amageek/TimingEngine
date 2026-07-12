import Foundation
import XcircuitePackage
import LogicIR
import TimingCore
import PDKCore

public struct SignalIntegrityRequest: XcircuiteEngineRequest {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var runID: String
    public var inputs: [XcircuiteFileReference]

    public var design: LogicDesignReference
    public var constraints: TimingConstraintReference
    public var pdk: PDKReference
    public var parasitics: XcircuiteFileReference
    public var maxDeltaDelay: Double
    public var maxNoiseRatio: Double

    public init(
        runID: String,
        inputs: [XcircuiteFileReference],
        design: LogicDesignReference,
        constraints: TimingConstraintReference,
        pdk: PDKReference,
        parasitics: XcircuiteFileReference,
        maxDeltaDelay: Double = Double.greatestFiniteMagnitude,
        maxNoiseRatio: Double = Double.greatestFiniteMagnitude
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.inputs = inputs
        self.design = design
        self.constraints = constraints
        self.pdk = pdk
        self.parasitics = parasitics
        self.maxDeltaDelay = maxDeltaDelay
        self.maxNoiseRatio = maxNoiseRatio
    }
}

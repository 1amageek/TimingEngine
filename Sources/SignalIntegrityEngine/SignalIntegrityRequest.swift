import Foundation
import DesignFlowKernel
import LogicIR
import TimingCore
import PDKCore

@available(*, deprecated, message: "Use SignalIntegrityFoundationRequest for all new executions.")
public struct LegacySignalIntegrityRequest: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var runID: String
    public var inputs: [ArtifactReference]

    public var design: LogicDesignReference
    public var constraints: TimingConstraintReference
    public var pdk: PDKReference
    public var parasitics: ArtifactReference
    public var maxDeltaDelay: Double
    public var maxNoiseRatio: Double

    public init(
        runID: String,
        inputs: [ArtifactReference],
        design: LogicDesignReference,
        constraints: TimingConstraintReference,
        pdk: PDKReference,
        parasitics: ArtifactReference,
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

@available(*, deprecated, message: "Use SignalIntegrityFoundationRequest for all new executions.")
public typealias SignalIntegrityRequest = LegacySignalIntegrityRequest

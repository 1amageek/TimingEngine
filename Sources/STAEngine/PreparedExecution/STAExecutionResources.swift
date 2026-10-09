import TimingCore
import TimingPDKProfileInspection

public struct STAExecutionResources: Sendable {
    public let reader: any TimingArtifactReading
    public let inspectedSources: TimingInspectedLibertySources?
    public let sourceLimits: LibertySourceParseLimits
    public let sourceResources: any LibertySourceResourceAccounting
    public let limits: STAExecutionLimits
    public let requiresStrictTransformAccounting: Bool
    public init(reader: any TimingArtifactReading, inspectedSources: TimingInspectedLibertySources? = nil,
        sourceLimits: LibertySourceParseLimits, sourceResources: any LibertySourceResourceAccounting,
        limits: STAExecutionLimits, requiresStrictTransformAccounting: Bool = false) {
        self.reader = reader; self.inspectedSources = inspectedSources; self.sourceLimits = sourceLimits
        self.sourceResources = sourceResources; self.limits = limits
        self.requiresStrictTransformAccounting = requiresStrictTransformAccounting
    }
}

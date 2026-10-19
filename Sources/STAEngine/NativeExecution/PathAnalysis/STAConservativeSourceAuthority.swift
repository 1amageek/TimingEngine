import TimingCore

/// Exact source domain used for every history in one retained coupled operator.
public struct STAConservativeSourceAuthority: Sendable, Hashable, Codable {
    public let endpoint: TimingParasitics.Endpoint
    public let sourceIsPort: Bool
    public let constantVoltage: Double?
    public let riseSlew: ClosedRange<Double>?
    public let fallSlew: ClosedRange<Double>?
    public let sourceArcs: [LibertyTimingSourceIdentity]
    public let prescribedBoundaryLoad: Double?
    public var loadModelIdentity: String { STAConservativeCoupledRCOptions.loadModelIdentity }
}

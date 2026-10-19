import TimingCore

/// Model-relative enclosure; exact preparation/replay is required for acceptance.
public struct STAConservativeWireObservation: Sendable, Hashable, Codable {
    public let modeID: String
    public let cornerID: String
    public let net: String
    public let source: TimingParasitics.Endpoint
    public let sink: TimingParasitics.Endpoint
    public let edge: TimingEdge
    public let sourceAuthorities: [STAConservativeSourceAuthority]
    public let sourceSlew: ClosedRange<Double>
    public let admittedSourceSlew: ClosedRange<Double>
    public let delay: ClosedRange<Double>
    public let slew: ClosedRange<Double>
    public let voltageErrorUpperBound: Double
    public let minimumCrossingDerivative: Double
    public let maximumAbsoluteDerivative: Double
    public var modelIdentity: String { STAConservativeCoupledRCOptions.modelIdentity }
}

import TimingCore

/// Caller-owned limits and explicit model premise for certified coupled boundary timing.
public struct STAConservativeCoupledRCOptions: Sendable, Hashable, Codable {
    public enum OperatingHistory: String, Sendable, Hashable, Codable {
        case boundedOperatingHistory
    }
    public let maximumNodes: Int
    public let maximumBasisSweeps: Int
    public let maximumCertificateAttempts: Int
    public let operatingHistory: OperatingHistory
    public static let modelIdentity = "nldm-prescribed-boundary.retained-load.bounded-history.coupled-rc.v1"
    public static let loadModelIdentity = "canonical-pin-plus-net-plus-equipotential-spef-load.v1"

    public init(maximumNodes: Int, maximumBasisSweeps: Int, maximumCertificateAttempts: Int,
                operatingHistory: OperatingHistory) throws {
        guard maximumNodes > 0, maximumBasisSweeps > 0, maximumCertificateAttempts > 0 else {
            throw TimingError.invalidInput("Certified coupled RC requires positive finite resource limits")
        }
        self.maximumNodes = maximumNodes; self.maximumBasisSweeps = maximumBasisSweeps
        self.maximumCertificateAttempts = maximumCertificateAttempts; self.operatingHistory = operatingHistory
    }

    private enum CodingKeys: String, CodingKey {
        case maximumNodes, maximumBasisSweeps, maximumCertificateAttempts, operatingHistory
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumNodes: c.decode(Int.self, forKey: .maximumNodes),
            maximumBasisSweeps: c.decode(Int.self, forKey: .maximumBasisSweeps),
            maximumCertificateAttempts: c.decode(Int.self, forKey: .maximumCertificateAttempts),
            operatingHistory: c.decode(OperatingHistory.self, forKey: .operatingHistory))
    }
}

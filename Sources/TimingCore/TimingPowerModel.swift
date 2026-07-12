import Foundation

public struct TimingPowerModel: Sendable, Hashable, Codable {
    public var leakagePower: Double?
    public var internalPower: Double?

    public init(leakagePower: Double? = nil, internalPower: Double? = nil) {
        self.leakagePower = leakagePower
        self.internalPower = internalPower
    }
}

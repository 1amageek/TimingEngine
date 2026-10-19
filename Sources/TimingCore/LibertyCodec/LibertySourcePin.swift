/// An original pin declaration, in source order; no inferred terminal identity.
public struct LibertySourcePin: Sendable, Hashable, Codable {
    public let name: String
    public let direction: TimingPin.Direction
    public let function: LibertySourceFunction?
    public let stateFunction: LibertySourceFunction?
    public let threeState: LibertySourceFunction?
    public let xFunction: LibertySourceFunction?
    public let powerDownFunction: LibertySourceFunction?
    public let relatedPowerPin: String?
    public let relatedGroundPin: String?
    public let line: Int
    public let byteOffset: Int
    internal init(name: String, direction: TimingPin.Direction, function: LibertySourceFunction?,
                  stateFunction: LibertySourceFunction?, threeState: LibertySourceFunction?, xFunction: LibertySourceFunction?,
                  line: Int, byteOffset: Int, powerDownFunction: LibertySourceFunction? = nil,
                  relatedPowerPin: String? = nil, relatedGroundPin: String? = nil) {
        self.name = name; self.direction = direction; self.function = function
        self.stateFunction = stateFunction; self.threeState = threeState; self.xFunction = xFunction
        self.powerDownFunction = powerDownFunction; self.relatedPowerPin = relatedPowerPin; self.relatedGroundPin = relatedGroundPin
        self.line = line; self.byteOffset = byteOffset
    }
}

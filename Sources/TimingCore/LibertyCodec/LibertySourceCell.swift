/// Original ordered cell/pin facts from actual Liberty grammar nodes.
public struct LibertySourceCell: Sendable, Hashable {
    public let name: String
    public let pins: [LibertySourcePin]
    public let powerPins: [LibertySourcePowerPin]
    public let area: Double?
    public let dontUse: Bool?
    public let sequential: [LibertySourceSequential]
    public let unsupportedFunctionalGroups: [String]
    public let line: Int
    public let byteOffset: Int
    internal init(name: String, pins: [LibertySourcePin], area: Double?, dontUse: Bool?,
                  sequential: [LibertySourceSequential], unsupportedFunctionalGroups: [String], line: Int, byteOffset: Int,
                  powerPins: [LibertySourcePowerPin] = []) {
        self.name = name; self.pins = pins; self.area = area; self.dontUse = dontUse
        self.powerPins = powerPins
        self.sequential = sequential; self.unsupportedFunctionalGroups = unsupportedFunctionalGroups
        self.line = line; self.byteOffset = byteOffset
    }
}

/// Original sequential declarations; eligibility belongs to the library compiler.
public struct LibertySourceSequential: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case flipFlop, latch }
    public let kind: Kind
    public let variables: [String]
    public let data: LibertySourceFunction?
    public let control: LibertySourceFunction?
    public let additionalControl: LibertySourceFunction?
    public let powerDownFunction: LibertySourceFunction?
    public let clear: LibertySourceFunction?
    public let preset: LibertySourceFunction?
    public let clearPresetVariable1: String?
    public let clearPresetVariable2: String?
    public let line: Int
    public let byteOffset: Int

    internal init(kind: Kind, variables: [String], data: LibertySourceFunction?, control: LibertySourceFunction?,
                  additionalControl: LibertySourceFunction?, powerDownFunction: LibertySourceFunction?,
                  clear: LibertySourceFunction?, preset: LibertySourceFunction?,
                  clearPresetVariable1: String?, clearPresetVariable2: String?, line: Int, byteOffset: Int) {
        self.kind = kind; self.variables = variables; self.data = data; self.control = control
        self.additionalControl = additionalControl; self.clear = clear; self.preset = preset
        self.powerDownFunction = powerDownFunction
        self.clearPresetVariable1 = clearPresetVariable1; self.clearPresetVariable2 = clearPresetVariable2
        self.line = line; self.byteOffset = byteOffset
    }
}

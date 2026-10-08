/// Original ordered cell/pin facts from actual Liberty grammar nodes.
public struct LibertySourceCell: Sendable, Hashable {
    public let name: String
    public let pins: [LibertySourcePin]
    public let line: Int
    public let byteOffset: Int
    internal init(name: String, pins: [LibertySourcePin], line: Int, byteOffset: Int) {
        self.name = name; self.pins = pins; self.line = line; self.byteOffset = byteOffset
    }
}

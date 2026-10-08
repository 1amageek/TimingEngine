/// Raw Liberty numeric observations. Numeric process has no named PDK interpretation.
public struct LibertySourceOperatingCondition: Sendable, Hashable {
    public let name: String
    public let process: Double?
    public let voltage: Double?
    public let temperature: Double?
    public let line: Int
    public let byteOffset: Int
    internal init(name: String, process: Double?, voltage: Double?, temperature: Double?, line: Int, byteOffset: Int) {
        self.name = name; self.process = process; self.voltage = voltage
        self.temperature = temperature; self.line = line; self.byteOffset = byteOffset
    }
}

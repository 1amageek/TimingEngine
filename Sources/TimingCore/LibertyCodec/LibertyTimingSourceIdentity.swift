/// Declared source-local timing identity; a public value never grants characterized admission.
public struct LibertyTimingSourceIdentity: Sendable, Hashable, Codable {
    public let cell: String
    public let pin: String
    public let timingType: String?
    public let line: Int
    public let byteOffset: Int
    public let ordinal: Int
    public let tables: [LibertyTimingTableIdentity]
    internal init(cell: String, pin: String, timingType: String?, line: Int, byteOffset: Int,
                  ordinal: Int, tables: [LibertyTimingTableIdentity]) {
        self.cell = cell; self.pin = pin; self.timingType = timingType
        self.line = line; self.byteOffset = byteOffset; self.ordinal = ordinal; self.tables = tables
    }
}

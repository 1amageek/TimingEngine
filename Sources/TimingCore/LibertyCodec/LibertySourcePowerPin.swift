/// Positioned PG facts; no nominal supply value or electrical qualification is inferred.
public struct LibertySourcePowerPin: Sendable, Hashable, Codable {
    public let name: String
    public let pgType: String?
    public let voltageName: String?
    public let line: Int
    public let byteOffset: Int

    internal init(name: String, pgType: String?, voltageName: String?, line: Int, byteOffset: Int) {
        self.name = name; self.pgType = pgType; self.voltageName = voltageName
        self.line = line; self.byteOffset = byteOffset
    }
}

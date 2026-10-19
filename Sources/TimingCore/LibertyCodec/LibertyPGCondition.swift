/// A caller-declared binary PG condition; construction or decoding grants no source authority.
public struct LibertyPGCondition: Sendable, Hashable, Codable {
    public let pin: String
    public let sourcePGType: String
    public let value: Bool

    public init(pin: String, sourcePGType: String, value: Bool) {
        self.pin = pin; self.sourcePGType = sourcePGType; self.value = value
    }
}

/// A complete source function and the exact meaning of each ordered input slot.
public struct TimingSequentialFunctionBinding: Sendable, Hashable, Codable {
    public enum Role: Sendable, Hashable, Codable {
        case data, control, additionalControl, powerDown, clear, preset
        case output(pin: String), outputState(pin: String), threeState(pin: String), xFunction(pin: String), outputPowerDown(pin: String)
    }
    public enum Symbol: Sendable, Hashable, Codable {
        case inputPin(String), stateVariable(String), powerPin(String)
    }
    public let role: Role
    public let function: LibertySourceFunction
    public let symbols: [Symbol]

    internal init(role: Role, function: LibertySourceFunction, symbols: [Symbol]) {
        self.role = role; self.function = function; self.symbols = symbols
    }
}

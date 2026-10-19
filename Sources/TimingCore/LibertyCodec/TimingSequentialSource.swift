/// Declared source transport. Only exact owned-source admission establishes eligibility.
public struct TimingSequentialSource: Sendable, Hashable, Codable {
    public enum Binding: Sendable, Hashable, Codable {
        case bound([TimingSequentialFunctionBinding])
        case unavailable(TimingSequentialBindingError)
    }
    public let declarations: [LibertySourceSequential]
    public let pins: [LibertySourcePin]
    public let powerPins: [LibertySourcePowerPin]
    public let binding: Binding

    internal init(declarations: [LibertySourceSequential], pins: [LibertySourcePin], powerPins: [LibertySourcePowerPin], binding: Binding) {
        self.declarations = declarations; self.pins = pins; self.powerPins = powerPins; self.binding = binding
    }

    public func requireBindings() throws(TimingSequentialBindingError) -> [TimingSequentialFunctionBinding] {
        switch binding {
        case .bound(let functions): return functions
        case .unavailable(let reason): throw reason
        }
    }

    public func function(for role: TimingSequentialFunctionBinding.Role) -> TimingSequentialFunctionBinding? {
        guard case .bound(let functions) = binding else { return nil }
        return functions.first { $0.role == role }
    }

    /// Exact syntactic identity/inversion views; arbitrary Boolean programs remain complete functions.
    func singleInput(for role: TimingSequentialFunctionBinding.Role, allowingInversion: Bool) -> String? {
        guard let bound = function(for: role), bound.symbols.count == 1,
              case .inputPin(let name) = bound.symbols[0], case .normalized(let facts) = bound.function.content else { return nil }
        if facts.operations.count == 1, facts.output.rawValue == 0,
           case .input(0) = facts.operations[0] { return name }
        if allowingInversion, facts.operations.count == 2, facts.output.rawValue == 1,
           case .input(0) = facts.operations[0], case .invert(let input) = facts.operations[1], input.rawValue == 0 { return name }
        return nil
    }

    var singleOutput: String? {
        let outputs = pins.filter { $0.direction == .output }
        guard outputs.count == 1, function(for: .output(pin: outputs[0].name)) != nil else { return nil }
        return outputs[0].name
    }

    var simpleEdgeTriggeredPins: TimingSequentialModel.LegacyPins? {
        guard declarations.count == 1, declarations[0].kind == .flipFlop,
              declarations[0].additionalControl == nil, declarations[0].powerDownFunction == nil,
              declarations[0].clear == nil, declarations[0].preset == nil,
              declarations[0].clearPresetVariable1 == nil, declarations[0].clearPresetVariable2 == nil,
              pins.allSatisfy({ $0.powerDownFunction == nil && $0.threeState == nil && $0.xFunction == nil && $0.stateFunction == nil }),
              let data = singleInput(for: .data, allowingInversion: false),
              let clock = singleInput(for: .control, allowingInversion: true), let output = singleOutput,
              let outputFunction = function(for: .output(pin: output)), outputFunction.symbols.count == 1,
              case .stateVariable = outputFunction.symbols[0],
              case .normalized(let outputFacts) = outputFunction.function.content,
              outputFacts.operations.count == 1, outputFacts.output.rawValue == 0,
              case .input(0) = outputFacts.operations[0] else { return nil }
        return .init(dataPin: data, clockPin: clock, outputPin: output)
    }
}

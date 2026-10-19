/// Binds normalized programs without changing their truth functions or guessing sequential roles.
struct LibertySequentialBinding {
    let storage: LibertyParseStorage?

    func model(_ cell: LibertySourceCell, numerical: TimingSequentialModel?) throws -> TimingSequentialModel {
        let binding: TimingSequentialSource.Binding
        do { binding = .bound(try functions(cell)) }
        catch let reason as TimingSequentialBindingError { binding = .unavailable(reason) }
        return TimingSequentialModel(source: .init(declarations: cell.sequential, pins: cell.pins,
            powerPins: cell.powerPins, binding: binding), numerical: numerical)
    }

    private func functions(_ cell: LibertySourceCell) throws -> [TimingSequentialFunctionBinding] {
        // FIXME(INCOMPLETE_IMPLEMENTATION): Owned source intake retains multiple sequential groups but
        // this production binder cannot compose their state domains. Strict execution must refuse this
        // binding until cross-group state/control semantics and their behavioral tests are implemented.
        guard cell.sequential.count == 1 else { throw TimingSequentialBindingError.multipleDeclarations }
        let declaration = cell.sequential[0]
        guard !declaration.variables.isEmpty else { throw TimingSequentialBindingError.invalidStateVariables }
        for (index, variable) in declaration.variables.enumerated() {
            try check(variable)
            guard !variable.isEmpty else { throw TimingSequentialBindingError.invalidStateVariables }
            for pin in cell.pins {
                try check(pin.name)
                if pin.name == variable { throw TimingSequentialBindingError.ambiguousSymbol(variable) }
            }
            for pin in cell.powerPins {
                try check(pin.name)
                if pin.name == variable { throw TimingSequentialBindingError.ambiguousSymbol(variable) }
            }
            for prior in declaration.variables[..<index] {
                try check(prior)
                if prior == variable { throw TimingSequentialBindingError.invalidStateVariables }
            }
        }
        var result = LibertyBuffer<TimingSequentialFunctionBinding>()
        func bind(_ role: TimingSequentialFunctionBinding.Role, _ function: LibertySourceFunction?, required: Bool = false) throws {
            guard let function else {
                if required { throw TimingSequentialBindingError.missingFunction(role) }
                return
            }
            guard case .normalized(let facts) = function.content else {
                if case .unsupported(let issue) = function.content { throw TimingSequentialBindingError.unsupportedFunction(role, issue) }
                throw TimingSequentialBindingError.missingFunction(role)
            }
            var symbols = LibertyBuffer<TimingSequentialFunctionBinding.Symbol>()
            for name in facts.symbols {
                try check(name)
                var resolved: TimingSequentialFunctionBinding.Symbol?
                func assign(_ value: TimingSequentialFunctionBinding.Symbol) throws {
                    guard resolved == nil else { throw TimingSequentialBindingError.ambiguousSymbol(name) }
                    resolved = value
                }
                for pin in cell.pins {
                    try check(pin.name)
                    if pin.name == name, pin.direction == .input { try assign(.inputPin(name)) }
                }
                for variable in declaration.variables {
                    try check(variable)
                    if variable == name { try assign(.stateVariable(name)) }
                }
                for pin in cell.powerPins {
                    try check(pin.name)
                    if pin.name == name { try assign(.powerPin(name)) }
                }
                guard let resolved else { throw TimingSequentialBindingError.unresolvedSymbol(name) }
                try symbols.append(resolved, storage: storage)
            }
            try result.append(.init(role: role, function: function, symbols: try symbols.array(storage: storage)), storage: storage)
        }
        try bind(.data, declaration.data, required: true)
        try bind(.control, declaration.control, required: true)
        try bind(.additionalControl, declaration.additionalControl)
        try bind(.powerDown, declaration.powerDownFunction)
        try bind(.clear, declaration.clear)
        try bind(.preset, declaration.preset)
        for pin in cell.pins where pin.direction == .output {
            try check(pin.name)
            try bind(.output(pin: pin.name), pin.function, required: true)
            try bind(.outputState(pin: pin.name), pin.stateFunction)
            try bind(.threeState(pin: pin.name), pin.threeState)
            try bind(.xFunction(pin: pin.name), pin.xFunction)
            try bind(.outputPowerDown(pin: pin.name), pin.powerDownFunction)
        }
        return try result.array(storage: storage)
    }

    private func check(_ text: String) throws { try storage?.step(UInt64(text.utf8.count) + 1) }
}

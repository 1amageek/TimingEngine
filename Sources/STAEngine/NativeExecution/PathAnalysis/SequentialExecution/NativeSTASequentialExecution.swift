import CircuiteFoundation
import LogicIR
import TimingCore

/// Executes the admitted source sequential profile without scalar-pin fallbacks.
internal enum NativeSTASequentialExecution {
    enum Failure: Error, Sendable, Equatable {
        case unsupported(String)
        case missing(String)
        case inconsistent(String)
        case nonfinite(String)
    }
    enum Kind: Sendable { case legacyFlipFlop, flipFlop, latch }
    struct OutputDefinition: Sendable {
        let pin: String
        let stateVariable: String?
        let inverted: Bool
    }
    struct Plan: Sendable {
        var transformRetention: NativeSTATransformRetention? = nil
        let kind: Kind
        let clockPin: String
        let activeEdge: TimingEdge
        let closeEdge: TimingEdge?
        let dataPins: [String]
        let controlPins: [String]
        let outputs: [OutputDefinition]
        let bindings: [TimingSequentialFunctionBinding]
        let checks: [TimingCheckArc]
        let declaration: LibertySourceSequential?
        let inputPinNames: [String]
        let powerPinNames: [String]
    }
    struct PowerFunctionReceipt: Sendable, Hashable {
        let pin: String?
        let line: Int
        let byteOffset: Int
        let value: Bool
    }
    struct NormalPowerReceipt: Sendable {
        var transformRetention: NativeSTATransformRetention? = nil
        let instance: String
        let cell: String
        let cornerID: String
        let library: ArtifactReference
        let assumptions: [STAOperatingSupplyAssumption]
        let functions: [PowerFunctionReceipt]
        let checked: CheckedLibertyNormalPower
    }

    static func compile(model: TimingSequentialModel, source: LibertySourceCell?,
                        work: inout UInt64, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                        sourceResources: (any LibertySourceResourceAccounting)? = nil) throws -> Plan {
        let temporary = NativeSTATransformStorage(budget: stateBudget, kind: .temporaryBytes)
        let retained = NativeSTATransformStorage(budget: stateBudget, kind: .liveOwnedBytes)
        try charge(1, work: &work, limits: limits, sourceResources: sourceResources)
        switch model.definition {
        case .legacy(let pins):
            try stateBudget.reserve(7)
            try retained.reserve(String.self, capacity: 3)
            try retained.reserve(OutputDefinition.self, capacity: 1)
            var result = Plan(kind: .legacyFlipFlop, clockPin: pins.clockPin, activeEdge: model.clockEdge ?? .rise,
                        closeEdge: nil, dataPins: [pins.dataPin], controlPins: [],
                        outputs: [.init(pin: pins.outputPin, stateVariable: nil, inverted: false)],
                        bindings: [], checks: model.timingChecks ?? [], declaration: nil,
                        inputPinNames: [pins.dataPin, pins.clockPin], powerPinNames: [])
            result.transformRetention = try retained.finish()
            return result
        case .source(let bound):
            guard let source, bound.declarations == source.sequential, bound.pins == source.pins,
                  bound.powerPins == source.powerPins, source.unsupportedFunctionalGroups.isEmpty else {
                throw Failure.inconsistent("Sequential model does not match owned source")
            }
            // FIXME(INCOMPLETE_IMPLEMENTATION): Multiple/compound clock groups are outside the initial
            // native profile. Production ClockPropagation/PathAnalysis must refuse them until a
            // complete source execution and behavioral evidence are available.
            try temporary.reserveSet(String.self, capacity: bound.declarations.first?.variables.count ?? 0)
            guard bound.declarations.count == 1, let declaration = bound.declarations.first,
                  declaration.variables.count == 2, Set(declaration.variables).count == 2,
                  declaration.additionalControl == nil else {
                throw Failure.unsupported("One FF/latch declaration with one clock or gate is required")
            }
            let bindings = try bound.requireBindings()
            var size = UInt64(source.pins.count + source.powerPins.count + bindings.count + (model.timingChecks?.count ?? 0) + 2)
            for binding in bindings {
                if case .normalized(let facts) = binding.function.content {
                    let next = size.addingReportingOverflow(UInt64(facts.symbols.count + facts.operations.count))
                    guard !next.overflow else { throw Failure.nonfinite("Sequential plan size") }
                    size = next.partialValue
                }
            }
            // Conservative comparison-work envelope covers the nested source membership searches.
            let square = size.multipliedReportingOverflow(by: size)
            let envelope = square.partialValue.multipliedReportingOverflow(by: 4)
            guard !square.overflow, !envelope.overflow else { throw Failure.nonfinite("Sequential plan work") }
            try charge(envelope.partialValue, work: &work, limits: limits, sourceResources: sourceResources)
            try stateBudget.reserve(bindings.count + source.pins.count * 4 + source.powerPins.count)
            try temporary.reserveSet(TimingSequentialFunctionBinding.Role.self, capacity: bindings.count)
            guard Set(try temporary.map(bindings, \.role)).count == bindings.count else {
                throw Failure.inconsistent("Duplicate sequential function role")
            }
            guard let control = bound.function(for: .control), let data = bound.function(for: .data) else {
                throw Failure.missing("Complete data and clock/gate functions")
            }
            let clock = try unary(control, state: false)
            var dataPins: [String] = [], controlPins: [String] = [], outputs: [OutputDefinition] = []
            for binding in bindings {
                try validateBinding(binding, source: source, declaration: declaration)
                try charge(UInt64(binding.symbols.count), work: &work, limits: limits, sourceResources: sourceResources)
                switch binding.role {
                case .data:
                    for symbol in binding.symbols {
                        if case .inputPin(let name) = symbol, !dataPins.contains(name) { try retained.append(name, to: &dataPins, site: 1) }
                    }
                case .clear, .preset:
                    for symbol in binding.symbols {
                        if case .inputPin(let name) = symbol, !controlPins.contains(name) { try retained.append(name, to: &controlPins, site: 2) }
                    }
                case .output(let pin):
                    let output = try unary(binding, state: true)
                    try retained.append(.init(pin: pin, stateVariable: output.name, inverted: output.inverted), to: &outputs, site: 3)
                case .additionalControl, .outputState, .threeState, .xFunction:
                    throw Failure.unsupported("Additional sequential output/control semantics")
                case .control, .powerDown, .outputPowerDown: break
                }
            }
            try temporary.reserveSet(String.self, capacity: outputs.count)
            try temporary.reserveSet(String.self, capacity: source.pins.count)
            let originalOutputs = try temporary.filter(source.pins) { $0.direction == .output }
            guard !outputs.isEmpty, Set(try temporary.map(outputs, \.pin)) == Set(try temporary.map(originalOutputs, \.name)),
                  !dataPins.isEmpty, !dataPins.contains(clock.name), !controlPins.contains(clock.name) else {
                throw Failure.unsupported("Complete physical data, control and output bindings are required")
            }
            // Validation preserves the full next-state program, including feedback slots.
            _ = data
            let inputPins = try temporary.filter(source.pins) { $0.direction == .input }
            var result = Plan(kind: declaration.kind == .latch ? .latch : .flipFlop,
                        clockPin: clock.name, activeEdge: clock.inverted ? .fall : .rise,
                        closeEdge: declaration.kind == .latch ? (clock.inverted ? .rise : .fall) : nil,
                        dataPins: dataPins, controlPins: controlPins, outputs: outputs,
                        bindings: bindings, checks: model.timingChecks ?? [], declaration: declaration,
                        inputPinNames: try retained.map(inputPins, \.name),
                        powerPinNames: try retained.map(source.powerPins, \.name))
            result.transformRetention = try retained.finish()
            return result
        }
    }

    /// Joins engine scope and consumes the shared source-only normal-power judgment.
    static func validateNormalPower(source: OwnedLibertySource, cell: String, instance: String, cornerID: String,
                                    library: ArtifactReference, assumptions: [STAOperatingSupplyAssumption],
                                    work: inout UInt64, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                                    sourceResources: (any LibertySourceResourceAccounting)? = nil) throws -> NormalPowerReceipt {
        let retained = NativeSTATransformStorage(budget: stateBudget, kind: .liveOwnedBytes)
        let temporary = NativeSTATransformStorage(budget: stateBudget, kind: .temporaryBytes)
        try charge(UInt64(assumptions.count),work:&work,limits:limits,sourceResources:sourceResources)
        try stateBudget.reserve(assumptions.count * 2)
        var consumed: [STAOperatingSupplyAssumption] = [], conditions: [LibertyPGCondition] = []
        for assumption in assumptions where assumption.instance == instance && assumption.cornerID == cornerID {
            guard assumption.cell == cell, assumption.library == library else { throw Failure.inconsistent("Operating supply engine scope join") }
            try retained.append(assumption, to: &consumed)
            try temporary.append(LibertyPGCondition(pin:assumption.pin,sourcePGType:assumption.sourcePGType,value:assumption.value == .one), to: &conditions)
        }
        let checked: CheckedLibertyNormalPower
        do {
            checked = try LibertyNormalPowerValidator().validate(source:source,cell:cell,conditions:conditions,admit:{ amount,slots,_ in
                // Core charges the retained source accountant; this callback admits only native counters.
                try charge(amount,work:&work,limits:limits,sourceResources:nil)
                try stateBudget.reserve(slots)
            })
        } catch LibertyNormalPowerError.resource(let cause) {
            // Preserve native cancellation/capacity classification across the shared source boundary.
            throw cause
        }
        try charge(UInt64(checked.receipt.functions.count),work:&work,limits:limits,sourceResources:sourceResources)
        try stateBudget.reserve(checked.receipt.functions.count)
        var functions: [PowerFunctionReceipt] = []
        for sample in checked.receipt.functions {
            let pin: String?
            switch sample.origin.owner {
            case .pin(let name): pin = name
            case .declaration: pin = nil
            }
            try retained.append(PowerFunctionReceipt(pin:pin,line:sample.origin.functionLine,byteOffset:sample.origin.functionByteOffset,value:sample.result), to: &functions)
        }
        var result = NormalPowerReceipt(instance:instance,cell:cell,cornerID:cornerID,library:library,
            assumptions:consumed,functions:functions,checked:checked)
        result.transformRetention = try retained.finish()
        return result
    }

    /// Evaluates original next-state logic. The caller supplies every referenced state/input value.
    static func evaluateNextState(plan: Plan, inputs: [String: Bool], states: [String: Bool],
                                  powerValues: [String: Bool] = [:],
                                  work: inout UInt64, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                                  sourceResources: (any LibertySourceResourceAccounting)? = nil) throws -> [String: Bool] {
        guard let declaration = plan.declaration, let data = plan.bindings.first(where: { $0.role == .data }) else {
            throw Failure.unsupported("Legacy scalar models do not define source next-state logic")
        }
        let supplied = inputs.count + states.count + powerValues.count
        try stateBudget.reserve(supplied + 2)
        let checks = UInt64(supplied + plan.bindings.count).multipliedReportingOverflow(
            by: UInt64(plan.inputPinNames.count + plan.powerPinNames.count + declaration.variables.count + 1))
        guard !checks.overflow else { throw Failure.nonfinite("Sequential compartment work") }
        try charge(checks.partialValue, work: &work, limits: limits, sourceResources: sourceResources)
        guard inputs.keys.allSatisfy({ plan.inputPinNames.contains($0) }),
              states.keys.allSatisfy({ declaration.variables.contains($0) }),
              powerValues.keys.allSatisfy({ plan.powerPinNames.contains($0) }) else {
            throw Failure.inconsistent("Sequential input/state/PG compartment")
        }
        func execute(_ binding: TimingSequentialFunctionBinding) throws -> Bool {
            try charge(UInt64(binding.symbols.count), work: &work, limits: limits, sourceResources: sourceResources)
            try stateBudget.reserve(binding.symbols.count)
            var values: [String: Bool] = [:]
            for symbol in binding.symbols {
                let name: String, value: Bool?
                switch symbol {
                case .inputPin(let pin): name = pin; value = inputs[pin]
                case .stateVariable(let state): name = state; value = states[state]
                case .powerPin(let pin): name = pin; value = powerValues[pin]
                }
                guard let value else { throw Failure.missing("Explicit value in original symbol compartment: " + name) }
                values[name] = value
            }
            return try evaluate(binding.function, values: values, work: &work, limits: limits,
                                stateBudget: stateBudget, sourceResources: sourceResources)
        }
        var next = try execute(data)
        var clear = false, preset = false
        if declaration.clear != nil {
            guard let binding = plan.bindings.first(where: { $0.role == .clear }) else { throw Failure.missing("Clear binding") }
            clear = try execute(binding)
        }
        if declaration.preset != nil {
            guard let binding = plan.bindings.first(where: { $0.role == .preset }) else { throw Failure.missing("Preset binding") }
            preset = try execute(binding)
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Simultaneous clear/preset state-table actions are not
        // executed by the initial native profile. Source execution must fail until those actions
        // and unknown state semantics have dedicated behavioral coverage.
        guard !(clear && preset) else { throw Failure.unsupported("Simultaneous clear/preset state-table semantics") }
        if clear { next = false }
        if preset { next = true }
        return [declaration.variables[0]: next, declaration.variables[1]: !next]
    }

    static func requiredChecks(plan: Plan, pin: String, edge: TimingEdge,
                               work: inout UInt64, limits: STAExecutionLimits,
                               sourceResources: (any LibertySourceResourceAccounting)? = nil) throws -> [TimingCheckArc] {
        try charge(UInt64(plan.checks.count * 4 + plan.dataPins.count + plan.controlPins.count), work: &work, limits: limits, sourceResources: sourceResources)
        var kinds: [TimingCheckArc.Kind] = []
        if plan.dataPins.contains(pin) { kinds.append(contentsOf: [.setup, .hold]) }
        if plan.controlPins.contains(pin) { kinds.append(contentsOf: [.recovery, .removal]) }
        guard !kinds.isEmpty else { throw Failure.inconsistent("Pin is not a referenced sequential input") }
        let related = plan.closeEdge ?? plan.activeEdge
        var result: [TimingCheckArc] = []
        for kind in kinds {
            let matches = plan.checks.filter { $0.kind == kind && $0.constrainedPin == pin
                && $0.constrainedEdge == edge && $0.relatedPin == plan.clockPin && $0.relatedEdge == related }
            guard matches.count == 1, let check = matches.first,
                  plan.kind == .legacyFlipFlop || check.sourceIdentity != nil else {
                throw Failure.missing("Unique positioned sequential check for referenced input")
            }
            result.append(check)
        }
        return result
    }

    private static func unary(_ binding: TimingSequentialFunctionBinding, state: Bool) throws -> (name: String, inverted: Bool) {
        guard binding.symbols.count == 1, case .normalized(let facts) = binding.function.content else {
            throw Failure.unsupported("Unary physical clock or state output required")
        }
        let name: String
        switch binding.symbols[0] {
        case .inputPin(let pin) where !state: name = pin
        case .stateVariable(let variable) where state: name = variable
        default: throw Failure.unsupported("Clock/output symbol role")
        }
        if facts.operations.count == 1, facts.output.rawValue == 0, case .input(0) = facts.operations[0] {
            return (name, false)
        }
        if facts.operations.count == 2, facts.output.rawValue == 1, case .input(0) = facts.operations[0],
           case .invert(let node) = facts.operations[1], node.rawValue == 0 { return (name, true) }
        throw Failure.unsupported("Compound clock or state output function")
    }

    private static func validateBinding(_ binding: TimingSequentialFunctionBinding, source: LibertySourceCell,
                                        declaration: LibertySourceSequential) throws {
        let original: LibertySourceFunction?
        switch binding.role {
        case .data: original = declaration.data
        case .control: original = declaration.control
        case .additionalControl: original = declaration.additionalControl
        case .powerDown: original = declaration.powerDownFunction
        case .clear: original = declaration.clear
        case .preset: original = declaration.preset
        case .output(let pin): original = source.pins.first { $0.name == pin }?.function
        case .outputState(let pin): original = source.pins.first { $0.name == pin }?.stateFunction
        case .threeState(let pin): original = source.pins.first { $0.name == pin }?.threeState
        case .xFunction(let pin): original = source.pins.first { $0.name == pin }?.xFunction
        case .outputPowerDown(let pin): original = source.pins.first { $0.name == pin }?.powerDownFunction
        }
        guard original == binding.function, case .normalized(let facts) = binding.function.content,
              facts.symbols.count == binding.symbols.count else { throw Failure.inconsistent("Original sequential function binding") }
        for index in binding.symbols.indices {
            let name: String
            switch binding.symbols[index] {
            case .inputPin(let pin):
                guard source.pins.contains(where: { $0.name == pin && $0.direction == .input }) else {
                    throw Failure.inconsistent("Original input symbol")
                }
                name = pin
            case .stateVariable(let variable):
                guard declaration.variables.contains(variable) else { throw Failure.inconsistent("Original state symbol") }
                name = variable
            case .powerPin(let pin):
                guard source.powerPins.contains(where: { $0.name == pin }) else { throw Failure.inconsistent("Original supply symbol") }
                name = pin
            }
            guard facts.symbols[index] == name else { throw Failure.inconsistent("Ordered source symbol slots") }
        }
    }

    private static func evaluate(_ function: LibertySourceFunction, values: [String: Bool],
                                 work: inout UInt64, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                                 sourceResources: (any LibertySourceResourceAccounting)?) throws -> Bool {
        guard case .normalized(let facts) = function.content else { throw Failure.unsupported("Unnormalized Boolean function") }
        let diagnostics = try stateBudget.transformResources.map {
            try TimingControlledDiagnostics(resources: $0, retaining: function)
        }
        for symbol in facts.symbols {
            try stateBudget.chargeScheduledWork(1)
            if values[symbol] == nil {
                throw try NativeSTATransformStorage.sourceFailure(diagnostics: diagnostics,
                    "Explicit Boolean value for ", symbol) { Failure.missing($0) }
            }
        }
        let result = try evaluateTruth(function, value: { slot in values[facts.symbols[slot]]! ? .one : .zero },
            work: &work, limits: limits, stateBudget: stateBudget, sourceResources: sourceResources)
        switch result {
        case .zero: return false
        case .one: return true
        case .unknown, .highImpedance: throw Failure.inconsistent("Complete Boolean source produced unknown truth")
        }
    }

    // Slot meaning stays here; the mechanical Boolean loop is shared with the source owner.
    static func evaluateTruth(_ function: LibertySourceFunction, value: (Int) -> LogicBit,
                              work: inout UInt64, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                              sourceResources: (any LibertySourceResourceAccounting)?) throws -> LogicBit {
        var nodesLease: LibertySourceStorageReservation?
        defer { withExtendedLifetime(nodesLease) {} }
        do {
            return try LibertySourceBooleanEvaluation.evaluate(function,value:value,admit:{ amount,slots in
                try charge(amount,work:&work,limits:limits,sourceResources:sourceResources)
                try stateBudget.reserve(slots)
                nodesLease = try stateBudget.reservePayload(LogicBit.self, capacity: slots, kind: .temporaryBytes)
            },checkpoint:{ try Task.checkCancellation(); try sourceResources?.check() })
        } catch let error as LibertySourceBooleanEvaluation.Failure {
            switch error {
            case .unsupported: throw Failure.unsupported("Unnormalized Boolean function")
            case .invalidProgram: throw Failure.inconsistent("Invalid Boolean source program")
            }
        }
    }

    static func charge(_ amount: UInt64, work: inout UInt64, limits: STAExecutionLimits,
                       sourceResources: (any LibertySourceResourceAccounting)?) throws {
        try Task.checkCancellation()
        try sourceResources?.check()
        let next = work.addingReportingOverflow(amount)
        guard !next.overflow, next.partialValue <= limits.maximumPathWorkUnits else {
            throw STAPathAnalysisError.capacity(resource: "path work units", limit: limits.maximumPathWorkUnits)
        }
        try sourceResources?.chargeWork(amount)
        work = next.partialValue
    }
}

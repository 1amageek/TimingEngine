import LogicIR
import TimingCore

extension NativeSTASequentialExecution {
    static func constantOutput(_ function: LibertySourceFunction, inputs: [String: TimingDesign.Constant],
                               work: inout UInt64, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                               sourceResources: (any LibertySourceResourceAccounting)?) throws -> TimingDesign.Constant? {
        guard case .normalized(let facts) = function.content else { throw Failure.unsupported("Unnormalized static output function") }
        let value = try evaluateTruth(function, value: { slot in
            inputs[facts.symbols[slot]].map { $0 == .one ? .one : .zero } ?? .unknown
        }, work: &work, limits: limits, stateBudget: stateBudget, sourceResources: sourceResources)
        switch value {
        case .zero: return .zero
        case .one: return .one
        case .unknown, .highImpedance: return nil
        }
    }
    struct StaticControls {
        var transformRetention: NativeSTATransformRetention? = nil
        enum Effect { case inactive, clear, preset, unknown }
        let effect: Effect
        let clear: Bool?
        let preset: Bool?
        let outputs: [String: TimingDesign.Constant]
    }

    static func staticControls(plan: Plan, inputs: [String: TimingDesign.Constant],
                               powerValues: [String: TimingDesign.Constant], work: inout UInt64,
                               limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                               sourceResources: (any LibertySourceResourceAccounting)?) throws -> StaticControls {
        guard let declaration = plan.declaration else {
            return .init(effect: .inactive, clear: nil, preset: nil, outputs: [:])
        }
        try charge(UInt64(inputs.count + powerValues.count + plan.bindings.count + plan.outputs.count),
            work: &work, limits: limits, sourceResources: sourceResources)
        try stateBudget.reserve(plan.outputs.count)
        guard inputs.keys.allSatisfy({ plan.inputPinNames.contains($0) }),
              powerValues.keys.allSatisfy({ plan.powerPinNames.contains($0) }) else {
            throw Failure.inconsistent("Static control source compartment")
        }
        func truth(_ role: TimingSequentialFunctionBinding.Role) throws -> LogicBit {
            guard let binding = plan.bindings.first(where: { $0.role == role }) else { return .zero }
            return try evaluateTruth(binding.function, value: { slot in
                switch binding.symbols[slot] {
                case .inputPin(let pin): return inputs[pin].map { $0 == .one ? .one : .zero } ?? .unknown
                case .powerPin(let pin): return powerValues[pin].map { $0 == .one ? .one : .zero } ?? .unknown
                case .stateVariable: return .unknown
                }
            }, work: &work, limits: limits, stateBudget: stateBudget, sourceResources: sourceResources)
        }
        let clear = try truth(.clear), preset = try truth(.preset)
        guard !(clear == .one && preset == .one) else { throw Failure.unsupported("Simultaneous clear/preset static state actions") }
        func binary(_ bit: LogicBit) -> Bool? { bit == .zero ? false : bit == .one ? true : nil }
        let effect: StaticControls.Effect
        let state: Bool?
        if clear == .one && preset == .zero { effect = .clear; state = false }
        else if preset == .one && clear == .zero { effect = .preset; state = true }
        else if clear == .zero && preset == .zero { effect = .inactive; state = nil }
        else { effect = .unknown; state = nil }
        let retained = NativeSTATransformStorage(budget: stateBudget, kind: .liveOwnedBytes)
        try retained.reserveDictionary(String.self, TimingDesign.Constant.self, capacity: plan.outputs.count)
        var outputs: [String: TimingDesign.Constant] = [:]; outputs.reserveCapacity(plan.outputs.count)
        if let state {
            for output in plan.outputs {
                guard let variable = output.stateVariable, let index = declaration.variables.firstIndex(of: variable), index < 2 else {
                    throw Failure.inconsistent("Static source state output binding")
                }
                let value = (index == 0 ? state : !state) != output.inverted
                outputs[output.pin] = value ? .one : .zero
            }
        }
        var result = StaticControls(effect: effect, clear: binary(clear), preset: binary(preset), outputs: outputs)
        result.transformRetention = try retained.finish()
        return result
    }
}

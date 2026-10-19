import LogicIR

/// Mechanical normalized source evaluation; callers own slot meaning and execution policy.
package enum LibertySourceBooleanEvaluation {
    package enum Failure: Error { case unsupported, invalidProgram }

    package static func evaluate(_ function: LibertySourceFunction, value: (Int) throws -> LogicBit,
                                 admit: (UInt64, Int) throws -> Void, checkpoint: () throws -> Void) throws -> LogicBit {
        guard case .normalized(let facts) = function.content else { throw Failure.unsupported }
        let work = facts.operations.count.addingReportingOverflow(facts.symbols.count)
        guard !work.overflow else { throw Failure.invalidProgram }
        try admit(UInt64(work.partialValue),facts.operations.count)
        var nodes: [LogicBit] = []; nodes.reserveCapacity(facts.operations.count)
        func prior(_ node: LogicBooleanNodeIndex) throws -> LogicBit {
            guard nodes.indices.contains(node.rawValue) else { throw Failure.invalidProgram }
            return nodes[node.rawValue]
        }
        for operation in facts.operations {
            try checkpoint()
            let result: LogicBit
            switch operation {
            case .constant(let bit): result = bit ? .one : .zero
            case .input(let slot):
                guard facts.symbols.indices.contains(slot) else { throw Failure.invalidProgram }
                result = try value(slot)
            case .invert(let a): result = try prior(a).inverted
            case .and(let a, let b): result = try prior(a).and(prior(b))
            case .or(let a, let b): result = try prior(a).or(prior(b))
            case .xor(let a, let b): result = try prior(a).xor(prior(b))
            }
            nodes.append(result)
        }
        guard nodes.indices.contains(facts.output.rawValue) else { throw Failure.invalidProgram }
        return nodes[facts.output.rawValue]
    }
}

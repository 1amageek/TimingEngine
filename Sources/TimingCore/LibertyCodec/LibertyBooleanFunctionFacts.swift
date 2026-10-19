import LogicIR

/// Normalized source syntax; named slots still require exact cell pin/state binding.
public struct LibertyBooleanFunctionFacts: Sendable, Hashable, Codable {
    public let symbols: [String]
    public let operations: [LogicBooleanOperation]
    public let output: LogicBooleanNodeIndex

    internal init(symbols: [String], operations: [LogicBooleanOperation], output: LogicBooleanNodeIndex) {
        self.symbols = symbols; self.operations = operations; self.output = output
    }

    private enum CodingKeys: String, CodingKey { case symbols, operations, output }
    private enum Operation: Codable {
        case constant(Bool), input(Int), invert(Int), and(Int, Int), or(Int, Int), xor(Int, Int)
    }

    /// Transport validation does not grant owned-source or characterized eligibility.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let symbols = try container.decode([String].self, forKey: .symbols)
        let encoded = try container.decode([Operation].self, forKey: .operations)
        let output = try container.decode(Int.self, forKey: .output)
        guard Set(symbols).count == symbols.count, symbols.allSatisfy({ !$0.isEmpty }),
              encoded.indices.contains(output) else {
            throw DecodingError.dataCorruptedError(forKey: .operations, in: container, debugDescription: "Invalid Boolean program domain")
        }
        var operations: [LogicBooleanOperation] = []
        operations.reserveCapacity(encoded.count)
        for operation in encoded {
            func prior(_ index: Int) throws -> LogicBooleanNodeIndex {
                guard operations.indices.contains(index) else {
                    throw DecodingError.dataCorruptedError(forKey: .operations, in: container, debugDescription: "Boolean operands must refer to prior nodes")
                }
                return .init(index)
            }
            switch operation {
            case .constant(let value): operations.append(.constant(value))
            case .input(let slot):
                guard symbols.indices.contains(slot) else {
                    throw DecodingError.dataCorruptedError(forKey: .operations, in: container, debugDescription: "Invalid Boolean input slot")
                }
                operations.append(.input(slot))
            case .invert(let a): operations.append(.invert(try prior(a)))
            case .and(let a, let b): operations.append(.and(try prior(a), try prior(b)))
            case .or(let a, let b): operations.append(.or(try prior(a), try prior(b)))
            case .xor(let a, let b): operations.append(.xor(try prior(a), try prior(b)))
            }
        }
        self.init(symbols: symbols, operations: operations, output: .init(output))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(symbols, forKey: .symbols)
        let encoded: [Operation] = operations.map { operation in
            switch operation {
            case .constant(let value): return .constant(value)
            case .input(let slot): return .input(slot)
            case .invert(let a): return .invert(a.rawValue)
            case .and(let a, let b): return .and(a.rawValue, b.rawValue)
            case .or(let a, let b): return .or(a.rawValue, b.rawValue)
            case .xor(let a, let b): return .xor(a.rawValue, b.rawValue)
            }
        }
        try container.encode(encoded, forKey: .operations)
        try container.encode(output.rawValue, forKey: .output)
    }
}

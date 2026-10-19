import LogicIR

/// One source normalizer; owned intake supplies its shared accountant and nesting bound.
struct LibertyBooleanNormalizer: ~Copyable {
    private enum Operator: Sendable {
        case invert, xor, and, or, parenthesis
        var precedence: Int {
            switch self { case .invert: 4; case .xor: 3; case .and: 2; case .or: 1; case .parenthesis: 0 }
        }
    }
    private let storage: LibertyParseStorage?
    private let maximumNesting: Int?
    private var symbols = LibertyBuffer<String>()
    private var operations = LibertyBuffer<LogicBooleanOperation>()
    private var values = LibertyBuffer<LogicBooleanNodeIndex>()
    private var operators = LibertyBuffer<Operator>()
    private var nesting = 0

    static func normalize(_ node: LibertyNode, storage: LibertyParseStorage?, maximumNesting: Int?)
        throws -> LibertySourceFunction {
        let content: LibertySourceFunction.Content
        do {
            guard let expression = node.value else { throw LibertyBooleanFunctionIssue.malformedExpression }
            var parser = LibertyBooleanNormalizer(storage: storage, maximumNesting: maximumNesting)
            content = .normalized(try parser.parse(expression))
        } catch let issue as LibertyBooleanFunctionIssue { content = .unsupported(issue) }
        // Resource, deadline, cancellation and nesting failures remain invocation failures.
        return .init(content: content, line: node.sourceLine, byteOffset: node.byteOffset)
    }

    private mutating func parse(_ source: String) throws -> LibertyBooleanFunctionFacts {
        let bytes = source.utf8
        var cursor = bytes.startIndex
        var expectingOperand = true
        while cursor != bytes.endIndex {
            try storage?.step()
            var separated = false
            while cursor != bytes.endIndex && Self.isWhitespace(bytes[cursor]) {
                try storage?.step(); separated = true; bytes.formIndex(after: &cursor)
            }
            guard cursor != bytes.endIndex else { break }
            let byte = bytes[cursor]
            if Self.isIdentifierStart(byte) || byte == 48 || byte == 49 || byte == 40 || byte == 33 {
                if !expectingOperand {
                    guard separated else { throw LibertyBooleanFunctionIssue.malformedExpression }
                    try pushBinary(.and)
                }
                if byte == 40 || byte == 33 {
                    if let maximumNesting, nesting >= maximumNesting { throw LibertySourceError.nestingLimit(maximum: maximumNesting) }
                    nesting += 1
                    try operators.append(byte == 40 ? .parenthesis : .invert, storage: storage)
                    bytes.formIndex(after: &cursor); expectingOperand = true; continue
                }
                if byte == 48 || byte == 49 {
                    bytes.formIndex(after: &cursor)
                    if cursor != bytes.endIndex && Self.isIdentifierContinuation(bytes[cursor]) {
                        throw LibertyBooleanFunctionIssue.unsupportedIdentifier
                    }
                    try emit(.constant(byte == 49))
                } else {
                    var text = LibertyText()
                    while cursor != bytes.endIndex && Self.isIdentifierContinuation(bytes[cursor]) {
                        try storage?.step()
                        try text.append(Character(UnicodeScalar(bytes[cursor])), storage: storage)
                        bytes.formIndex(after: &cursor)
                    }
                    let symbol = try text.string(storage: storage)
                    var slot: Int?
                    for index in symbols.indices {
                        for _ in symbols[index].utf8 { try storage?.step() }
                        for _ in symbol.utf8 { try storage?.step() }
                        if symbols[index] == symbol { slot = index; break }
                    }
                    if slot == nil { slot = symbols.count; try symbols.append(symbol, storage: storage) }
                    try emit(.input(slot!))
                }
                expectingOperand = false
                try reducePrefixes()
            } else if byte == 39 {
                guard !expectingOperand, let value = values.last else { throw LibertyBooleanFunctionIssue.malformedExpression }
                _ = values.removeLast(); try emit(.invert(value))
                bytes.formIndex(after: &cursor)
            } else if byte == 41 {
                guard !expectingOperand else { throw LibertyBooleanFunctionIssue.malformedExpression }
                while let top = operators.last, top != .parenthesis { try reduce() }
                guard operators.last == .parenthesis else { throw LibertyBooleanFunctionIssue.malformedExpression }
                _ = operators.removeLast(); nesting -= 1
                try reducePrefixes(); bytes.formIndex(after: &cursor)
            } else {
                let operation: Operator
                switch byte {
                case 94: operation = .xor
                case 42, 38: operation = .and
                case 43, 124: operation = .or
                default: throw LibertyBooleanFunctionIssue.unsupportedSyntax
                }
                guard !expectingOperand else { throw LibertyBooleanFunctionIssue.malformedExpression }
                try pushBinary(operation); expectingOperand = true; bytes.formIndex(after: &cursor)
            }
        }
        guard !expectingOperand else { throw LibertyBooleanFunctionIssue.malformedExpression }
        while let top = operators.last {
            guard top != .parenthesis else { throw LibertyBooleanFunctionIssue.malformedExpression }
            try reduce()
        }
        guard values.count == 1 else { throw LibertyBooleanFunctionIssue.malformedExpression }
        return .init(symbols: try symbols.array(storage: storage),
                     operations: try operations.array(storage: storage), output: values[0])
    }

    private mutating func emit(_ operation: LogicBooleanOperation) throws {
        let index = LogicBooleanNodeIndex(operations.count)
        try operations.append(operation, storage: storage)
        try values.append(index, storage: storage)
    }
    private mutating func pushBinary(_ operation: Operator) throws {
        while let top = operators.last, top != .parenthesis, top.precedence >= operation.precedence { try reduce() }
        try operators.append(operation, storage: storage)
    }
    private mutating func reducePrefixes() throws {
        while operators.last == .invert { try reduce() }
    }
    private mutating func reduce() throws {
        try storage?.step()
        guard let operation = operators.last, let right = values.last else {
            throw LibertyBooleanFunctionIssue.malformedExpression
        }
        _ = operators.removeLast(); _ = values.removeLast()
        if operation == .invert {
            nesting -= 1; try emit(.invert(right)); return
        }
        guard let left = values.last else { throw LibertyBooleanFunctionIssue.malformedExpression }
        _ = values.removeLast()
        switch operation {
        case .xor: try emit(.xor(left, right))
        case .and: try emit(.and(left, right))
        case .or: try emit(.or(left, right))
        case .invert, .parenthesis: throw LibertyBooleanFunctionIssue.malformedExpression
        }
    }
    private static func isWhitespace(_ byte: UInt8) -> Bool { byte == 32 || (9...13).contains(byte) }
    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
    }
    private static func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (48...57).contains(byte)
    }
}

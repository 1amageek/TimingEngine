import Foundation

/// The shared legacy byte grammar, with caller-accounted owned construction.
struct LibertyGrammar {
    private enum Token: Sendable {
        case word(String)
        case quoted(String)
        case symbol(Character)
        case end
    }

    private struct LocatedToken: Sendable {
        let token: Token
        let line: Int
        let sourceLine: Int
        let byteOffset: Int
    }

    private struct GroupFrame: Sendable {
        let name: String
        let arguments: [String]
        let line: Int
        let sourceLine: Int
        let byteOffset: Int
        var children = LibertyBuffer<LibertyNode>()
    }

    private let storage: LibertyParseStorage?
    private let maximumNestingDepth: Int?
    private var tokens = LibertyBuffer<LocatedToken>()
    private var index = 0

    init(source: String, storage: LibertyParseStorage? = nil,
         maximumNestingDepth: Int? = nil) throws {
        if let maximumNestingDepth, maximumNestingDepth <= 0 { throw LibertySourceError.invalidLimit }
        if storage != nil, maximumNestingDepth == nil { throw LibertySourceError.invalidLimit }
        self.storage = storage
        self.maximumNestingDepth = maximumNestingDepth
        try tokenize(source)
    }

    mutating func parse() throws -> [LibertyNode] {
        var result = LibertyBuffer<LibertyNode>()
        var frames = LibertyBuffer<GroupFrame>()
        while true {
            try storage?.step()
            if case .end = try peek() {
                guard frames.isEmpty else { throw error("Missing closing '}'.") }
                return try result.array(storage: storage, kind: .temporaryBytes)
            }
            if !frames.isEmpty, try isSymbol("}") {
                _ = try advance()
                try storage?.step()
                let frame = frames.removeLast()
                let children = try frame.children.array(storage: storage, kind: .temporaryBytes)
                let node = LibertyNode(name: frame.name, arguments: frame.arguments, value: nil,
                    children: children, line: frame.line, sourceLine: frame.sourceLine, byteOffset: frame.byteOffset)
                try append(node, to: &result, frames: &frames)
                continue
            }
            let byteOffset = tokens[index].byteOffset
            let sourceLine = tokens[index].sourceLine
            guard case .word(let name) = try advance() else {
                throw error("Expected a Liberty group or attribute.")
            }
            // Preserve the ordinary grammar's next-token line convention.
            let line = currentLine()
            var arguments: [String] = []
            if try isSymbol("(") { arguments = try parseArguments() }
            if try isSymbol(":") {
                _ = try advance()
                let value = try parseAttributeValue()
                let node = LibertyNode(name: name, arguments: arguments, value: value,
                    children: [], line: line, sourceLine: sourceLine, byteOffset: byteOffset)
                try append(node, to: &result, frames: &frames)
            } else if try isSymbol("{") {
                if let maximumNestingDepth, frames.count >= maximumNestingDepth {
                    throw LibertySourceError.nestingLimit(maximum: maximumNestingDepth)
                }
                _ = try advance()
                try frames.append(GroupFrame(name: name, arguments: arguments,
                    line: line, sourceLine: sourceLine, byteOffset: byteOffset), storage: storage)
            } else if try isSymbol(";") {
                _ = try advance()
                let node = LibertyNode(name: name, arguments: arguments, value: nil,
                    children: [], line: line, sourceLine: sourceLine, byteOffset: byteOffset)
                try append(node, to: &result, frames: &frames)
            } else if storage != nil {
                throw error("Expected a statement delimiter.")
            } else {
                throw error("Expected ':', '{' or ';' after '\(name)'.")
            }
        }
    }

    private func append(_ node: LibertyNode, to result: inout LibertyBuffer<LibertyNode>,
                        frames: inout LibertyBuffer<GroupFrame>) throws {
        if frames.isEmpty {
            try result.append(node, storage: storage)
        } else {
            try storage?.step()
            // Remove the owning frame before mutating its child buffer; no shared builder snapshot remains.
            var frame = frames.removeLast()
            try frame.children.append(node, storage: storage)
            try frames.append(frame, storage: storage)
        }
    }

    private mutating func parseArguments() throws -> [String] {
        _ = try advance()
        var values = LibertyBuffer<String>()
        var current = LibertyText()
        while true {
            switch try advance() {
            case .symbol(")"):
                let value = try current.string(storage: storage, kind: .temporaryBytes)
                if !(try trimmedIsEmpty(value)) {
                    try values.append(current.string(storage: storage), storage: storage)
                }
                return try values.array(storage: storage, kind: .temporaryBytes)
            case .symbol(","):
                let value = try current.string(storage: storage, kind: .temporaryBytes)
                try values.append(trimmed(value), storage: storage)
                current = LibertyText()
            case .word(let value), .quoted(let value):
                if !current.isEmpty { try current.append(" ", storage: storage) }
                try current.append(value, storage: storage)
            case .symbol(let symbol):
                try current.append(symbol, storage: storage)
            case .end:
                throw error("Unterminated argument list.")
            }
        }
    }

    private mutating func parseAttributeValue() throws -> String {
        var value = LibertyText()
        while true {
            switch try advance() {
            case .symbol(";"):
                return try trimmed(value.string(storage: storage, kind: .temporaryBytes))
            case .word(let item), .quoted(let item):
                if !value.isEmpty { try value.append(" ", storage: storage) }
                try value.append(item, storage: storage)
            case .symbol(let symbol):
                try value.append(symbol, storage: storage)
            case .end:
                throw error("Unterminated attribute value.")
            }
        }
    }

    private func trimmedIsEmpty(_ value: String) throws -> Bool {
        guard let storage else { return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for byte in value.utf8 {
            try storage.step()
            if !Self.isTrimWhitespace(byte) { return false }
        }
        return true
    }

    private func trimmed(_ value: String) throws -> String {
        guard let storage else { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let bytes = value.utf8
        var start = bytes.startIndex
        var end = bytes.endIndex
        while start < end {
            try storage.step()
            guard Self.isTrimWhitespace(bytes[start]) else { break }
            bytes.formIndex(after: &start)
        }
        while start < end {
            try storage.step()
            let previous = bytes.index(before: end)
            guard Self.isTrimWhitespace(bytes[previous]) else { break }
            end = previous
        }
        var count = 0
        for _ in bytes[start..<end] { try storage.step(); count = try LibertyParseStorage.add(count, 1) }
        let receipt = try storage.reserve(UInt8.self, capacity: count)
        try storage.step(UInt64(count))
        let output = String(decoding: bytes[start..<end], as: UTF8.self)
        try storage.hold(output, receipt: receipt)
        try storage.resources.check()
        return output
    }

    private static func isTrimWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || (9...13).contains(byte)
    }

    private func peek() throws -> Token {
        try storage?.step()
        return tokens[index].token
    }

    private func isSymbol(_ symbol: Character) throws -> Bool {
        if case .symbol(let value) = try peek() { return value == symbol }
        return false
    }

    private mutating func advance() throws -> Token {
        try storage?.step()
        let token = tokens[index].token
        index += 1
        return token
    }

    private func currentLine() -> Int { tokens[Swift.min(index, tokens.count - 1)].line }

    private func error(_ message: String) -> any Error {
        if storage != nil { return LibertySourceError.syntax(line: tokens[Swift.min(index, tokens.count - 1)].sourceLine) }
        return TimingError.parseFailure(format: "Liberty", line: currentLine(), message: message)
    }

    private func lexicalError(line: Int, sourceLine: Int, message: String) -> any Error {
        if storage != nil { return LibertySourceError.syntax(line: sourceLine) }
        return TimingError.parseFailure(format: "Liberty", line: line, message: message)
    }

    private func continuationLength(in bytes: borrowing [UInt8], at cursor: Int) throws -> Int {
        guard try read(bytes, at: cursor) == 92, cursor + 1 < bytes.count else { return 0 }
        let next = try read(bytes, at: cursor + 1)
        if next == 10 { return 2 }
        if next == 13, cursor + 2 < bytes.count {
            if try read(bytes, at: cursor + 2) == 10 { return 3 }
        }
        return 0
    }

    private func read(_ bytes: borrowing [UInt8], at cursor: Int) throws -> UInt8 {
        try storage?.step()
        return bytes[cursor]
    }

    private mutating func tokenize(_ source: String) throws {
        var count = 0
        for _ in source.utf8 { try storage?.step(); count = try LibertyParseStorage.add(count, 1) }
        let receipt = try storage?.reserve(UInt8.self, capacity: count, kind: .temporaryBytes)
        try storage?.step(UInt64(count))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for byte in source.utf8 { try storage?.step(); bytes.append(byte) }
        if let storage, let receipt { try storage.hold(bytes, receipt: receipt, kind: .temporaryBytes) }
        var cursor = 0
        var line = 1
        var physicalLine = 1
        while cursor < bytes.count {
            let byte = try read(bytes, at: cursor)
            let continuation = try continuationLength(in: bytes, at: cursor)
            if continuation > 0 { line += 1; physicalLine += 1; cursor += continuation; continue }
            if byte == 10 { line += 1; physicalLine += 1; cursor += 1; continue }
            if byte == 13 || byte == 32 || byte == 9 { cursor += 1; continue }
            let next = byte == 47 && cursor + 1 < bytes.count ? try read(bytes, at: cursor + 1) : nil
            if byte == 47, next == 47 {
                cursor += 2
                while cursor < bytes.count {
                    if try read(bytes, at: cursor) == 10 { break }
                    cursor += 1
                }
                continue
            }
            if byte == 47, next == 42 {
                cursor += 2
                while cursor + 1 < bytes.count {
                    let current = try read(bytes, at: cursor)
                    if current == 42, try read(bytes, at: cursor + 1) == 47 { break }
                    if current == 10 { line += 1; physicalLine += 1 }
                    cursor += 1
                }
                guard cursor + 1 < bytes.count else {
                    throw lexicalError(line: line, sourceLine: physicalLine, message: "Unterminated comment.")
                }
                cursor += 2
                continue
            }
            let byteOffset = cursor
            let sourceLine = physicalLine
            if byte == 34 {
                cursor += 1
                var value = LibertyText()
                while cursor < bytes.count {
                    let current = try read(bytes, at: cursor)
                    if current == 34 { break }
                    let continuation = try continuationLength(in: bytes, at: cursor)
                    if continuation > 0 { line += 1; physicalLine += 1; cursor += continuation; continue }
                    if current == 92, cursor + 1 < bytes.count { cursor += 1 }
                    let unescaped = current == 92 ? try read(bytes, at: cursor) : current
                    if unescaped == 10 { physicalLine += 1 }
                    try value.append(Character(UnicodeScalar(unescaped)), storage: storage)
                    cursor += 1
                }
                guard cursor < bytes.count else {
                    throw lexicalError(line: line, sourceLine: physicalLine, message: "Unterminated string.")
                }
                cursor += 1
                let token = Token.quoted(try value.string(storage: storage))
                try tokens.append(LocatedToken(token: token, line: line, sourceLine: sourceLine, byteOffset: byteOffset), storage: storage)
                continue
            }
            if Self.isSymbolByte(byte) {
                let token = Token.symbol(Character(UnicodeScalar(byte)))
                try tokens.append(LocatedToken(token: token, line: line, sourceLine: sourceLine, byteOffset: byteOffset), storage: storage)
                cursor += 1
                continue
            }
            var value = LibertyText()
            while cursor < bytes.count {
                let current = try read(bytes, at: cursor)
                if try continuationLength(in: bytes, at: cursor) > 0 { break }
                if current == 10 || current == 13 || current == 32 || current == 9
                    || Self.isSymbolByte(current) || current == 34 { break }
                try value.append(Character(UnicodeScalar(current)), storage: storage)
                cursor += 1
            }
            guard !value.isEmpty else { throw lexicalError(line: line, sourceLine: physicalLine, message: "Unexpected byte.") }
            let token = Token.word(try value.string(storage: storage))
            try tokens.append(LocatedToken(token: token, line: line, sourceLine: sourceLine, byteOffset: byteOffset), storage: storage)
        }
        try tokens.append(LocatedToken(token: .end, line: line, sourceLine: physicalLine, byteOffset: bytes.count), storage: storage)
    }

    private static func isSymbolByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 40, 41, 123, 125, 58, 59, 44: true
        default: false
        }
    }
}

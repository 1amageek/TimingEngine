import Foundation

public struct TimingDesignParser: TimingDesignParsing {
    public init() {}

    public func parse(_ data: Data, topDesignName: String) throws -> TimingDesign {
        guard let source = String(data: data, encoding: .utf8) else {
            throw TimingError.parseFailure(format: "design", line: 1, message: "Input is not UTF-8.")
        }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            do {
                let design = try JSONDecoder().decode(TimingDesign.self, from: data)
                guard design.schemaVersion == TimingDesign.currentSchemaVersion else {
                    throw TimingError.invalidInput("Unsupported timing design schema version \(design.schemaVersion).")
                }
                return design
            } catch let error as TimingError {
                throw error
            } catch {
                throw TimingError.parseFailure(format: "design JSON", line: 1, message: error.localizedDescription)
            }
        }
        return try parseVerilog(source, topDesignName: topDesignName)
    }

    public func parse(_ data: Data, topDesignName: String,
        resources: any LibertySourceResourceAccounting, json: any TimingBoundedJSONDecoding)
        throws -> TimingTransformValue<TimingDesign> {
        let transform = try TimingTextTransform(resources: resources)
        do {
            let route = try controlledRoute(data, topDesignName: topDesignName, transform: transform)
            switch route {
            case .json:
                transform.storage.releaseTemporary()
                return try json.decodeDesign(data, resources: resources)
            case .design(let value): return try transform.finish(value)
            }
        } catch let error as TimingControlledTransformFailure { throw error }
        catch { throw transform.failure(error) }
    }

    private enum ControlledRoute { case json; case design(TimingDesign) }

    private func controlledRoute(_ data: Data, topDesignName: String,
        transform: TimingTextTransform) throws -> ControlledRoute {
        let source = try transform.source(data, format: "design")
        let trimmedLease = try transform.storage.reserve(UInt8.self,
            capacity: source.utf8.count, kind: .temporaryBytes)
        try transform.storage.step(UInt64(source.utf8.count))
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        try transform.storage.hold(trimmed, receipt: trimmedLease, kind: .temporaryBytes)
        if trimmed.hasPrefix("{") { return .json }
        return .design(try parseVerilog(source, topDesignName: topDesignName, transform: transform))
    }

    private func parseVerilog(_ source: String, topDesignName: String,
        transform: TimingTextTransform? = nil) throws -> TimingDesign {
        let tokens = try tokenize(removeComments(source, transform: transform), transform: transform)
        let moduleName = try moduleName(from: tokens, transform: transform) ?? topDesignName
        // Every port/instance/net requires at least one original token. These are
        // source-proved requested capacities, not a byte multiplier or RSS claim.
        let portsLease = try transform?.storage.reserve(TimingDesign.Port.self, capacity: tokens.count)
        let instancesLease = try transform?.storage.reserve(TimingDesign.Instance.self, capacity: tokens.count)
        let namesLease = try transform?.reserveSet(String.self, capacity: tokens.count)
        let statementLease = try transform?.storage.reserve(String.self, capacity: tokens.count, kind: .temporaryBytes)
        defer { withExtendedLifetime((namesLease, statementLease)) {} }
        try transform?.storage.step(UInt64(tokens.count))
        var ports: [TimingDesign.Port] = []
        var instances: [TimingDesign.Instance] = []
        var netNames = Set<String>()
        if transform != nil {
            ports.reserveCapacity(tokens.count); instances.reserveCapacity(tokens.count)
            netNames.reserveCapacity(tokens.count)
        }
        try transform?.storage.step(UInt64(tokens.count))
        if let moduleIndex = tokens.firstIndex(of: "module"),
           let open = tokens[(moduleIndex + 1)...].firstIndex(of: "("),
           let close = tokens[(open + 1)...].firstIndex(of: ")") {
            let header: [String]
            if let transform {
                header = try transform.map(tokens[(open + 1)..<close]) { $0 }
            } else { header = Array(tokens[(open + 1)..<close]) }
            try parseANSIHeader(header, ports: &ports, netNames: &netNames, transform: transform)
        }
        var statement: [String] = []
        var line = 1
        if transform != nil { statement.reserveCapacity(tokens.count) }
        for token in tokens {
            try transform?.storage.step(UInt64(token.utf8.count))
            if token == ";" {
                try parseStatement(statement, line: line, ports: &ports, instances: &instances, netNames: &netNames, transform: transform)
                statement.removeAll(keepingCapacity: true)
            } else {
                statement.append(token)
            }
            if let transform {
                for character in token {
                    try transform.storage.step()
                    if character == "\n" { line = try LibertyParseStorage.add(line, 1) }
                }
            } else if token.contains("\n") { line += token.filter { $0 == "\n" }.count }
        }
        if !statement.isEmpty {
            try parseStatement(statement, line: line, ports: &ports, instances: &instances, netNames: &netNames, transform: transform)
        }

        guard !instances.isEmpty else {
            throw TimingError.parseFailure(format: "Verilog", line: 1, message: "No cell instances were found.")
        }
        let nets: [TimingDesign.Net]
        if let transform {
            let names = try transform.sorted(netNames) { left, right in
                try transform.storage.step(UInt64(try LibertyParseStorage.add(left.utf8.count, right.utf8.count)))
                return left < right
            }
            nets = try transform.map(names, kind: .liveOwnedBytes) { TimingDesign.Net(name: $0) }
            if let portsLease { try transform.storage.hold(ports, receipt: portsLease) }
            if let instancesLease { try transform.storage.hold(instances, receipt: instancesLease) }
        } else { nets = netNames.sorted().map { TimingDesign.Net(name: $0) } }
        return TimingDesign(topDesignName: moduleName, ports: ports, instances: instances, nets: nets)
    }

    private func parseANSIHeader(
        _ tokens: [String],
        ports: inout [TimingDesign.Port],
        netNames: inout Set<String>,
        transform: TimingTextTransform? = nil
    ) throws {
        var direction: TimingDesign.Port.Direction?
        let ignoredLease = try transform?.reserveSet(String.self, capacity: 5)
        defer { withExtendedLifetime(ignoredLease) {} }
        try transform?.storage.step(5)
        let ignored = Set(["wire", "logic", "reg", "signed", "unsigned"])
        for token in tokens {
            try transform?.storage.step(UInt64(token.utf8.count))
            switch token {
            case "input": direction = .input
            case "output": direction = .output
            case "inout": direction = .bidirectional
            case ",", "[", "]", ":": break
            default:
                guard let direction, !ignored.contains(token), Int(token) == nil else { continue }
                if try !ports.contains(where: { port in
                    try transform?.storage.step(UInt64(try LibertyParseStorage.add(port.name.utf8.count, token.utf8.count)))
                    return port.name == token
                }) {
                    ports.append(TimingDesign.Port(name: token, direction: direction))
                }
                netNames.insert(token)
            }
        }
    }

    private func parseStatement(
        _ statement: [String],
        line: Int,
        ports: inout [TimingDesign.Port],
        instances: inout [TimingDesign.Instance],
        netNames: inout Set<String>,
        transform: TimingTextTransform? = nil
    ) throws {
        guard let first = statement.first else { return }
        switch first {
        case "module", "endmodule", "wire", "tri", "reg", "logic", "parameter", "localparam", "assign":
            if first == "input" || first == "output" { break }
            if first == "assign" {
                throw TimingError.unsupportedSemantic(format: "Verilog", semantic: "continuous assignment")
            }
            return
        case "input", "output", "inout":
            let direction: TimingDesign.Port.Direction
            switch first {
            case "input": direction = .input
            case "output": direction = .output
            default: direction = .bidirectional
            }
            let names: [String]
            let accepted: (String) -> Bool = { token in
                token != "," && token != "[" && token != "]" && Int(token) == nil && !token.contains(":")
            }
            if let transform { names = try transform.filter(statement.dropFirst(), accepted) }
            else { names = statement.dropFirst().filter(accepted) }
            for name in names where !name.isEmpty {
                try transform?.storage.step(UInt64(name.utf8.count))
                ports.append(TimingDesign.Port(name: name, direction: direction))
                netNames.insert(name)
            }
            return
        default:
            break
        }
        guard statement.count >= 4, let open = statement.firstIndex(of: "(") else { return }
        let cell = statement[0]
        let instanceName = statement[1]
        guard open > 1 else {
            throw TimingError.parseFailure(format: "Verilog", line: line, message: "Cell instance has no instance name.")
        }
        let connectionsLease = try transform?.reserveDictionary(String.self, String.self, capacity: statement.count, kind: .liveOwnedBytes)
        var connections: [String: String] = [:]
        if transform != nil { connections.reserveCapacity(statement.count) }
        var index = open + 1
        while index < statement.count {
            try transform?.storage.step(UInt64(statement[index].utf8.count))
            guard statement[index] == ".", index + 1 < statement.count else {
                index += 1
                continue
            }
            let pin = statement[index + 1]
            index += 2
            guard index < statement.count, statement[index] == "(" else { continue }
            index += 1
            var net = ""
            if let transform {
                let beginning = index
                var count = 0
                while index < statement.count, statement[index] != ")" {
                    try transform.storage.step(UInt64(statement[index].utf8.count))
                    if statement[index] != "," {
                        count = try LibertyParseStorage.add(count, statement[index].utf8.count)
                    }
                    index += 1
                }
                let lease = try transform.storage.reserve(UInt8.self, capacity: count)
                try transform.storage.step(UInt64(count))
                net.reserveCapacity(count)
                for offset in beginning..<index where statement[offset] != "," {
                    try transform.storage.step()
                    net += statement[offset]
                }
                try transform.storage.hold(net, receipt: lease)
            } else {
                while index < statement.count, statement[index] != ")" {
                    if statement[index] != "," { net += statement[index] }
                    index += 1
                }
            }
            if !net.isEmpty {
                connections[pin] = net
                netNames.insert(net)
            }
            index += 1
        }
        guard !connections.isEmpty else {
            if let transform {
                let bytes = try TimingDiagnosticTextCapacity.description(literal: "Cell instance '' has no connections.",
                    ints: 0, doubles: 0, booleans: 0, additionalUTF8: UInt64(instanceName.utf8.count))
                throw try transform.sourceFailure(utf8ByteCount: bytes) {
                    TimingError.parseFailure(format: "Verilog", line: line, message: "Cell instance '\(instanceName)' has no connections.")
                }
            }
            throw TimingError.parseFailure(format: "Verilog", line: line, message: "Cell instance '\(instanceName)' has no connections.")
        }
        if let transform {
            if let connectionsLease { try transform.storage.hold(connections, receipt: connectionsLease) }
        }
        instances.append(TimingDesign.Instance(name: instanceName, cell: cell, connections: connections))
    }

    private func moduleName(from tokens: [String], transform: TimingTextTransform? = nil) throws -> String? {
        try transform?.storage.step(UInt64(tokens.count))
        guard let index = tokens.firstIndex(of: "module"), tokens.index(after: index) < tokens.endIndex else { return nil }
        return tokens[tokens.index(after: index)]
    }

    private func removeComments(_ source: String, transform: TimingTextTransform? = nil) throws -> String {
        let lease = try transform?.storage.reserve(UInt8.self, capacity: source.utf8.count, kind: .temporaryBytes)
        var result = ""
        if transform != nil { result.reserveCapacity(source.utf8.count) }
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            try transform?.storage.step()
            let next = source.index(after: index)
            if !inBlock, source[index] == "/", next < source.endIndex, source[next] == "/" {
                while index < source.endIndex, source[index] != "\n" {
                    try transform?.storage.step(); index = source.index(after: index)
                }
                continue
            }
            if !inBlock, source[index] == "/", next < source.endIndex, source[next] == "*" {
                inBlock = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if inBlock, source[index] == "*", next < source.endIndex, source[next] == "/" {
                inBlock = false
                index = source.index(index, offsetBy: 2)
                continue
            }
            if !inBlock { result.append(source[index]) }
            index = next
        }
        if let transform, let lease { try transform.storage.hold(result, receipt: lease, kind: .temporaryBytes) }
        return result
    }

    private func controlledTokens(_ source: String, transform: TimingTextTransform) throws -> [String] {
        // A token consumes at least one original UTF-8 byte. The explicit
        // requested slot capacity is therefore bounded by this exact source.
        let capacity = source.utf8.count
        let slots = try transform.storage.reserve(String.self, capacity: capacity)
        let punctuationLease = try transform.reserveSet(Character.self, capacity: 8)
        defer { withExtendedLifetime(punctuationLease) {} }
        try transform.storage.step(UInt64(capacity))
        var tokens: [String] = []
        tokens.reserveCapacity(capacity)
        let punctuation: Set<Character> = ["(", ")", ".", ",", ";", "[", "]", ":"]
        var beginning: String.Index?
        func appendToken(_ range: Range<String.Index>) throws {
            guard tokens.count < capacity else { throw LibertySourceError.arithmeticOverflow }
            let token = try transform.text(source[range])
            try transform.storage.step()
            tokens.append(token)
        }
        for index in source.indices {
            let character = source[index]
            try transform.storage.step(UInt64(character.utf8.count))
            if character.isWhitespace || punctuation.contains(character) {
                if let start = beginning { try appendToken(start..<index); beginning = nil }
                if punctuation.contains(character) {
                    try appendToken(index..<source.index(after: index))
                }
            } else if beginning == nil { beginning = index }
        }
        if let start = beginning { try appendToken(start..<source.endIndex) }
        try transform.storage.hold(tokens, receipt: slots)
        return tokens
    }

    private func tokenize(_ source: String, transform: TimingTextTransform? = nil) throws -> [String] {
        if let transform { return try controlledTokens(source, transform: transform) }
        var tokens: [String] = []
        var current = ""
        let punctuation: Set<Character> = ["(", ")", ".", ",", ";", "[", "]", ":"]
        func flush(_ current: inout String, into tokens: inout [String]) {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current = ""
        }
        for character in source {
            if character.isWhitespace {
                flush(&current, into: &tokens)
            } else if punctuation.contains(character) {
                flush(&current, into: &tokens)
                tokens.append(String(character))
            } else {
                current.append(character)
            }
        }
        flush(&current, into: &tokens)
        return tokens
    }
}

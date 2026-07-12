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

    private func parseVerilog(_ source: String, topDesignName: String) throws -> TimingDesign {
        let tokens = tokenize(removeComments(source))
        let moduleName = moduleName(from: tokens) ?? topDesignName
        var ports: [TimingDesign.Port] = []
        var instances: [TimingDesign.Instance] = []
        var netNames = Set<String>()
        if let moduleIndex = tokens.firstIndex(of: "module"),
           let open = tokens[(moduleIndex + 1)...].firstIndex(of: "("),
           let close = tokens[(open + 1)...].firstIndex(of: ")") {
            parseANSIHeader(
                Array(tokens[(open + 1) ..< close]),
                ports: &ports,
                netNames: &netNames
            )
        }
        var statement: [String] = []
        var line = 1

        for token in tokens {
            if token == ";" {
                try parseStatement(statement, line: line, ports: &ports, instances: &instances, netNames: &netNames)
                statement.removeAll(keepingCapacity: true)
            } else {
                statement.append(token)
            }
            if token.contains("\n") { line += token.filter { $0 == "\n" }.count }
        }
        if !statement.isEmpty {
            try parseStatement(statement, line: line, ports: &ports, instances: &instances, netNames: &netNames)
        }

        guard !instances.isEmpty else {
            throw TimingError.parseFailure(format: "Verilog", line: 1, message: "No cell instances were found.")
        }
        let nets = netNames.sorted().map { TimingDesign.Net(name: $0) }
        return TimingDesign(topDesignName: moduleName, ports: ports, instances: instances, nets: nets)
    }

    private func parseANSIHeader(
        _ tokens: [String],
        ports: inout [TimingDesign.Port],
        netNames: inout Set<String>
    ) {
        var direction: TimingDesign.Port.Direction?
        let ignored = Set(["wire", "logic", "reg", "signed", "unsigned"])
        for token in tokens {
            switch token {
            case "input": direction = .input
            case "output": direction = .output
            case "inout": direction = .bidirectional
            case ",", "[", "]", ":": break
            default:
                guard let direction, !ignored.contains(token), Int(token) == nil else { continue }
                if !ports.contains(where: { $0.name == token }) {
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
        netNames: inout Set<String>
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
            let names = statement.dropFirst().filter { token in
                token != "," && token != "[" && token != "]" && Int(token) == nil && !token.contains(":")
            }
            for name in names where !name.isEmpty {
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
        var connections: [String: String] = [:]
        var index = open + 1
        while index < statement.count {
            guard statement[index] == ".", index + 1 < statement.count else {
                index += 1
                continue
            }
            let pin = statement[index + 1]
            index += 2
            guard index < statement.count, statement[index] == "(" else { continue }
            index += 1
            var net = ""
            while index < statement.count, statement[index] != ")" {
                if statement[index] != "," { net += statement[index] }
                index += 1
            }
            if !net.isEmpty {
                connections[pin] = net
                netNames.insert(net)
            }
            index += 1
        }
        guard !connections.isEmpty else {
            throw TimingError.parseFailure(format: "Verilog", line: line, message: "Cell instance '\(instanceName)' has no connections.")
        }
        instances.append(TimingDesign.Instance(name: instanceName, cell: cell, connections: connections))
    }

    private func moduleName(from tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: "module"), tokens.index(after: index) < tokens.endIndex else { return nil }
        return tokens[tokens.index(after: index)]
    }

    private func removeComments(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let next = source.index(after: index)
            if !inBlock, source[index] == "/", next < source.endIndex, source[next] == "/" {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
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
        return result
    }

    private func tokenize(_ source: String) -> [String] {
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

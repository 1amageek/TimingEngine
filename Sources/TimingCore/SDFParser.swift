import Foundation

public struct SDFParser: TimingSDFParsing {
    public init() {}

    public func parse(_ data: Data) throws -> TimingSDF {
        guard let source = String(data: data, encoding: .utf8) else {
            throw TimingError.parseFailure(format: "SDF", line: 1, message: "Input is not UTF-8.")
        }
        var grammar = SDFGrammar(source: source)
        let root = try grammar.parse()
        var timescale = 1.0
        var annotations: [TimingSDF.Annotation] = []
        let delayRoot = root.first(where: { $0.name == "DELAY" })
        if let node = delayRoot?.child(named: "TIMESCALE") ?? root.first(where: { $0.name == "TIMESCALE" }), let value = node.atoms.first {
            timescale = Self.timeScale(value)
        }
        let cells = delayRoot?.children.filter { $0.name == "CELL" } ?? root.filter { $0.name == "CELL" }
        for cell in cells {
            let instance = cell.child(named: "INSTANCE")?.atoms.first ?? "*"
            guard let delay = cell.child(named: "DELAY") else { continue }
            let absolute = delay.child(named: "ABSOLUTE") ?? delay
            for path in absolute.children where path.name == "IOPATH" {
                guard path.atoms.count >= 2 else {
                    throw TimingError.parseFailure(format: "SDF", line: path.line, message: "IOPATH is missing pins.")
                }
                let values = path.children.compactMap { Self.delayValue($0.name) }
                guard !values.isEmpty else {
                    throw TimingError.parseFailure(format: "SDF", line: path.line, message: "IOPATH has no delay value.")
                }
                annotations.append(TimingSDF.Annotation(
                    instance: instance,
                    fromPin: path.atoms[0],
                    toPin: path.atoms[1],
                    rise: values[0] * timescale,
                    fall: (values.count > 1 ? values[1] : values[0]) * timescale
                ))
            }
        }
        return TimingSDF(timescale: timescale, annotations: annotations)
    }

    private static func delayValue(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let selected: String
        if parts.count >= 3, !parts[1].isEmpty {
            selected = parts[1]
        } else if let first = parts.first, !first.isEmpty {
            selected = first
        } else if let last = parts.last, !last.isEmpty {
            selected = last
        } else {
            return nil
        }
        return Double(selected)
    }

    private static func timeScale(_ value: String) -> Double {
        let lower = value.lowercased()
        let suffixes: [(String, Double)] = [("fs", 1e-15), ("ps", 1e-12), ("ns", 1e-9), ("us", 1e-6), ("ms", 1e-3), ("s", 1)]
        for (suffix, scale) in suffixes where lower.hasSuffix(suffix) {
            return (Double(lower.dropLast(suffix.count)) ?? 1) * scale
        }
        return Double(lower) ?? 1
    }
}

public struct SDFWriter: Sendable {
    public init() {}

    public func write(_ sdf: TimingSDF) -> Data {
        var lines: [String] = [
            "(SDFVERSION \"3.0\")",
            "(TIMESCALE \(formatTimeScale(sdf.timescale)))",
        ]
        for instance in Dictionary(grouping: sdf.annotations, by: \.instance).sorted(by: { $0.key < $1.key }) {
            lines.append("(CELL")
            lines.append("  (CELLTYPE \"TIMING_ENGINE_CELL\")")
            lines.append("  (INSTANCE \(instance.key))")
            lines.append("  (DELAY")
            lines.append("    (ABSOLUTE")
            for annotation in instance.value {
                guard let fromPin = annotation.fromPin, let toPin = annotation.toPin else { continue }
                let rise = annotation.rise.map { formatNumber($0 / sdf.timescale) } ?? "0"
                let fall = annotation.fall.map { formatNumber($0 / sdf.timescale) } ?? rise
                lines.append("      (IOPATH \(fromPin) \(toPin) (\(rise)) (\(fall)))")
            }
            lines.append("    )")
            lines.append("  )")
            lines.append(")")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func formatTimeScale(_ value: Double) -> String {
        let options: [(Double, String)] = [(1e-15, "1fs"), (1e-12, "1ps"), (1e-9, "1ns"), (1e-6, "1us"), (1e-3, "1ms"), (1, "1s")]
        return options.min { abs($0.0 - value) < abs($1.0 - value) }?.1 ?? "1s"
    }

    private func formatNumber(_ value: Double) -> String {
        String(format: "%.17g", value)
    }
}

private struct SDFNode: Sendable {
    let name: String
    let atoms: [String]
    let children: [SDFNode]
    let line: Int

    func child(named name: String) -> SDFNode? {
        children.first { $0.name == name }
    }
}

private struct SDFGrammar {
    private let source: String
    private var tokens: [String] = []
    private var lines: [Int] = []
    private var index = 0

    init(source: String) {
        self.source = source
        tokenize()
    }

    mutating func parse() throws -> [SDFNode] {
        var nodes: [SDFNode] = []
        while index < tokens.count {
            nodes.append(try parseNode())
        }
        return nodes
    }

    private mutating func parseNode() throws -> SDFNode {
        guard consume("(") else { throw error("Expected '('.") }
        guard index < tokens.count else { throw error("Missing SDF node name.") }
        let name = tokens[index]
        let line = lines[index]
        index += 1
        var atoms: [String] = []
        var children: [SDFNode] = []
        while index < tokens.count, tokens[index] != ")" {
            if tokens[index] == "(" {
                children.append(try parseNode())
            } else {
                atoms.append(tokens[index])
                index += 1
            }
        }
        guard consume(")") else { throw error("Unterminated SDF node '\(name)'.") }
        return SDFNode(name: name, atoms: atoms, children: children, line: line)
    }

    private mutating func consume(_ token: String) -> Bool {
        guard index < tokens.count, tokens[index] == token else { return false }
        index += 1
        return true
    }

    private func error(_ message: String) -> TimingError {
        .parseFailure(format: "SDF", line: lines.indices.contains(index) ? lines[index] : (lines.last ?? 1), message: message)
    }

    private mutating func tokenize() {
        let bytes = Array(source.utf8)
        var cursor = 0
        var line = 1
        while cursor < bytes.count {
            if bytes[cursor] == 10 { line += 1; cursor += 1; continue }
            if bytes[cursor] == 32 || bytes[cursor] == 9 || bytes[cursor] == 13 { cursor += 1; continue }
            if bytes[cursor] == 34 {
                cursor += 1
                var value = ""
                while cursor < bytes.count, bytes[cursor] != 34 {
                    value.append(Character(UnicodeScalar(bytes[cursor])))
                    cursor += 1
                }
                if cursor < bytes.count { cursor += 1 }
                tokens.append(value)
                lines.append(line)
                continue
            }
            if bytes[cursor] == 40 || bytes[cursor] == 41 {
                tokens.append(String(Character(UnicodeScalar(bytes[cursor]))))
                lines.append(line)
                cursor += 1
                continue
            }
            var value = ""
            while cursor < bytes.count, ![10, 13, 32, 9, 40, 41].contains(bytes[cursor]) {
                value.append(Character(UnicodeScalar(bytes[cursor])))
                cursor += 1
            }
            tokens.append(value)
            lines.append(line)
        }
    }
}

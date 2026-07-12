import Foundation

public struct LibertyParser: TimingLibraryParsing {
    public init() {}

    public func parse(_ data: Data) throws -> TimingLibrary {
        guard let source = String(data: data, encoding: .utf8) else {
            throw TimingError.parseFailure(format: "Liberty", line: 1, message: "Input is not UTF-8.")
        }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            do {
                return try JSONDecoder().decode(TimingLibrary.self, from: data)
            } catch {
                throw TimingError.parseFailure(format: "Liberty JSON", line: 1, message: error.localizedDescription)
            }
        }
        var grammar = try LibertyGrammar(source: source)
        let root = try grammar.parse()
        guard let libraryNode = root.first(where: { $0.name == "library" }) else {
            throw TimingError.parseFailure(format: "Liberty", line: 1, message: "No library group was found.")
        }

        let timeUnitScale = Self.unitScale(
            from: libraryNode.attribute(named: "time_unit") ?? "1s",
            dimension: .time
        )
        let capacitanceUnitScale = Self.capacitanceScale(
            from: libraryNode.children.first(where: { $0.name == "capacitive_load_unit" })?.arguments ?? []
        )
        let powerUnitScale = Self.unitScale(
            from: libraryNode.attribute(named: "power_unit") ?? "1W",
            dimension: .power
        )
        var operatingConditions: [String: TimingOperatingCondition] = [:]
        for node in libraryNode.children where node.name == "operating_conditions" {
            let name = node.arguments.first ?? "default"
            operatingConditions[name] = TimingOperatingCondition(
                name: name,
                process: node.attribute(named: "process").flatMap(Self.number),
                voltage: node.attribute(named: "voltage").flatMap(Self.number),
                temperature: node.attribute(named: "temperature").flatMap(Self.number)
            )
        }

        var cells: [String: TimingCell] = [:]
        for cellNode in libraryNode.children where cellNode.name == "cell" {
            guard let cellName = cellNode.arguments.first, !cellName.isEmpty else {
                throw TimingError.parseFailure(format: "Liberty", line: cellNode.line, message: "Cell has no name.")
            }
            let cell = try parseCell(
                node: cellNode,
                timeUnitScale: timeUnitScale,
                capacitanceUnitScale: capacitanceUnitScale,
                powerUnitScale: powerUnitScale
            )
            cells[cellName] = cell
        }

        guard !cells.isEmpty else {
            throw TimingError.parseFailure(format: "Liberty", line: libraryNode.line, message: "Library contains no cells.")
        }
        return TimingLibrary(
            name: libraryNode.arguments.first ?? "library",
            timeUnitScale: timeUnitScale,
            capacitanceUnitScale: capacitanceUnitScale,
            powerUnitScale: powerUnitScale,
            cells: cells,
            operatingConditions: operatingConditions
        )
    }

    private func parseCell(
        node: LibertyNode,
        timeUnitScale: Double,
        capacitanceUnitScale: Double,
        powerUnitScale: Double
    ) throws -> TimingCell {
        var pins: [TimingPin] = []
        for pinNode in node.children where pinNode.name == "pin" {
            guard let name = pinNode.arguments.first else {
                throw TimingError.parseFailure(format: "Liberty", line: pinNode.line, message: "Pin has no name.")
            }
            let direction = TimingPin.Direction(rawValue: (pinNode.attribute(named: "direction") ?? "unknown").lowercased()) ?? .unknown
            let capacitance = Self.number(pinNode.attribute(named: "capacitance") ?? "0", default: 0) * capacitanceUnitScale
            let maxCapacitance = pinNode.attribute(named: "max_capacitance").flatMap(Self.number).map { $0 * capacitanceUnitScale }
            pins.append(TimingPin(
                name: name,
                direction: direction,
                capacitance: capacitance,
                maxCapacitance: maxCapacitance,
                function: pinNode.attribute(named: "function"),
                isClock: false,
                isData: false
            ))
        }

        let ffNode = node.children.first(where: { $0.name == "ff" })
        let leakagePower = node.attribute(named: "cell_leakage_power").flatMap(Self.number).map { $0 * powerUnitScale }
        let internalPower = node.children
            .filter { $0.name == "internal_power" }
            .flatMap { powerNode in
                powerNode.children
                    .filter { $0.name == "rise_power" || $0.name == "fall_power" }
                    .compactMap { powerNode in Self.values(from: powerNode.child(named: "values")?.arguments ?? []).first }
            }
            .first
            .map { $0 * powerUnitScale }
        let dataPin = ffNode.flatMap { Self.pinName(from: $0.attribute(named: "next_state")) }
        let clockPin = ffNode.flatMap { Self.pinName(from: $0.attribute(named: "clocked_on")) }
        let outputPin = pins.first(where: { $0.direction == .output })?.name
        var arcs: [TimingArc] = []
        var setup = 0.0
        var hold = 0.0
        var recovery: Double?
        var removal: Double?
        var minPulseWidth: Double?
        var clockToQ: TimingArc?

        for pinNode in node.children where pinNode.name == "pin" {
            guard let destination = pinNode.arguments.first else { continue }
            for timingNode in pinNode.children where timingNode.name == "timing" {
                guard let related = timingNode.attribute(named: "related_pin").flatMap(Self.pinName) else { continue }
                let timingType = (timingNode.attribute(named: "timing_type") ?? "").lowercased()
                if timingType.contains("setup") {
                    setup = max(setup, try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale))
                    continue
                }
                if timingType.contains("hold") {
                    hold = max(hold, try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale))
                    continue
                }
                if timingType.contains("recovery") {
                    recovery = max(recovery ?? 0, try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale))
                    continue
                }
                if timingType.contains("removal") {
                    removal = max(removal ?? 0, try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale))
                    continue
                }
                if timingType.contains("min_pulse_width") {
                    minPulseWidth = max(minPulseWidth ?? 0, try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale))
                    continue
                }

                let arc = try parseArc(
                    timingNode,
                    from: related,
                    to: destination,
                    timeUnitScale: timeUnitScale,
                    capacitanceUnitScale: capacitanceUnitScale
                )
                arcs.append(arc)
                if let clockPin, let outputPin, related == clockPin, destination == outputPin,
                   timingType.contains("edge") || timingType.contains("propagation") {
                    clockToQ = arc
                }
            }
        }

        let sequential: TimingSequentialModel?
        if let dataPin, let clockPin, let outputPin {
            sequential = TimingSequentialModel(
                dataPin: dataPin,
                clockPin: clockPin,
                outputPin: outputPin,
                clockToQ: clockToQ,
                setupTime: setup,
                holdTime: hold,
                recoveryTime: recovery,
                removalTime: removal,
                minPulseWidth: minPulseWidth
            )
        } else {
            sequential = nil
        }

        let normalizedPins = pins.map { pin in
            TimingPin(
                name: pin.name,
                direction: pin.direction,
                capacitance: pin.capacitance,
                maxCapacitance: pin.maxCapacitance,
                function: pin.function,
                isClock: pin.name == clockPin,
                isData: pin.name == dataPin
            )
        }
        return TimingCell(
            name: node.arguments.first ?? "cell",
            area: node.attribute(named: "area").flatMap(Self.number),
            pins: normalizedPins,
            arcs: arcs,
            sequentialModel: sequential,
            powerModel: TimingPowerModel(leakagePower: leakagePower, internalPower: internalPower)
        )
    }

    private func parseArc(
        _ node: LibertyNode,
        from: String,
        to: String,
        timeUnitScale: Double,
        capacitanceUnitScale: Double
    ) throws -> TimingArc {
        let senseValue = (node.attribute(named: "timing_sense") ?? "positive_unate").lowercased()
        let sense: TimingSense
        switch senseValue {
        case "negative_unate":
            sense = .negativeUnate
        case "non_unate":
            sense = .nonUnate
        default:
            sense = .positiveUnate
        }
        let rise = try table(node: node, name: "cell_rise", scale: timeUnitScale, capacitanceScale: capacitanceUnitScale)
        let fall = try table(node: node, name: "cell_fall", scale: timeUnitScale, capacitanceScale: capacitanceUnitScale)
        let riseTransition = try optionalTable(node: node, name: "rise_transition", scale: timeUnitScale, capacitanceScale: capacitanceUnitScale) ?? rise
        let fallTransition = try optionalTable(node: node, name: "fall_transition", scale: timeUnitScale, capacitanceScale: capacitanceUnitScale) ?? fall
        return TimingArc(
            fromPin: from,
            toPin: to,
            sense: sense,
            delayRise: rise,
            delayFall: fall,
            transitionRise: riseTransition,
            transitionFall: fallTransition,
            isConstraint: false
        )
    }

    private func constraintValue(_ node: LibertyNode, timeUnitScale: Double, capacitanceUnitScale: Double) throws -> Double {
        for name in ["rise_constraint", "fall_constraint", "cell_rise", "cell_fall"] {
            if let table = try optionalTable(node: node, name: name, scale: timeUnitScale, capacitanceScale: capacitanceUnitScale) {
                return table.values[0][0]
            }
        }
        throw TimingError.parseFailure(format: "Liberty", line: node.line, message: "Timing constraint has no supported table.")
    }

    private func table(node: LibertyNode, name: String, scale: Double, capacitanceScale: Double) throws -> TimingLUT {
        guard let table = try optionalTable(node: node, name: name, scale: scale, capacitanceScale: capacitanceScale) else {
            throw TimingError.parseFailure(format: "Liberty", line: node.line, message: "Timing arc is missing \(name).")
        }
        return table
    }

    private func optionalTable(node: LibertyNode, name: String, scale: Double, capacitanceScale: Double) throws -> TimingLUT? {
        guard let tableNode = node.children.first(where: { $0.name == name }) else { return nil }
        let index1 = Self.values(from: tableNode.child(named: "index_1")?.arguments ?? []).map { $0 }
        let index2 = Self.values(from: tableNode.child(named: "index_2")?.arguments ?? []).map { $0 }
        let rows = Self.values(from: tableNode.child(named: "values")?.arguments ?? [])
        let actualIndex1 = index1.isEmpty ? [0] : index1.map { $0 * scale }
        let actualIndex2 = index2.isEmpty ? [0] : index2.map { $0 * capacitanceScale }
        let matrix: [[Double]]
        if rows.isEmpty {
            matrix = [[0]]
        } else if rows.count == actualIndex1.count * actualIndex2.count {
            matrix = stride(from: 0, to: rows.count, by: actualIndex2.count).map {
                Array(rows[$0 ..< ($0 + actualIndex2.count)])
            }
        } else if actualIndex1.count == 1 && rows.count == actualIndex2.count {
            matrix = [rows]
        } else {
            throw TimingError.parseFailure(format: "Liberty", line: tableNode.line, message: "Table dimensions do not match values.")
        }
        return try TimingLUT(
            inputSlews: actualIndex1,
            outputLoads: actualIndex2,
            values: matrix.map { row in row.map { $0 * scale } }
        )
    }

    private enum UnitDimension {
        case time
        case power
    }

    private static func unitScale(from value: String, dimension: UnitDimension) -> Double {
        let cleaned = value.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let number = Self.number(cleaned) ?? 1
        let suffix = cleaned.drop { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E" }
        switch (dimension, suffix) {
        case (.time, "s"): return number
        case (.time, "ms"): return number * 1e-3
        case (.time, "us"): return number * 1e-6
        case (.time, "ns"): return number * 1e-9
        case (.time, "ps"): return number * 1e-12
        case (.time, "fs"): return number * 1e-15
        case (.power, "w"): return number
        case (.power, "mw"): return number * 1e-3
        case (.power, "uw"): return number * 1e-6
        case (.power, "nw"): return number * 1e-9
        case (.power, "pw"): return number * 1e-12
        default: return number
        }
    }

    private static func capacitanceScale(from arguments: [String]) -> Double {
        guard arguments.count >= 2, let value = number(arguments[0]) else { return 1 }
        let unit = arguments[1].lowercased()
        let multiplier: Double
        switch unit {
        case "f": multiplier = 1
        case "mf": multiplier = 1e-3
        case "uf": multiplier = 1e-6
        case "nf": multiplier = 1e-9
        case "pf": multiplier = 1e-12
        case "ff": multiplier = 1e-15
        default: multiplier = 1
        }
        return value * multiplier
    }

    private static func number(_ value: String) -> Double? {
        let cleaned = value.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(cleaned) { return direct }
        let suffixes = ["ms", "us", "ns", "ps", "fs", "s", "mf", "uf", "nf", "pf", "ff"]
        for suffix in suffixes where cleaned.lowercased().hasSuffix(suffix) {
            return Double(cleaned.dropLast(suffix.count))
        }
        return nil
    }

    private static func number(_ value: String, default fallback: Double) -> Double {
        number(value) ?? fallback
    }

    private static func values(from arguments: [String]) -> [Double] {
        arguments
            .joined(separator: ",")
            .replacingOccurrences(of: "\"", with: "")
            .split { $0 == "," || $0.isWhitespace }
            .compactMap { Double($0) }
    }

    private static func pinName(from expression: String?) -> String? {
        guard let expression else { return nil }
        let cleaned = expression.replacingOccurrences(of: "\"", with: "")
        let candidates = cleaned.split { character in
            !(character.isLetter || character.isNumber || character == "_")
        }
        return candidates.last.map(String.init)
    }
}

private struct LibertyNode: Sendable {
    let name: String
    let arguments: [String]
    let value: String?
    let children: [LibertyNode]
    let line: Int

    func attribute(named name: String) -> String? {
        children.first(where: { $0.name == name })?.value
    }

    func child(named name: String) -> LibertyNode? {
        children.first(where: { $0.name == name })
    }
}

private struct LibertyGrammar {
    private enum Token: Equatable {
        case word(String)
        case quoted(String)
        case symbol(Character)
        case end
    }

    private let source: String
    private var tokens: [Token] = []
    private var lines: [Int] = []
    private var index = 0

    init(source: String) throws {
        self.source = source
        try tokenize()
    }

    mutating func parse() throws -> [LibertyNode] {
        try parseStatements(until: nil)
    }

    private mutating func parseStatements(until closing: Character?) throws -> [LibertyNode] {
        var result: [LibertyNode] = []
        while true {
            if case .end = peek() {
                if closing != nil {
                    throw error("Missing closing '\(closing!)'.")
                }
                return result
            }
            if let closing, peek() == .symbol(closing) {
                _ = advance()
                return result
            }
            guard case .word(let name) = advance() else {
                throw error("Expected a Liberty group or attribute.")
            }
            let line = currentLine()
            var arguments: [String] = []
            if peek() == .symbol("(") {
                arguments = try parseArguments()
            }
            if peek() == .symbol(":") {
                _ = advance()
                let value = try parseAttributeValue()
                result.append(LibertyNode(name: name, arguments: arguments, value: value, children: [], line: line))
            } else if peek() == .symbol("{") {
                _ = advance()
                let children = try parseStatements(until: "}")
                result.append(LibertyNode(name: name, arguments: arguments, value: nil, children: children, line: line))
            } else if peek() == .symbol(";") {
                _ = advance()
                result.append(LibertyNode(name: name, arguments: arguments, value: nil, children: [], line: line))
            } else {
                throw error("Expected ':', '{' or ';' after '\(name)'.")
            }
        }
    }

    private mutating func parseArguments() throws -> [String] {
        guard peek() == .symbol("(") else { return [] }
        _ = advance()
        var values: [String] = []
        var current = ""
        while true {
            switch advance() {
            case .symbol(")"):
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append(current) }
                return values
            case .symbol(","):
                values.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            case .word(let value), .quoted(let value):
                if !current.isEmpty { current += " " }
                current += value
            case .symbol(let symbol):
                current.append(symbol)
            case .end:
                throw error("Unterminated argument list.")
            }
        }
    }

    private mutating func parseAttributeValue() throws -> String {
        var value = ""
        while true {
            switch advance() {
            case .symbol(";"):
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .word(let item), .quoted(let item):
                if !value.isEmpty { value += " " }
                value += item
            case .symbol(let symbol):
                value.append(symbol)
            case .end:
                throw error("Unterminated attribute value.")
            }
        }
    }

    private func peek() -> Token { tokens[index] }

    private mutating func advance() -> Token {
        let token = tokens[index]
        index += 1
        return token
    }

    private func currentLine() -> Int { lines[min(index, lines.count - 1)] }

    private func error(_ message: String) -> TimingError {
        .parseFailure(format: "Liberty", line: currentLine(), message: message)
    }

    private mutating func tokenize() throws {
        let bytes = Array(source.utf8)
        var cursor = 0
        var line = 1
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == 10 { line += 1; cursor += 1; continue }
            if byte == 13 || byte == 32 || byte == 9 { cursor += 1; continue }
            if byte == 47, cursor + 1 < bytes.count, bytes[cursor + 1] == 47 {
                cursor += 2
                while cursor < bytes.count, bytes[cursor] != 10 { cursor += 1 }
                continue
            }
            if byte == 47, cursor + 1 < bytes.count, bytes[cursor + 1] == 42 {
                cursor += 2
                while cursor + 1 < bytes.count && !(bytes[cursor] == 42 && bytes[cursor + 1] == 47) {
                    if bytes[cursor] == 10 { line += 1 }
                    cursor += 1
                }
                guard cursor + 1 < bytes.count else {
                    throw TimingError.parseFailure(format: "Liberty", line: line, message: "Unterminated comment.")
                }
                cursor += 2
                continue
            }
            if byte == 34 {
                cursor += 1
                var value = ""
                while cursor < bytes.count && bytes[cursor] != 34 {
                    if bytes[cursor] == 92, cursor + 1 < bytes.count {
                        cursor += 1
                    }
                    value.append(Character(UnicodeScalar(bytes[cursor])))
                    cursor += 1
                }
                guard cursor < bytes.count else {
                    throw TimingError.parseFailure(format: "Liberty", line: line, message: "Unterminated string.")
                }
                cursor += 1
                tokens.append(.quoted(value))
                lines.append(line)
                continue
            }
            if "(){}:;,".utf8.contains(byte) {
                tokens.append(.symbol(Character(UnicodeScalar(byte))))
                lines.append(line)
                cursor += 1
                continue
            }
            var value = ""
            while cursor < bytes.count {
                let current = bytes[cursor]
                if current == 10 || current == 13 || current == 32 || current == 9 || "(){}:;,\"".utf8.contains(current) { break }
                value.append(Character(UnicodeScalar(current)))
                cursor += 1
            }
            if value.isEmpty {
                throw TimingError.parseFailure(format: "Liberty", line: line, message: "Unexpected byte.")
            }
            tokens.append(.word(value))
            lines.append(line)
        }
        tokens.append(.end)
        lines.append(line)
    }
}

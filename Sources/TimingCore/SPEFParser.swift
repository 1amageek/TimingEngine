import Foundation

public struct SPEFParser: TimingParasiticParsing {
    public init() {}

    public func parse(_ data: Data) throws -> TimingParasitics {
        do {
            return try parseData(data)
        } catch let error as TimingSPEFError {
            throw TimingError.spefOwnership(error)
        }
    }

    private func parseData(_ data: Data) throws -> TimingParasitics {
        guard let source = String(data: data, encoding: .utf8) else {
            throw TimingError.parseFailure(format: "SPEF", line: 1, message: "Input is not UTF-8.")
        }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            do {
                return try JSONDecoder().decode(TimingParasitics.self, from: data)
            } catch {
                throw TimingError.parseFailure(format: "SPEF JSON", line: 1, message: error.localizedDescription)
            }
        }
        var capacitanceScale = 1.0
        var resistanceScale = 1.0
        var delimiter: Character = ":"
        var nameMap: [String: String] = [:]
        var inNameMap = false
        var networks: [String: TimingParasitics.Network] = [:]
        var connections: [String: String] = [:]
        var pendingCouplings: [(first: String, second: String, capacitance: Double, line: Int)] = []
        var currentNetwork: String?
        var totalCapacitance = 0.0
        var groundCapacitance = 0.0
        var resistance = 0.0
        var section: String?

        func expand(_ token: String, line: Int) throws -> String {
            guard token.first == "*" else { return token }
            if let value = nameMap[token] { return value }
            let split = unescapedDelimiter(in: token, delimiter: delimiter)
            let reference = split.map { String(token[..<$0]) } ?? token
            guard let value = nameMap[reference] else {
                throw TimingSPEFError.unknownNameMapReference(line: line, reference: reference)
            }
            guard let split else { return value }
            return value + token[split...]
        }

        func finishNetwork(line: Int) throws {
            guard let currentNetwork else { return }
            let total = totalCapacitance * capacitanceScale
            let ground = groundCapacitance * capacitanceScale
            let ohms = resistance * resistanceScale
            guard total.isFinite, ground.isFinite, ohms.isFinite else {
                throw TimingError.parseFailure(format: "SPEF", line: line, message: "Network aggregate overflow.")
            }
            networks[currentNetwork] = TimingParasitics.Network(
                name: currentNetwork, totalCapacitance: total,
                groundCapacitance: ground, resistance: ohms
            )
        }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = fields.first else { continue }
            if first == "*NAME_MAP" { inNameMap = true; continue }
            if inNameMap, first.first == "*", first.dropFirst().allSatisfy(\.isNumber), first.count > 1 {
                guard fields.count == 2 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid name-map entry.")
                }
                guard nameMap[first] == nil else {
                    throw TimingSPEFError.duplicateNameMapReference(line: lineNumber, reference: first)
                }
                nameMap[first] = fields[1]
                continue
            }
            inNameMap = false
            if first == "*DELIMITER" {
                guard fields.count == 2, fields[1].count == 1, let value = fields[1].first,
                      value != "\\", value != "*" else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid node delimiter.")
                }
                delimiter = value
                continue
            }
            if first == "*C_UNIT" || first == "*CAP_UNIT" {
                guard fields.count == 3 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid capacitance unit declaration.")
                }
                capacitanceScale = try unitScale(value: fields[1], unit: fields[2], dimension: .capacitance, line: lineNumber)
                continue
            }
            if first == "*R_UNIT" || first == "*RES_UNIT" {
                guard fields.count == 3 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid resistance unit declaration.")
                }
                resistanceScale = try unitScale(value: fields[1], unit: fields[2], dimension: .resistance, line: lineNumber)
                continue
            }
            if first == "*D_NET" {
                try finishNetwork(line: lineNumber)
                guard fields.count >= 3, let total = Double(fields[2]), total.isFinite, total >= 0 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid *D_NET header.")
                }
                let name = unescape(try expand(fields[1], line: lineNumber))
                guard networks[name] == nil else {
                    throw TimingSPEFError.duplicateNetwork(line: lineNumber, net: name)
                }
                currentNetwork = name
                totalCapacitance = total
                groundCapacitance = 0
                resistance = 0
                section = nil
                continue
            }
            if first == "*END" {
                try finishNetwork(line: lineNumber)
                currentNetwork = nil
                section = nil
                continue
            }
            guard let currentNetwork else { continue }
            if first == "*CAP" { section = "cap"; continue }
            if first == "*RES" { section = "res"; continue }
            if first == "*CONN" { section = "conn"; continue }
            if section == "conn", first == "*P" || first == "*I" || first == "*N" {
                guard fields.count >= 2 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Missing connection endpoint.")
                }
                let endpoint = unescape(try expand(fields[1], line: lineNumber))
                if let previous = connections[endpoint], previous != currentNetwork {
                    throw TimingSPEFError.conflictingConnection(
                        line: lineNumber, endpoint: endpoint, firstNet: previous, secondNet: currentNetwork
                    )
                }
                connections[endpoint] = currentNetwork
            } else if section == "cap" {
                guard fields.count == 3 || fields.count == 4,
                      let value = Double(fields.last ?? ""), value.isFinite, value >= 0 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid capacitance entry.")
                }
                if fields.count == 3 {
                    groundCapacitance += value
                } else {
                    let capacitance = value * capacitanceScale
                    guard capacitance.isFinite else {
                        throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Coupling capacitance overflow.")
                    }
                    pendingCouplings.append((
                        first: try expand(fields[1], line: lineNumber),
                        second: try expand(fields[2], line: lineNumber),
                        capacitance: capacitance, line: lineNumber
                    ))
                }
            } else if section == "res" {
                guard fields.count >= 4, let value = Double(fields.last ?? ""), value.isFinite, value >= 0 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid resistance entry.")
                }
                resistance += value
            }
        }
        try finishNetwork(line: lines.count)
        guard !networks.isEmpty else {
            throw TimingError.parseFailure(format: "SPEF", line: 1, message: "No *D_NET sections were found.")
        }

        func owner(of token: String, line: Int) throws -> String {
            let endpoint = unescape(token)
            var candidates: Set<String> = []
            if let connection = connections[endpoint] { candidates.insert(connection) }
            if networks[endpoint] != nil { candidates.insert(endpoint) }
            let split = unescapedDelimiter(in: token, delimiter: delimiter)
            if let split {
                let suffix = token[token.index(after: split)...]
                let prefix = unescape(String(token[..<split]))
                if !suffix.isEmpty, suffix.allSatisfy(\.isNumber), networks[prefix] != nil {
                    candidates.insert(prefix)
                }
            }
            if candidates.count > 1 {
                throw TimingSPEFError.ambiguousEndpoint(line: line, endpoint: endpoint, nets: candidates.sorted())
            }
            if let candidate = candidates.first { return candidate }
            // Unscoped root identities can belong to a design-known external net
            // absent from partial D_NET coverage. Logical validation owns admission.
            if split == nil { return endpoint }
            throw TimingSPEFError.unknownEndpoint(line: line, endpoint: endpoint)
        }

        let couplings = try pendingCouplings.map { entry in
            let first = try owner(of: entry.first, line: entry.line)
            let second = try owner(of: entry.second, line: entry.line)
            guard first != second else {
                throw TimingSPEFError.intraNetCoupling(line: entry.line, net: first)
            }
            return TimingParasitics.Coupling(firstNet: first, secondNet: second, capacitance: entry.capacitance)
        }
        return TimingParasitics(networks: networks.values.sorted { $0.name < $1.name }, couplings: couplings)
    }

    private func unescapedDelimiter(in token: String, delimiter: Character) -> String.Index? {
        var escaped = false
        var last: String.Index?
        for index in token.indices {
            let character = token[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == delimiter { last = index }
        }
        return last
    }

    private func unescape(_ token: String) -> String {
        var result = ""
        var escaped = false
        for character in token {
            if escaped { result.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }

    private enum UnitDimension {
        case capacitance
        case resistance
    }

    private func unitScale(
        value: String,
        unit: String,
        dimension: UnitDimension,
        line: Int
    ) throws -> Double {
        guard let number = Double(value), number.isFinite, number > 0 else {
            throw TimingError.parseFailure(
                format: "SPEF",
                line: line,
                message: "Unit scale must contain a finite positive number."
            )
        }
        switch (dimension, unit.uppercased()) {
        case (.capacitance, "F"): return number
        case (.capacitance, "MF"): return number * 1e-3
        case (.capacitance, "UF"): return number * 1e-6
        case (.capacitance, "NF"): return number * 1e-9
        case (.capacitance, "PF"): return number * 1e-12
        case (.capacitance, "FF"): return number * 1e-15
        case (.resistance, "OHM"): return number
        case (.resistance, "KOHM"): return number * 1e3
        case (.resistance, "MOHM"): return number * 1e6
        default:
            throw TimingError.parseFailure(
                format: "SPEF",
                line: line,
                message: "Unsupported unit '\(unit)'."
            )
        }
    }
}

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
        var pendingCapacitances: [(source: TimingParasitics.SourceID, first: String, second: String?, capacitance: Double)] = []
        var localIdentifiers: Set<UInt64> = []
        var currentNetwork: String?
        var declarationLine = 1
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
            let total = try convertToSI(totalCapacitance, scale: capacitanceScale,
                                        quantity: "declared capacitance", line: declarationLine)
            _ = try convertToSI(groundCapacitance, scale: capacitanceScale,
                                quantity: "ground capacitance", line: line)
            let ohms = try convertToSI(resistance, scale: resistanceScale,
                                       quantity: "resistance inventory", line: line)
            networks[currentNetwork] = TimingParasitics.Network(
                name: currentNetwork, declaredCapacitance: total, resistanceInventory: ohms
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
                guard fields.count >= 3 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid *D_NET header.")
                }
                let total = try sourceValue(fields[2], quantity: "declared capacitance", line: lineNumber)
                let name = unescape(try expand(fields[1], line: lineNumber))
                guard networks[name] == nil else {
                    throw TimingSPEFError.duplicateNetwork(line: lineNumber, net: name)
                }
                currentNetwork = name
                declarationLine = lineNumber
                totalCapacitance = total
                groundCapacitance = 0
                resistance = 0
                section = nil
                localIdentifiers = []
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
                guard fields.count == 3 || fields.count == 4 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid capacitance entry.")
                }
                let value = try sourceValue(fields.last ?? "", quantity: "capacitance", line: lineNumber)
                guard let identifier = UInt64(fields[0]), identifier > 0,
                      localIdentifiers.insert(identifier).inserted else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber,
                        message: "Capacitance identifiers must be positive and unique within a network.")
                }
                let capacitance = try convertToSI(value, scale: capacitanceScale,
                                                  quantity: "capacitance", line: lineNumber)
                if fields.count == 3 { groundCapacitance += value }
                pendingCapacitances.append((
                    source: .init(declaringNet: currentNetwork, identifier: identifier, line: lineNumber),
                    first: try expand(fields[1], line: lineNumber),
                    second: fields.count == 4 ? try expand(fields[2], line: lineNumber) : nil,
                    capacitance: capacitance
                ))
            } else if section == "res" {
                guard fields.count >= 4 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid resistance entry.")
                }
                let value = try sourceValue(fields.last ?? "", quantity: "resistance", line: lineNumber)
                _ = try convertToSI(value, scale: resistanceScale, quantity: "resistance", line: lineNumber)
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

        var records: [String: [TimingParasitics.CapacitanceRecord]] = [:]
        for entry in pendingCapacitances {
            let first = TimingParasitics.Endpoint(name: unescape(entry.first),
                ownerNet: try owner(of: entry.first, line: entry.source.line))
            let second = try entry.second.map { token in
                TimingParasitics.Endpoint(name: unescape(token),
                    ownerNet: try owner(of: token, line: entry.source.line))
            }
            guard first.ownerNet == entry.source.declaringNet
                    || second?.ownerNet == entry.source.declaringNet else {
                throw TimingSPEFError.invalidCapacitanceOwner(line: entry.source.line,
                    endpoint: first.name, declaringNet: entry.source.declaringNet)
            }
            records[entry.source.declaringNet, default: []].append(.init(
                source: entry.source, first: first, second: second, capacitance: entry.capacitance))
        }
        return TimingParasitics(networks: networks.values.sorted { $0.name < $1.name }.map { network in
            .init(name: network.name, declaredCapacitance: network.declaredCapacitance,
                  resistanceInventory: network.resistanceInventory,
                  capacitances: records[network.name] ?? [])
        })
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
        let factor: Double
        switch (dimension, unit.uppercased()) {
        case (.capacitance, "F"): factor = 1
        case (.capacitance, "MF"): factor = 1e-3
        case (.capacitance, "UF"): factor = 1e-6
        case (.capacitance, "NF"): factor = 1e-9
        case (.capacitance, "PF"): factor = 1e-12
        case (.capacitance, "FF"): factor = 1e-15
        case (.resistance, "OHM"): factor = 1
        case (.resistance, "KOHM"): factor = 1e3
        case (.resistance, "MOHM"): factor = 1e6
        default:
            throw TimingError.parseFailure(
                format: "SPEF",
                line: line,
                message: "Unsupported unit '\(unit)'."
            )
        }
        return try convertToSI(number, scale: factor, quantity: "unit scale", line: line)
    }

    private func sourceValue(_ token: String, quantity: String, line: Int) throws -> Double {
        guard let value = Double(token), value.isFinite, value >= 0 else {
            throw TimingError.parseFailure(format: "SPEF", line: line, message: "Invalid \(quantity) entry.")
        }
        // Exponent digits do not make a zero significand nonzero.
        let significand = token.prefix { $0 != "e" && $0 != "E" }
        if value == 0, significand.contains(where: { $0 >= "1" && $0 <= "9" }) {
            let message = token.hasPrefix("-")
                ? "Invalid \(quantity) entry."
                : "Positive \(quantity) is not representable as a Double."
            throw TimingError.parseFailure(format: "SPEF", line: line, message: message)
        }
        return value
    }

    private func convertToSI(_ value: Double, scale: Double, quantity: String, line: Int) throws -> Double {
        let converted = value * scale
        guard converted.isFinite, value == 0 || converted > 0 else {
            throw TimingError.parseFailure(format: "SPEF", line: line,
                message: "Positive \(quantity) is not representable in SI units.")
        }
        return converted
    }
}

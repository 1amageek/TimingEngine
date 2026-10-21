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
        return try parseSource(source, transform: nil)
    }

    public func parse(_ data: Data, resources: any LibertySourceResourceAccounting,
        json: any TimingBoundedJSONDecoding) throws -> TimingTransformValue<TimingParasitics> {
        let transform = try TimingTextTransform(resources: resources)
        do {
            let route = try controlledRoute(data, transform: transform)
            switch route {
            case .json:
                transform.storage.releaseTemporary()
                return try json.decodeParasitics(data, resources: resources)
            case .source(let value): return try transform.finish(value)
            }
        } catch let error as TimingControlledTransformFailure { throw error }
        catch { throw transform.failure(error) }
    }

    private enum ControlledRoute { case json; case source(TimingParasitics) }
    private func controlledRoute(_ data: Data, transform: TimingTextTransform) throws -> ControlledRoute {
        let source = try transform.source(data, format: "SPEF")
        if try transform.trimmed(source).hasPrefix("{") { return .json }
        do { return .source(try parseSource(source, transform: transform)) }
        catch let error as TimingSPEFError { throw TimingError.spefOwnership(error) }
    }

    private func parseSource(_ source: String, transform: TimingTextTransform?) throws -> TimingParasitics {
        let lines: [Substring]
        if let transform { lines = try transform.segments(source, omittingEmpty: false, separatedBy: { $0 == "\n" }) }
        else { lines = source.split(separator: "\n", omittingEmptySubsequences: false) }
        let nameMapLease = try transform?.reserveDictionary(String.self, String.self, capacity: lines.count, kind: .liveOwnedBytes)
        let networksLease = try transform?.reserveDictionary(String.self, TimingParasitics.Network.self, capacity: lines.count)
        let connectionsLease = try transform?.reserveDictionary(String.self, String.self, capacity: lines.count, kind: .liveOwnedBytes)
        typealias PendingCapacitance = (source: TimingParasitics.SourceID, first: String, second: String?, capacitance: Double)
        typealias PendingResistance = (source: TimingParasitics.SourceID, first: String, second: String, resistance: Double)
        let capacitanceLease = try transform?.storage.reserve(PendingCapacitance.self, capacity: lines.count, kind: .temporaryBytes)
        let resistanceLease = try transform?.storage.reserve(PendingResistance.self, capacity: lines.count, kind: .temporaryBytes)
        let resistanceIDsLease = try transform?.reserveSet(UInt64.self, capacity: lines.count)
        let capacitanceIDsLease = try transform?.reserveSet(UInt64.self, capacity: lines.count)
        var capacitanceScale = 1.0
        var resistanceScale = 1.0
        var delimiter: Character = ":"
        var nameMap: [String: String] = [:]
        var inNameMap = false
        var networks: [String: TimingParasitics.Network] = [:]
        var connections: [String: String] = [:]
        var pendingCapacitances: [(source: TimingParasitics.SourceID, first: String, second: String?, capacitance: Double)] = []
        var pendingResistances: [(source: TimingParasitics.SourceID, first: String, second: String, resistance: Double)] = []
        var resistanceIdentifiers: Set<UInt64> = []
        var localIdentifiers: Set<UInt64> = []
        if transform != nil {
            nameMap.reserveCapacity(lines.count); networks.reserveCapacity(lines.count); connections.reserveCapacity(lines.count)
            pendingCapacitances.reserveCapacity(lines.count); pendingResistances.reserveCapacity(lines.count)
            resistanceIdentifiers.reserveCapacity(lines.count); localIdentifiers.reserveCapacity(lines.count)
        }
        var currentNetwork: String?
        var declarationLine = 1
        var totalCapacitance = 0.0
        var groundCapacitance = 0.0
        var resistance = 0.0
        var section: String?

        func expand(_ token: String, line: Int) throws -> String {
            guard token.first == "*" else { return token }
            if let value = nameMap[token] { return value }
            let split = try unescapedDelimiter(in: token, delimiter: delimiter, transform: transform)
            let reference: String
            if let split, let transform { reference = try transform.text(token[..<split]) }
            else { reference = split.map { String(token[..<$0]) } ?? token }
            guard let value = nameMap[reference] else {
                throw TimingSPEFError.unknownNameMapReference(line: line, reference: reference)
            }
            guard let split else { return value }
            if let transform { return try transform.concatenate(value, token[split...]) }
            return value + token[split...]
        }

        func finishNetwork(line: Int) throws {
            guard let currentNetwork else { return }
            let total = try convertToSI(totalCapacitance, scale: capacitanceScale,
                                        quantity: "declared capacitance", line: declarationLine, transform: transform)
            _ = try convertToSI(groundCapacitance, scale: capacitanceScale,
                                quantity: "ground capacitance", line: line, transform: transform)
            let ohms = try convertToSI(resistance, scale: resistanceScale,
                                       quantity: "resistance inventory", line: line, transform: transform)
            networks[currentNetwork] = TimingParasitics.Network(
                name: currentNetwork, declaredCapacitance: total, resistanceInventory: ohms
            )
        }

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line: String
            if let transform { line = try transform.trimmed(transform.text(rawLine, kind: .temporaryBytes)) }
            else { line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            let fields: [String]
            if let transform {
                fields = try transform.map(transform.segments(line, omittingEmpty: true, separatedBy: { $0.isWhitespace })) {
                    try transform.text($0)
                }
            } else { fields = line.split(whereSeparator: \.isWhitespace).map(String.init) }
            try transform?.storage.step(UInt64(line.utf8.count))
            guard let first = fields.first else { continue }
            if first == "*PROGRAM", line.contains(" PEX_IDENTITY_V1"), !line.contains(" PEX_CANONICAL_TERMINALS_V1") {
                throw TimingError.unsupportedSemantic(format: "SPEF", semantic: "Encoded PEX terminals require explicit canonical-terminal export.")
            }
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
                capacitanceScale = try unitScale(value: fields[1], unit: fields[2], dimension: .capacitance, line: lineNumber, transform: transform)
                continue
            }
            if first == "*R_UNIT" || first == "*RES_UNIT" {
                guard fields.count == 3 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid resistance unit declaration.")
                }
                resistanceScale = try unitScale(value: fields[1], unit: fields[2], dimension: .resistance, line: lineNumber, transform: transform)
                continue
            }
            if first == "*D_NET" {
                try finishNetwork(line: lineNumber)
                guard fields.count >= 3 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid *D_NET header.")
                }
                let total = try sourceValue(fields[2], quantity: "declared capacitance", line: lineNumber, transform: transform)
                let name = try unescape(expand(fields[1], line: lineNumber), transform: transform)
                guard networks[name] == nil else {
                    throw TimingSPEFError.duplicateNetwork(line: lineNumber, net: name)
                }
                currentNetwork = name
                declarationLine = lineNumber
                totalCapacitance = total
                groundCapacitance = 0
                resistance = 0
                section = nil
                if transform != nil {
                    localIdentifiers.removeAll(keepingCapacity: true); resistanceIdentifiers.removeAll(keepingCapacity: true)
                } else { localIdentifiers = []; resistanceIdentifiers = [] }
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
                let endpoint = try unescape(expand(fields[1], line: lineNumber), transform: transform)
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
                let value = try sourceValue(fields.last ?? "", quantity: "capacitance", line: lineNumber, transform: transform)
                guard let identifier = UInt64(fields[0]), identifier > 0,
                      localIdentifiers.insert(identifier).inserted else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber,
                        message: "Capacitance identifiers must be positive and unique within a network.")
                }
                let capacitance = try convertToSI(value, scale: capacitanceScale,
                                                  quantity: "capacitance", line: lineNumber, transform: transform)
                if fields.count == 3 { groundCapacitance += value }
                pendingCapacitances.append((
                    source: .init(declaringNet: currentNetwork, identifier: identifier, line: lineNumber),
                    first: try expand(fields[1], line: lineNumber),
                    second: fields.count == 4 ? try expand(fields[2], line: lineNumber) : nil,
                    capacitance: capacitance
                ))
            } else if section == "res" {
                guard fields.count == 4 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid resistance entry.")
                }
                let value = try sourceValue(fields.last ?? "", quantity: "resistance", line: lineNumber, transform: transform)
                guard let identifier = UInt64(fields[0]), identifier > 0,
                      resistanceIdentifiers.insert(identifier).inserted else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber,
                        message: "Resistance identifiers must be positive and unique within a network.")
                }
                let ohms = try convertToSI(value, scale: resistanceScale, quantity: "resistance", line: lineNumber, transform: transform)
                pendingResistances.append((.init(declaringNet: currentNetwork, identifier: identifier, line: lineNumber),
                    try expand(fields[1], line: lineNumber), try expand(fields[2], line: lineNumber), ohms))
                resistance += value
            }
        }
        try finishNetwork(line: lines.count)
        guard !networks.isEmpty else {
            throw TimingError.parseFailure(format: "SPEF", line: 1, message: "No *D_NET sections were found.")
        }

        func owner(of token: String, line: Int) throws -> String {
            let endpoint = try unescape(token, transform: transform)
            let candidatesLease = try transform?.reserveSet(String.self, capacity: 3)
            defer { withExtendedLifetime(candidatesLease) {} }
            var candidates: Set<String> = []
            if transform != nil { candidates.reserveCapacity(3) }
            if let connection = connections[endpoint] { candidates.insert(connection) }
            if networks[endpoint] != nil { candidates.insert(endpoint) }
            let split = try unescapedDelimiter(in: token, delimiter: delimiter, transform: transform)
            if let split {
                let suffix = token[token.index(after: split)...]
                let prefix = try unescape(transform == nil ? String(token[..<split]) : transform!.text(token[..<split]), transform: transform)
                if !suffix.isEmpty, suffix.allSatisfy(\.isNumber), networks[prefix] != nil {
                    candidates.insert(prefix)
                }
            }
            if candidates.count > 1 {
                throw TimingSPEFError.ambiguousEndpoint(line: line, endpoint: endpoint, nets: transform == nil ? candidates.sorted() : try transform!.sorted(candidates, kind: .liveOwnedBytes, by: <))
            }
            if let candidate = candidates.first { return candidate }
            // Unscoped root identities can belong to a design-known external net
            // absent from partial D_NET coverage. Logical validation owns admission.
            if split == nil { return endpoint }
            throw TimingSPEFError.unknownEndpoint(line: line, endpoint: endpoint)
        }

        if let transform {
            let storage = transform.storage
            let recordsLease = try transform.reserveDictionary(String.self,
                LibertyBuffer<TimingParasitics.CapacitanceRecord>.self, capacity: networks.count)
            let resistancesLease = try transform.reserveDictionary(String.self,
                LibertyBuffer<TimingParasitics.ResistanceRecord>.self, capacity: networks.count)
            var records: [String:LibertyBuffer<TimingParasitics.CapacitanceRecord>] = [:]
            var resistances: [String:LibertyBuffer<TimingParasitics.ResistanceRecord>] = [:]
            records.reserveCapacity(networks.count); resistances.reserveCapacity(networks.count)
            for entry in pendingCapacitances {
                try storage.step()
                let first = TimingParasitics.Endpoint(name: try unescape(entry.first, transform: transform),
                    ownerNet: try owner(of: entry.first, line: entry.source.line))
                let second: TimingParasitics.Endpoint?
                if let token = entry.second {
                    second = TimingParasitics.Endpoint(name: try unescape(token, transform: transform),
                        ownerNet: try owner(of: token, line: entry.source.line))
                } else { second = nil }
                guard first.ownerNet == entry.source.declaringNet || second?.ownerNet == entry.source.declaringNet else {
                    throw TimingSPEFError.invalidCapacitanceOwner(line: entry.source.line,
                        endpoint: first.name, declaringNet: entry.source.declaringNet)
                }
                try records[entry.source.declaringNet, default: LibertyBuffer()].append(.init(
                    source: entry.source, first: first, second: second, capacitance: entry.capacitance), storage: storage)
            }
            for entry in pendingResistances {
                try storage.step()
                let first = TimingParasitics.Endpoint(name: try unescape(entry.first, transform: transform),
                    ownerNet: try owner(of: entry.first, line: entry.source.line))
                let second = TimingParasitics.Endpoint(name: try unescape(entry.second, transform: transform),
                    ownerNet: try owner(of: entry.second, line: entry.source.line))
                try resistances[entry.source.declaringNet, default: LibertyBuffer()].append(.init(
                    source: entry.source, first: first, second: second, resistance: entry.resistance), storage: storage)
            }
            let sorted = try transform.sorted(networks.values) { try storage.step(); return $0.name < $1.name }
            let result = try transform.map(sorted, kind: .liveOwnedBytes) { network in
                let matches = try transform.filter(connections) { item in
                    try storage.step(UInt64(item.value.utf8.count)); return item.value == network.name
                }
                let names = try transform.sorted(transform.map(matches, { $0.key }), by: <)
                let endpoints = try transform.map(names, kind: .liveOwnedBytes) {
                    TimingParasitics.Endpoint(name: $0, ownerNet: network.name)
                }
                return TimingParasitics.Network(name: network.name, declaredCapacitance: network.declaredCapacitance,
                    resistanceInventory: network.resistanceInventory,
                    capacitances: try records[network.name]?.array(storage: storage) ?? [],
                    resistances: try resistances[network.name]?.array(storage: storage) ?? [], connections: endpoints)
            }
            let delimiterLease = try storage.reserve(UInt8.self, capacity: delimiter.utf8.count)
            try storage.step(UInt64(delimiter.utf8.count))
            let delimiterText = String(delimiter)
            try storage.hold(delimiterText, receipt: delimiterLease)
            // These buffers remain simultaneously charged until all resulting
            // arrays are complete; no per-stage reset or guessed peak is used.
            withExtendedLifetime((nameMapLease, networksLease, connectionsLease, capacitanceLease,
                resistanceLease, resistanceIDsLease, capacitanceIDsLease, recordsLease, resistancesLease)) {}
            return TimingParasitics(pinDelimiter: delimiterText, networks: result)
        }

        var records: [String: [TimingParasitics.CapacitanceRecord]] = [:]
        for entry in pendingCapacitances {
            let first = TimingParasitics.Endpoint(name: try unescape(entry.first, transform: transform),
                ownerNet: try owner(of: entry.first, line: entry.source.line))
            let second = try entry.second.map { token in
                TimingParasitics.Endpoint(name: try unescape(token, transform: transform),
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
        var resistances: [String: [TimingParasitics.ResistanceRecord]] = [:]
        for entry in pendingResistances {
            let first = TimingParasitics.Endpoint(name: try unescape(entry.first, transform: transform), ownerNet: try owner(of: entry.first, line: entry.source.line))
            let second = TimingParasitics.Endpoint(name: try unescape(entry.second, transform: transform), ownerNet: try owner(of: entry.second, line: entry.source.line))
            resistances[entry.source.declaringNet, default: []].append(.init(source: entry.source,
                first: first, second: second, resistance: entry.resistance))
        }
        return TimingParasitics(pinDelimiter: String(delimiter), networks: networks.values.sorted { $0.name < $1.name }.map { network in
            .init(name: network.name, declaredCapacitance: network.declaredCapacitance,
                  resistanceInventory: network.resistanceInventory,
                  capacitances: records[network.name] ?? [], resistances: resistances[network.name] ?? [],
                  connections: connections.filter { $0.value == network.name }.keys.sorted().map {
                      .init(name: $0, ownerNet: network.name)
                  })
        })
    }

    private func unescapedDelimiter(in token: String, delimiter: Character, transform: TimingTextTransform? = nil) throws -> String.Index? {
        var escaped = false
        var last: String.Index?
        for index in token.indices {
            try transform?.storage.step(UInt64(token[index].utf8.count))
            let character = token[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == delimiter { last = index }
        }
        return last
    }

    private func unescape(_ token: String, transform: TimingTextTransform? = nil) throws -> String {
        let lease = try transform?.storage.reserve(UInt8.self, capacity: token.utf8.count)
        try transform?.storage.step(UInt64(token.utf8.count))
        var result = ""
        if transform != nil { result.reserveCapacity(token.utf8.count) }
        var escaped = false
        for character in token {
            if escaped { result.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        if let transform, let lease { try transform.storage.hold(result, receipt: lease) }
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
        line: Int,
        transform: TimingTextTransform? = nil
    ) throws -> Double {
        guard let number = Double(value), number.isFinite, number > 0 else {
            throw TimingError.parseFailure(
                format: "SPEF",
                line: line,
                message: "Unit scale must contain a finite positive number."
            )
        }
        let factor: Double
        let normalized: String
        if let transform { normalized = try transform.caseMapped(unit, uppercase: true) }
        else { normalized = unit.uppercased() }
        switch (dimension, normalized) {
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
            throw try boundedFailure(line: line, literal: "Unsupported unit ''.", field: unit, transform: transform) {
                "Unsupported unit '\(unit)'."
            }
        }
        return try convertToSI(number, scale: factor, quantity: "unit scale", line: line, transform: transform)
    }

    private func sourceValue(_ token: String, quantity: String, line: Int, transform: TimingTextTransform? = nil) throws -> Double {
        guard let value = Double(token), value.isFinite, value >= 0 else {
            throw try boundedFailure(line: line, literal: "Invalid  entry.", field: quantity, transform: transform) {
                "Invalid \(quantity) entry."
            }
        }
        // Exponent digits do not make a zero significand nonzero.
        let significand = token.prefix { $0 != "e" && $0 != "E" }
        if value == 0, significand.contains(where: { $0 >= "1" && $0 <= "9" }) {
            if token.hasPrefix("-") {
                throw try boundedFailure(line: line, literal: "Invalid  entry.", field: quantity, transform: transform) {
                    "Invalid \(quantity) entry."
                }
            }
            throw try boundedFailure(line: line, literal: "Positive  is not representable as a Double.", field: quantity, transform: transform) {
                "Positive \(quantity) is not representable as a Double."
            }
        }
        return value
    }

    private func convertToSI(_ value: Double, scale: Double, quantity: String, line: Int, transform: TimingTextTransform? = nil) throws -> Double {
        let converted = value * scale
        guard converted.isFinite, value == 0 || converted > 0 else {
            throw try boundedFailure(line: line, literal: "Positive  is not representable in SI units.", field: quantity, transform: transform) {
                "Positive \(quantity) is not representable in SI units."
            }
        }
        return converted
    }
    private func boundedFailure(line: Int, literal: StaticString, field: String,
        transform: TimingTextTransform?, _ message: () -> String) throws -> any Error {
        if let transform {
            let bytes = try TimingDiagnosticTextCapacity.description(literal: literal, ints: 0, doubles: 0,
                booleans: 0, additionalUTF8: UInt64(field.utf8.count))
            return try transform.sourceFailure(utf8ByteCount: bytes) {
                TimingError.parseFailure(format: "SPEF", line: line, message: message())
            }
        }
        return TimingError.parseFailure(format: "SPEF", line: line, message: message())
    }

}

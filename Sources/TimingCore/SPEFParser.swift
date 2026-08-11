import Foundation

public struct SPEFParser: TimingParasiticParsing {
    public init() {}

    public func parse(_ data: Data) throws -> TimingParasitics {
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
        var networks: [String: TimingParasitics.Network] = [:]
        var couplings: [TimingParasitics.Coupling] = []
        var currentNetwork: String?
        var totalCapacitance = 0.0
        var groundCapacitance = 0.0
        var resistance = 0.0
        var section: String?

        func finishNetwork() {
            guard let currentNetwork else { return }
            networks[currentNetwork] = TimingParasitics.Network(
                name: currentNetwork,
                totalCapacitance: totalCapacitance * capacitanceScale,
                groundCapacitance: groundCapacitance * capacitanceScale,
                resistance: resistance * resistanceScale
            )
        }

        for (offset, rawLine) in source.split(whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = fields.first else { continue }
            if first == "*C_UNIT" || first == "*CAP_UNIT" {
                guard fields.count == 3 else {
                    throw TimingError.parseFailure(
                        format: "SPEF",
                        line: lineNumber,
                        message: "Invalid capacitance unit declaration."
                    )
                }
                capacitanceScale = try unitScale(
                    value: fields[1],
                    unit: fields[2],
                    dimension: .capacitance,
                    line: lineNumber
                )
                continue
            }
            if first == "*R_UNIT" || first == "*RES_UNIT" {
                guard fields.count == 3 else {
                    throw TimingError.parseFailure(
                        format: "SPEF",
                        line: lineNumber,
                        message: "Invalid resistance unit declaration."
                    )
                }
                resistanceScale = try unitScale(
                    value: fields[1],
                    unit: fields[2],
                    dimension: .resistance,
                    line: lineNumber
                )
                continue
            }
            if first == "*D_NET" {
                finishNetwork()
                guard fields.count >= 3,
                      let total = Double(fields[2]),
                      total.isFinite,
                      total >= 0 else {
                    throw TimingError.parseFailure(format: "SPEF", line: lineNumber, message: "Invalid *D_NET header.")
                }
                currentNetwork = fields[1]
                totalCapacitance = total
                groundCapacitance = 0
                resistance = 0
                section = nil
                continue
            }
            if first == "*END" {
                finishNetwork()
                currentNetwork = nil
                continue
            }
            guard currentNetwork != nil else { continue }
            if first == "*CAP" { section = "cap"; continue }
            if first == "*RES" { section = "res"; continue }
            if first == "*CONN" { section = "conn"; continue }
            if section == "cap" {
                guard fields.count == 3 || fields.count >= 4,
                      let value = Double(fields.last ?? ""),
                      value.isFinite,
                      value >= 0 else {
                    throw TimingError.parseFailure(
                        format: "SPEF",
                        line: lineNumber,
                        message: "Invalid capacitance entry."
                    )
                }
                if fields.count == 3 {
                    groundCapacitance += value
                } else if fields.count >= 4 {
                    couplings.append(TimingParasitics.Coupling(
                        firstNet: fields[1],
                        secondNet: fields[2],
                        capacitance: value * capacitanceScale
                    ))
                }
            } else if section == "res" {
                guard fields.count >= 4,
                      let value = Double(fields.last ?? ""),
                      value.isFinite,
                      value >= 0 else {
                    throw TimingError.parseFailure(
                        format: "SPEF",
                        line: lineNumber,
                        message: "Invalid resistance entry."
                    )
                }
                resistance += value
            }
        }
        finishNetwork()
        guard !networks.isEmpty else {
            throw TimingError.parseFailure(format: "SPEF", line: 1, message: "No *D_NET sections were found.")
        }
        return TimingParasitics(networks: networks.values.sorted { $0.name < $1.name }, couplings: couplings)
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

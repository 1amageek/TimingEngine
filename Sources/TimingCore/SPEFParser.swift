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
            if first == "*CAP_UNIT", fields.count >= 3 {
                capacitanceScale = unitScale(value: fields[1], unit: fields[2])
                continue
            }
            if first == "*RES_UNIT", fields.count >= 3 {
                resistanceScale = unitScale(value: fields[1], unit: fields[2])
                continue
            }
            if first == "*D_NET" {
                finishNetwork()
                guard fields.count >= 3, let total = Double(fields[2]) else {
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
            guard let value = Double(fields.last ?? "") else { continue }
            if section == "cap" {
                if fields.count == 3 {
                    groundCapacitance += value
                } else if fields.count >= 4 {
                    couplings.append(TimingParasitics.Coupling(
                        firstNet: fields[1],
                        secondNet: fields[2],
                        capacitance: value * capacitanceScale
                    ))
                }
            } else if section == "res", fields.count >= 4 {
                resistance += value
            }
        }
        finishNetwork()
        guard !networks.isEmpty else {
            throw TimingError.parseFailure(format: "SPEF", line: 1, message: "No *D_NET sections were found.")
        }
        return TimingParasitics(networks: networks.values.sorted { $0.name < $1.name }, couplings: couplings)
    }

    private func unitScale(value: String, unit: String) -> Double {
        let number = Double(value) ?? 1
        switch unit.uppercased() {
        case "F": return number
        case "MF": return number * 1e-3
        case "UF": return number * 1e-6
        case "NF": return number * 1e-9
        case "PF": return number * 1e-12
        case "FF": return number * 1e-15
        case "OHM": return number
        case "KOHM": return number * 1e3
        case "MOHM": return number * 1e6
        default: return number
        }
    }
}

import Testing
@testable import TimingCore
@testable import STAEngine

@Suite("Fresh conservative residual replay determinism", .timeLimit(.minutes(1)))
struct STAConservativeReplayDeterminismTests {
    private typealias N = NativeSTAConservativeNumerics
    private typealias I = TimingNumericInterval
    private typealias S = NativeSTAConservativeSparseNumerics
    private typealias G = NativeSTAConservativeSparseGraph
    private typealias C = NativeSTAConservativeResidualCertificate
    private typealias R = NativeSTAConservativeResidualResponse
    private typealias K = NativeSTAConservativeCoupling
    private typealias E = TimingParasitics.Endpoint

    private struct Field {
        let name: String
        let bits: [UInt64]
    }
    private struct Snapshot {
        var fields: [Field] = []
        mutating func integers(_ name: String, _ values: [Int]) {
            fields.append(Field(name: name, bits: values.map { UInt64(bitPattern: Int64($0)) }))
        }
        mutating func doubles(_ name: String, _ values: [Double]) {
            fields.append(Field(name: name, bits: values.map(\.bitPattern)))
        }
        mutating func matrix(_ name: String, _ value: N.Matrix) {
            integers(name + ".shape", [value.rows, value.columns])
            doubles(name + ".intervals", value.values.flatMap { [$0.lowerBound, $0.upperBound] })
        }
        mutating func csr(_ name: String, _ value: S.CSR) {
            integers(name + ".shape", [value.rows, value.columns])
            integers(name + ".rowOffsets", value.rowOffsets)
            integers(name + ".columnIndices", value.columnIndices)
            doubles(name + ".intervals", value.values.flatMap { [$0.lowerBound, $0.upperBound] })
        }
        mutating func bounds(_ name: String, _ value: K.Bounds) {
            doubles(name, [value.delay.lowerBound, value.delay.upperBound,
                value.slew.lowerBound, value.slew.upperBound, value.voltageErrorUpperBound,
                value.minimumCrossingDerivative, value.maximumAbsoluteDerivative,
                value.admittedSourceSlew.lowerBound, value.admittedSourceSlew.upperBound])
        }
        func firstDifference(from other: Snapshot) -> String? {
            guard fields.count == other.fields.count else { return "snapshot field count \(fields.count) versus \(other.fields.count)" }
            for i in fields.indices {
                let first = fields[i], second = other.fields[i]
                guard first.name == second.name else { return "field ordering \(first.name) versus \(second.name)" }
                guard first.bits.count == second.bits.count else { return first.name + ": length differs" }
                for index in first.bits.indices where first.bits[index] != second.bits[index] {
                    return first.name + "[\(index)]: 0x" + String(first.bits[index], radix: 16)
                        + " versus 0x" + String(second.bits[index], radix: 16)
                }
            }
            return nil
        }
    }

    #if os(macOS)
    private func replay(nodesPerNet: Int) throws -> Snapshot {
        let limits = try STAExecutionLimits(maximumPathStates: 16_000_000, maximumPathWorkUnits: 1_000_000_000)
        let n = N(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: nil)
        var work: UInt64 = 0
        var ordinal = 0
        let own = E(name: "own", ownerNet: "victim")
        let aggressor = E(name: "other", ownerNet: "aggressor")
        let victim = (0..<nodesPerNet).map { E(name: "v\($0)", ownerNet: "victim") }
        let other = (0..<nodesPerNet).map { E(name: "a\($0)", ownerNet: "aggressor") }
        func id() -> TimingParasitics.SourceID {
            defer { ordinal += 1 }
            return .init(declaringNet: "replay-physical", identifier: UInt64(ordinal), line: ordinal + 1)
        }
        var victimCaps: [TimingParasitics.CapacitanceRecord] = []
        var otherCaps: [TimingParasitics.CapacitanceRecord] = []
        var victimResistance: [TimingParasitics.ResistanceRecord] = []
        var otherResistance: [TimingParasitics.ResistanceRecord] = []
        for i in 0..<nodesPerNet {
            let capacitance = 1e-14 * (1 + Double(i) / 32)
            victimCaps.append(.init(source: id(), first: victim[i], capacitance: capacitance))
            victimCaps.append(.init(source: id(), first: victim[i], second: other[i], capacitance: 1e-15))
            otherCaps.append(.init(source: id(), first: other[i], capacitance: capacitance))
            let resistance = 100.0 + 7 * Double(i)
            victimResistance.append(.init(source: id(), first: i == 0 ? own : victim[i - 1], second: victim[i], resistance: resistance))
            otherResistance.append(.init(source: id(), first: i == 0 ? aggressor : other[i - 1], second: other[i], resistance: resistance))
        }
        let inventory = TimingParasitics(networks: [
            .init(name: "victim", capacitances: victimCaps, resistances: victimResistance, connections: [own] + victim),
            .init(name: "aggressor", capacitances: otherCaps, resistances: otherResistance, connections: [aggressor] + other)
        ])
        let endpoints = [own] + victim + [aggressor] + other
        let physical = victim + other
        // Each replay constructs fresh dictionaries and fresh native sessions from identical semantic input bits.
        let originalIndex = Dictionary(uniqueKeysWithValues: endpoints.enumerated().map { ($0.element, $0.offset) })
        let rows = Dictionary(uniqueKeysWithValues: physical.enumerated().map { ($0.element, $0.offset) })
        let sourceIndex = [own: 0, aggressor: 1]
        var incidence = try n.matrix(physical.count, 2)
        for row in physical.indices { incidence[row, row < nodesPerNet ? 0 : 1] = try I(point: 1) }
        let reduced = try G(numerical: n).reduce(parasitics: inventory, originalIndex: originalIndex,
            ideal: Array(endpoints.indices), idealSource: [0: 0, nodesPerNet + 1: 1], rows: rows,
            sourceIndex: sourceIndex, receiverLoads: [:], skipped: [], dcIncidence: incidence, work: &work)
        var result = Snapshot()
        result.doubles("inputs.capacitances", inventory.networks.flatMap { $0.capacitances.map(\.capacitance) })
        result.doubles("inputs.resistances", inventory.networks.flatMap { $0.resistances.map(\.resistance) })
        result.integers("reduced.dynamicRows", reduced.dynamicRows)
        result.csr("reduced.G", reduced.conductance)
        result.csr("reduced.C", reduced.capacitance)
        result.matrix("reduced.L", reduced.forcing)
        result.csr("reduced.W", reduced.reconstruction)
        result.csr("reduced.P", reduced.dcIncidence)
        result.integers("reduced.capBlockSizes", reduced.capBlocks.map(\.count))
        result.integers("reduced.capBlocks", reduced.capBlocks.flatMap { $0 })
        let horizon = 48e-12 * Double(nodesPerNet * nodesPerNet)
        var times = [0.0], time = 1e-12 / 16
        while time < horizon { times.append(time); time *= 1.125 }
        times.append(horizon)
        result.doubles("times", times)
        let checked = try C(numerical: n).prepare(reduced, receiverRows: Array(physical.indices), times: times, work: &work)
        result.integers("certificate.receiverRows", checked.receiverRows)
        for (index, segment) in checked.segments.enumerated() {
            result.doubles("certificate.segment\(index).time", [segment.start, segment.end])
            for (coefficient, matrix) in segment.bernstein.enumerated() {
                result.matrix("certificate.segment\(index).B\(coefficient)", matrix)
            }
        }
        result.matrix("certificate.initialError", checked.errors.initial)
        result.matrix("certificate.solveError", checked.errors.solve)
        result.matrix("certificate.interpolationError", checked.errors.interpolation)
        result.matrix("certificate.tailError", checked.errors.tail)
        result.matrix("certificate.direct", checked.direct)
        let facts = try R(numerical: n).prepare(checked, work: &work)
        result.matrix("response.hError", facts.hError)
        result.matrix("response.gL1", facts.gL1)
        result.matrix("response.hL1", facts.hL1)
        result.matrix("response.hPrimitiveOscillation", facts.hPrimitiveOscillation)
        let thresholds = TimingCharacterizationThresholds(inputRise: 50, inputFall: 50,
            outputRise: 50, outputFall: 50, slewLowerRise: 20, slewUpperRise: 80,
            slewLowerFall: 20, slewUpperFall: 80)
        var slopes = try n.matrix(2, 1)
        let slope = try K().thresholdSpan(thresholds, rising: true).divided(by: I(point: 0.6))
        slopes[0, 0] = slope; slopes[1, 0] = slope
        result.matrix("sourceSlopes", slopes)
        var endpointSource = Dictionary(uniqueKeysWithValues: victim.map { ($0, 0) } + other.map { ($0, 1) })
        endpointSource[own] = 0; endpointSource[aggressor] = 1
        let prepared = K.ResidualPrepared(parasitics: inventory, sources: [
            .dynamic(endpoint: own, sourceIsPort: true, riseSlew: 0.6...0.6, fallSlew: 0.6...0.6),
            .dynamic(endpoint: aggressor, sourceIsPort: false, riseSlew: 0.6...0.6, fallSlew: 0.6...0.6)
        ], receiverLoads: [:], endpointRows: rows, endpointSource: endpointSource, sourceIndices: sourceIndex,
            sourceSlopes: slopes, dcIncidence: reduced.dcIncidence, thresholds: thresholds,
            options: try .init(maximumNodes: endpoints.count, maximumBasisSweeps: 8, maximumCertificateAttempts: 8,
                operatingHistory: .boundedOperatingHistory), numerics: n, facts: facts)
        let conditional = try K().addingSourceHistory(prepared: .residual(prepared),
            histories: [aggressor: .minimumPlateau(seconds: horizon)], work: &work)
        for (label, model) in [("unconditional", K.Prepared.residual(prepared)), ("history", conditional)] {
            for edge in [TimingEdge.rise, .fall] {
                let name = edge == .rise ? "rise" : "fall"
                result.bounds("bounds.\(label).\(name)", try K().bounds(prepared: model,
                    source: own, sink: victim[nodesPerNet - 1], edge: edge, sourceSlew: 0.6...0.6, work: &work))
            }
        }
        return result
    }

    @Test("two fresh native preparations retain identical bits at every numerical boundary", arguments: [1, 4])
    func freshPhysicalReplay(_ nodesPerNet: Int) throws {
        let first = try replay(nodesPerNet: nodesPerNet)
        let second = try replay(nodesPerNet: nodesPerNet)
        if let difference = first.firstDifference(from: second) {
            Issue.record("Fresh \(2 * nodesPerNet)-node replay first differs at \(difference)")
        }
    }
    #endif
}

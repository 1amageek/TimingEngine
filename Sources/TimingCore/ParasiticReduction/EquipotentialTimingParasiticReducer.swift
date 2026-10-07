import Foundation

public struct EquipotentialTimingParasiticReducer: TimingParasiticReducing {
    public init() {}

    public func reduce(_ source: TimingParasitics) throws -> TimingLumpedParasitics {
        do { return try reduceInventory(source) }
        catch let error as TimingParasiticReductionError { throw TimingError.parasiticReduction(error) }
    }

    private struct Pair: Hashable, Comparable {
        let first: TimingParasitics.Endpoint
        let second: TimingParasitics.Endpoint
        init(_ a: TimingParasitics.Endpoint, _ b: TimingParasitics.Endpoint) {
            first = min(a, b); second = max(a, b)
        }
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.first == rhs.first ? lhs.second < rhs.second : lhs.first < rhs.first
        }
    }

    private func reduceInventory(_ source: TimingParasitics) throws -> TimingLumpedParasitics {
        guard source.schemaVersion == TimingParasitics.currentSchemaVersion,
              Set(source.networks.map(\.name)).count == source.networks.count else {
            throw TimingParasiticReductionError.invalidInventory("Unsupported schema or duplicate networks.")
        }
        var loads: [String: Double] = [:], grounds: [String: Double] = [:]
        var grouped: [Pair: [TimingParasitics.CapacitanceRecord]] = [:]
        var collapsed: [TimingParasitics.CapacitanceRecord] = []
        var comparisons: [TimingParasiticReductionEvidence.InventoryComparison] = []
        var mirrors: [[TimingParasitics.SourceID]] = []
        var endpointOwners: [String: String] = [:]
        var incidentInventory: [String: Double] = [:]

        func add(_ value: Double, to net: String, in values: inout [String: Double]) throws {
            let sum = (values[net] ?? 0) + value
            guard sum.isFinite else { throw TimingParasiticReductionError.numericOverflow(net: net) }
            values[net] = sum
        }
        for network in source.networks.sorted(by: { $0.name < $1.name }) {
            guard !network.name.isEmpty, network.declaredCapacitance.isFinite, network.declaredCapacitance >= 0,
                  network.resistanceInventory.isFinite, network.resistanceInventory >= 0 else {
                throw TimingParasiticReductionError.invalidInventory("Invalid network declaration.")
            }
            loads[network.name] = loads[network.name] ?? 0
            grounds[network.name] = 0
            var identifiers: Set<UInt64> = []
            var inventory = 0.0
            for record in network.capacitances.sorted(by: { $0.source < $1.source }) {
                guard record.source.declaringNet == network.name, record.source.identifier > 0,
                      record.source.line > 0, identifiers.insert(record.source.identifier).inserted,
                      record.capacitance.isFinite, record.capacitance >= 0 else {
                    throw TimingParasiticReductionError.invalidInventory("Invalid or duplicate CAP source record.")
                }
                inventory += record.capacitance
                guard inventory.isFinite else { throw TimingParasiticReductionError.numericOverflow(net: network.name) }
                for endpoint in [record.first] + (record.second.map { [$0] } ?? []) {
                    guard !endpoint.name.isEmpty, !endpoint.ownerNet.isEmpty else {
                        throw TimingParasiticReductionError.invalidInventory("Empty CAP endpoint identity.")
                    }
                    if let previous = endpointOwners[endpoint.name], previous != endpoint.ownerNet {
                        throw TimingParasiticReductionError.invalidInventory("Conflicting CAP endpoint ownership.")
                    }
                    endpointOwners[endpoint.name] = endpoint.ownerNet
                }
                guard record.first.ownerNet == network.name || record.second?.ownerNet == network.name else {
                    throw TimingParasiticReductionError.invalidInventory("CAP record has no endpoint in its declaring network.")
                }
                if let second = record.second {
                    if record.first.ownerNet == second.ownerNet {
                        collapsed.append(record)
                        try add(record.capacitance, to: network.name, in: &incidentInventory)
                    }
                    else { grouped[Pair(record.first, second), default: []].append(record) }
                } else {
                    try add(record.capacitance, to: network.name, in: &incidentInventory)
                    try add(record.capacitance, to: network.name, in: &grounds)
                    try add(record.capacitance, to: network.name, in: &loads)
                }
            }
            comparisons.append(.init(net: network.name, declaredCapacitance: network.declaredCapacitance,
                                     localRecordCapacitance: inventory))
        }

        var netPairs: [Pair: (capacitance: Double, victims: Set<String>, sources: [TimingParasitics.SourceID])] = [:]
        for pair in grouped.keys.sorted() {
            let records = grouped[pair]!
            let first = records.filter { $0.source.declaringNet == pair.first.ownerNet }.sorted {
                $0.capacitance == $1.capacitance ? $0.source < $1.source : $0.capacitance < $1.capacitance
            }
            let second = records.filter { $0.source.declaringNet == pair.second.ownerNet }.sorted {
                $0.capacitance == $1.capacitance ? $0.source < $1.source : $0.capacitance < $1.capacitance
            }
            let physical: [TimingParasitics.CapacitanceRecord]
            if !first.isEmpty && !second.isEmpty {
                guard first.map(\.capacitance) == second.map(\.capacitance) else {
                    throw TimingParasiticReductionError.ambiguousMirroredListings(first: pair.first, second: pair.second)
                }
                physical = first
                for (a, b) in zip(first, second) { mirrors.append([a.source, b.source].sorted()) }
            } else { physical = first.isEmpty ? second : first }
            var capacitance = 0.0
            for record in physical { capacitance += record.capacitance }
            guard capacitance.isFinite else { throw TimingParasiticReductionError.numericOverflow(net: pair.first.ownerNet) }
            try add(capacitance, to: pair.first.ownerNet, in: &loads)
            try add(capacitance, to: pair.second.ownerNet, in: &loads)
            try add(capacitance, to: pair.first.ownerNet, in: &incidentInventory)
            try add(capacitance, to: pair.second.ownerNet, in: &incidentInventory)
            let netPair = Pair(.init(name: pair.first.ownerNet, ownerNet: pair.first.ownerNet),
                               .init(name: pair.second.ownerNet, ownerNet: pair.second.ownerNet))
            var combined = netPairs[netPair] ?? (0, [], [])
            combined.capacitance += capacitance
            guard combined.capacitance.isFinite else {
                throw TimingParasiticReductionError.numericOverflow(net: pair.first.ownerNet)
            }
            combined.victims.formUnion(records.map(\.source.declaringNet))
            combined.sources.append(contentsOf: records.map(\.source))
            netPairs[netPair] = combined
        }
        for network in source.networks where network.declaredCapacitance > 0 && incidentInventory[network.name] == nil {
            throw TimingParasiticReductionError.missingCapacitanceRecords(net: network.name)
        }
        comparisons = comparisons.map { comparison in
            .init(net: comparison.net, declaredCapacitance: comparison.declaredCapacitance,
                  localRecordCapacitance: comparison.localRecordCapacitance,
                  incidentOperatorCapacitance: incidentInventory[comparison.net] ?? 0)
        }
        let couplings = netPairs.keys.sorted().map { pair in
            let combined = netPairs[pair]!
            return TimingLumpedParasitics.Coupling(firstNet: pair.first.ownerNet, secondNet: pair.second.ownerNet,
                capacitance: combined.capacitance, declaredVictims: combined.victims.sorted(), sourceIDs: combined.sources.sorted())
        }
        let evidence = TimingParasiticReductionEvidence(collapsedIntraNetCapacitances: collapsed,
            mirroredSourceGroups: mirrors, inventoryComparisons: comparisons, effectiveLoads: loads)
        return TimingLumpedParasitics(effectiveLoads: loads, groundCapacitances: grounds, couplings: couplings, evidence: evidence)
    }
}

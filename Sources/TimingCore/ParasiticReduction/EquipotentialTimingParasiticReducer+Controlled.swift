import Foundation

extension EquipotentialTimingParasiticReducer {
    public func reduce(_ source: TimingParasitics,
        resources: any LibertySourceResourceAccounting
    ) throws -> TimingTransformValue<TimingLumpedParasitics> {
        let transform = try TimingTextTransform(resources: resources)
        do {
            let result = try controlledInventory(source, transform: transform)
            return try transform.finish(result)
        } catch let error as TimingParasiticReductionError {
            throw transform.failure(TimingError.parasiticReduction(error))
        } catch let error as TimingControlledTransformFailure { throw error }
        catch { throw transform.failure(error) }
    }

    private struct ControlledPair: Hashable, Comparable, Sendable {
        let first: TimingParasitics.Endpoint
        let second: TimingParasitics.Endpoint
        init(_ a: TimingParasitics.Endpoint, _ b: TimingParasitics.Endpoint) {
            first = min(a, b); second = max(a, b)
        }
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.first == rhs.first ? lhs.second < rhs.second : lhs.first < rhs.first
        }
    }

    private struct Combined: Sendable {
        var capacitance = 0.0
        var victims = LibertyBuffer<String>()
        var sources = LibertyBuffer<TimingParasitics.SourceID>()
    }

    private func controlledInventory(_ source: TimingParasitics,
        transform t: TimingTextTransform) throws -> TimingLumpedParasitics {
        let storage = t.storage
        try storage.step()
        guard source.schemaVersion == 2 || source.schemaVersion == TimingParasitics.currentSchemaVersion else {
            throw TimingParasiticReductionError.invalidInventory("Unsupported schema or duplicate networks.")
        }
        let networkNamesLease = try t.reserveSet(String.self, capacity: source.networks.count)
        var networkNames: Set<String> = []; networkNames.reserveCapacity(source.networks.count)
        var recordCount = 0
        for network in source.networks {
            try storage.step(UInt64(network.name.utf8.count))
            guard networkNames.insert(network.name).inserted else {
                throw TimingParasiticReductionError.invalidInventory("Unsupported schema or duplicate networks.")
            }
            recordCount = try LibertyParseStorage.add(recordCount, network.capacitances.count)
        }
        // At most two distinct endpoint owner keys and load keys per CAP, plus
        // every declared network. These are requested capacities, not RSS claims.
        let endpoints = try LibertyParseStorage.add(recordCount, recordCount)
        let netCapacity = try LibertyParseStorage.add(endpoints, source.networks.count)
        let loadsLease = try t.reserveDictionary(String.self, Double.self, capacity: netCapacity, kind: .liveOwnedBytes)
        let groundsLease = try t.reserveDictionary(String.self, Double.self, capacity: source.networks.count, kind: .liveOwnedBytes)
        let incidentLease = try t.reserveDictionary(String.self, Double.self, capacity: netCapacity)
        let ownersLease = try t.reserveDictionary(String.self, String.self, capacity: endpoints)
        let groupedLease = try t.reserveDictionary(ControlledPair.self, LibertyBuffer<TimingParasitics.CapacitanceRecord>.self, capacity: recordCount)
        let pairsLease = try t.reserveDictionary(ControlledPair.self, Combined.self, capacity: recordCount)
        var loads: [String:Double] = [:]; loads.reserveCapacity(netCapacity)
        var grounds: [String:Double] = [:]; grounds.reserveCapacity(source.networks.count)
        var incident: [String:Double] = [:]; incident.reserveCapacity(netCapacity)
        var owners: [String:String] = [:]; owners.reserveCapacity(endpoints)
        var grouped: [ControlledPair:LibertyBuffer<TimingParasitics.CapacitanceRecord>] = [:]; grouped.reserveCapacity(recordCount)
        var netPairs: [ControlledPair:Combined] = [:]; netPairs.reserveCapacity(recordCount)
        var collapsed = LibertyBuffer<TimingParasitics.CapacitanceRecord>()
        var comparisons = LibertyBuffer<TimingParasiticReductionEvidence.InventoryComparison>()
        var mirrors = LibertyBuffer<[TimingParasitics.SourceID]>()
        func add(_ value: Double, _ net: String, _ target: inout [String:Double]) throws {
            try storage.step(UInt64(net.utf8.count))
            let sum = (target[net] ?? 0) + value
            guard sum.isFinite else { throw TimingParasiticReductionError.numericOverflow(net: net) }
            target[net] = sum
        }
        let networks = try t.sorted(source.networks) { try storage.step(); return $0.name < $1.name }
        for network in networks {
            try storage.step()
            guard !network.name.isEmpty, network.declaredCapacitance.isFinite, network.declaredCapacitance >= 0,
                  network.resistanceInventory.isFinite, network.resistanceInventory >= 0 else {
                throw TimingParasiticReductionError.invalidInventory("Invalid network declaration.")
            }
            loads[network.name] = loads[network.name] ?? 0; grounds[network.name] = 0
            let idsLease = try t.reserveSet(UInt64.self, capacity: network.capacitances.count)
            var identifiers: Set<UInt64> = []; identifiers.reserveCapacity(network.capacitances.count)
            var inventory = 0.0
            let records = try t.sorted(network.capacitances) { try storage.step(); return $0.source < $1.source }
            for record in records {
                try storage.step()
                guard record.source.declaringNet == network.name, record.source.identifier > 0,
                      record.source.line > 0, identifiers.insert(record.source.identifier).inserted,
                      record.capacitance.isFinite, record.capacitance >= 0 else {
                    throw TimingParasiticReductionError.invalidInventory("Invalid or duplicate CAP source record.")
                }
                inventory += record.capacitance
                guard inventory.isFinite else { throw TimingParasiticReductionError.numericOverflow(net: network.name) }
                func endpoint(_ value: TimingParasitics.Endpoint) throws {
                    try storage.step(UInt64(value.name.utf8.count + value.ownerNet.utf8.count))
                    guard !value.name.isEmpty, !value.ownerNet.isEmpty else {
                        throw TimingParasiticReductionError.invalidInventory("Empty CAP endpoint identity.")
                    }
                    if let previous = owners[value.name], previous != value.ownerNet {
                        throw TimingParasiticReductionError.invalidInventory("Conflicting CAP endpoint ownership.")
                    }
                    owners[value.name] = value.ownerNet
                }
                try endpoint(record.first); if let second = record.second { try endpoint(second) }
                guard record.first.ownerNet == network.name || record.second?.ownerNet == network.name else {
                    throw TimingParasiticReductionError.invalidInventory("CAP record has no endpoint in its declaring network.")
                }
                if let second = record.second {
                    if record.first.ownerNet == second.ownerNet {
                        try collapsed.append(record, storage: storage)
                        try add(record.capacitance, network.name, &incident)
                    } else {
                        try grouped[ControlledPair(record.first, second), default: LibertyBuffer()].append(record, storage: storage)
                    }
                } else {
                    try add(record.capacitance, network.name, &incident)
                    try add(record.capacitance, network.name, &grounds)
                    try add(record.capacitance, network.name, &loads)
                }
            }
            try comparisons.append(.init(net: network.name, declaredCapacitance: network.declaredCapacitance,
                localRecordCapacitance: inventory), storage: storage)
            withExtendedLifetime(idsLease) {}
        }
        let orderedPairs = try t.sorted(grouped.keys) { try storage.step(); return $0 < $1 }
        for pair in orderedPairs {
            try storage.step()
            guard let records = grouped[pair] else { preconditionFailure("Grouped source key disappeared") }
            let first = try t.sorted(t.filter(records) { try storage.step(); return $0.source.declaringNet == pair.first.ownerNet }) {
                try storage.step(); return $0.capacitance == $1.capacitance ? $0.source < $1.source : $0.capacitance < $1.capacitance
            }
            let second = try t.sorted(t.filter(records) { try storage.step(); return $0.source.declaringNet == pair.second.ownerNet }) {
                try storage.step(); return $0.capacitance == $1.capacitance ? $0.source < $1.source : $0.capacitance < $1.capacitance
            }
            let physical: [TimingParasitics.CapacitanceRecord]
            if !first.isEmpty && !second.isEmpty {
                guard first.count == second.count else {
                    throw TimingParasiticReductionError.ambiguousMirroredListings(first: pair.first, second: pair.second)
                }
                for index in first.indices {
                    try storage.step()
                    guard first[index].capacitance == second[index].capacitance else {
                        throw TimingParasiticReductionError.ambiguousMirroredListings(first: pair.first, second: pair.second)
                    }
                    var ids = LibertyBuffer<TimingParasitics.SourceID>()
                    try ids.append(first[index].source, storage: storage); try ids.append(second[index].source, storage: storage)
                    let sorted = try t.sorted(ids, kind: .liveOwnedBytes) { try storage.step(); return $0 < $1 }
                    try mirrors.append(sorted, storage: storage)
                }
                physical = first
            } else { physical = first.isEmpty ? second : first }
            var capacitance = 0.0
            for record in physical { try storage.step(); capacitance += record.capacitance }
            guard capacitance.isFinite else { throw TimingParasiticReductionError.numericOverflow(net: pair.first.ownerNet) }
            try add(capacitance, pair.first.ownerNet, &loads); try add(capacitance, pair.second.ownerNet, &loads)
            try add(capacitance, pair.first.ownerNet, &incident); try add(capacitance, pair.second.ownerNet, &incident)
            let netPair = ControlledPair(.init(name: pair.first.ownerNet, ownerNet: pair.first.ownerNet),
                .init(name: pair.second.ownerNet, ownerNet: pair.second.ownerNet))
            var combined = netPairs[netPair] ?? Combined()
            combined.capacitance += capacitance
            guard combined.capacitance.isFinite else { throw TimingParasiticReductionError.numericOverflow(net: pair.first.ownerNet) }
            for record in records {
                try combined.victims.append(record.source.declaringNet, storage: storage)
                try combined.sources.append(record.source, storage: storage)
            }
            netPairs[netPair] = combined
        }
        for network in source.networks {
            try storage.step()
            if network.declaredCapacitance > 0 && incident[network.name] == nil {
                throw TimingParasiticReductionError.missingCapacitanceRecords(net: network.name)
            }
        }
        let finalComparisons = try t.map(comparisons, kind: .liveOwnedBytes) { value in
            try storage.step()
            return TimingParasiticReductionEvidence.InventoryComparison(net: value.net,
                declaredCapacitance: value.declaredCapacitance, localRecordCapacitance: value.localRecordCapacitance,
                incidentOperatorCapacitance: incident[value.net] ?? 0)
        }
        let orderedNetPairs = try t.sorted(netPairs.keys) { try storage.step(); return $0 < $1 }
        let couplings = try t.map(orderedNetPairs, kind: .liveOwnedBytes) { pair in
            guard let combined = netPairs[pair] else { preconditionFailure("Grouped net key disappeared") }
            let sortedVictims = try t.sorted(combined.victims) { try storage.step(); return $0 < $1 }
            var unique = LibertyBuffer<String>()
            for victim in sortedVictims {
                try storage.step()
                if unique.last != victim { try unique.append(victim, storage: storage) }
            }
            return TimingLumpedParasitics.Coupling(firstNet: pair.first.ownerNet, secondNet: pair.second.ownerNet,
                capacitance: combined.capacitance, declaredVictims: try unique.array(storage: storage),
                sourceIDs: try t.sorted(combined.sources, kind: .liveOwnedBytes) { try storage.step(); return $0 < $1 })
        }
        let evidence = TimingParasiticReductionEvidence(collapsedIntraNetCapacitances: try collapsed.array(storage: storage),
            mirroredSourceGroups: try mirrors.array(storage: storage), inventoryComparisons: finalComparisons, effectiveLoads: loads)
        try storage.hold(loads, receipt: loadsLease); try storage.hold(grounds, receipt: groundsLease)
        withExtendedLifetime((networkNamesLease, incidentLease, ownersLease, groupedLease, pairsLease)) {}
        return TimingLumpedParasitics(effectiveLoads: loads, groundCapacitances: grounds, couplings: couplings, evidence: evidence)
    }
}

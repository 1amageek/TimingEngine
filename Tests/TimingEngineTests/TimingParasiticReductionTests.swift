import Foundation
import Testing
import TimingCore

struct TimingParasiticReductionTests {
    private func parse(_ source: String) throws -> TimingParasitics {
        try SPEFParser().parse(Data(source.utf8))
    }

    @Test("Distributed same-net capacitance preserves endpoints, value and loss evidence")
    func distributedInventory() throws {
        let value = try parse("*D_NET root 10\n*CAP\n1 root:1 3\n2 root:1 root:2 7\n*RES\n1 root:1 root:2 100\n*END\n")
        let record = try #require(value.networks.first?.capacitances.last)
        #expect(record.first == .init(name: "root:1", ownerNet: "root"))
        #expect(record.second == .init(name: "root:2", ownerNet: "root"))
        #expect(record.source == .init(declaringNet: "root", identifier: 2, line: 4))
        #expect(record.capacitance == 7)
        let reduced = try EquipotentialTimingParasiticReducer().reduce(value)
        #expect(reduced.effectiveLoads == ["root": 3])
        #expect(reduced.groundCapacitances == ["root": 3])
        #expect(reduced.couplings.isEmpty)
        #expect(reduced.evidence.collapsedIntraNetCapacitances == [record])
        #expect(!reduced.evidence.isDistributedSignoffEvidence)
        #expect(try JSONDecoder().decode(TimingParasitics.self, from: JSONEncoder().encode(value)) == value)
        #expect(try JSONDecoder().decode(TimingParasiticReductionEvidence.self, from: JSONEncoder().encode(reduced.evidence)) == reduced.evidence)
    }

    @Test("Incoming-only listing and bare external partial coverage receive actual incident load")
    func asymmetricAndPartialCoverage() throws {
        let full = try parse("*D_NET a 5\n*CAP\n1 a:1 3\n2 a:1 b:1 2\n*END\n*D_NET b 2\n*END\n")
        let reduced = try EquipotentialTimingParasiticReducer().reduce(full)
        #expect(reduced.effectiveLoads == ["a": 5, "b": 2])
        let b = try #require(reduced.evidence.inventoryComparisons.first { $0.net == "b" })
        #expect(b.localRecordCapacitance == 0)
        #expect(b.incidentOperatorCapacitance == 2)
        #expect(b.difference == 0)
        #expect(b.hasIncomingOnlyListing)
        #expect(full.network(named: "b")?.resistanceInventory == 0)
        let partial = try parse("*D_NET a 999\n*CAP\n1 a external 2\n*END\n")
        let partialReduced = try EquipotentialTimingParasiticReducer().reduce(partial)
        #expect(partialReduced.effectiveLoads == ["a": 2, "external": 2])
        #expect(partial.network(named: "external") == nil)
        #expect(partialReduced.groundCapacitances["external"] == nil)
        #expect(partialReduced.evidence.inventoryComparisons.first?.difference == 997)
    }

    @Test("Mirrored multiset collapse preserves same-owner parallel physical operators")
    func mirroredAndParallel() throws {
        let oneSide = "*D_NET a 4\n*CAP\n1 a:1 b:1 1\n2 a:1 b:1 1\n3 a:2 b:2 2\n*END\n*D_NET b 4\n"
        let one = try EquipotentialTimingParasiticReducer().reduce(parse(oneSide + "*END\n"))
        let mirrored = try EquipotentialTimingParasiticReducer().reduce(parse(oneSide + "*CAP\n1 b:1 a:1 1\n2 b:1 a:1 1\n3 b:2 a:2 2\n*END\n"))
        #expect(one.effectiveLoads == ["a": 4, "b": 4])
        #expect(mirrored.effectiveLoads == one.effectiveLoads)
        #expect(one.couplings.count == 1)
        #expect(one.couplings.first?.capacitance == 4)
        #expect(one.couplings.first?.sourceIDs.count == 3)
        #expect(mirrored.couplings.first?.sourceIDs.count == 6)
        #expect(mirrored.evidence.mirroredSourceGroups.count == 3)
        #expect(throws: TimingError.parasiticReduction(.ambiguousMirroredListings(
            first: .init(name: "a:1", ownerNet: "a"), second: .init(name: "b:1", ownerNet: "b")))) {
            _ = try EquipotentialTimingParasiticReducer().reduce(parse(oneSide + "*CAP\n1 b:1 a:1 1\n*END\n"))
        }
    }

    @Test("Positive declarations without any incident source records are refused only at reduction")
    func missingInventory() throws {
        let source = try parse("*D_NET a 1\n*END\n")
        #expect(source.networks.first?.declaredCapacitance == 1)
        #expect(throws: TimingError.parasiticReduction(.missingCapacitanceRecords(net: "a"))) {
            _ = try EquipotentialTimingParasiticReducer().reduce(source)
        }
        #expect(try EquipotentialTimingParasiticReducer().reduce(parse("*D_NET a 0\n*END\n")).effectiveLoads == ["a": 0])
    }

    @Test("Ground CAP owner and source IDs are validated rather than inventing a net")
    func groundOwnership() {
        #expect(throws: TimingError.spefOwnership(.unknownEndpoint(line: 3, endpoint: "missing:1"))) {
            _ = try parse("*D_NET a 1\n*CAP\n1 missing:1 1\n*END\n")
        }
        #expect(throws: TimingError.spefOwnership(.invalidCapacitanceOwner(line: 3, endpoint: "b", declaringNet: "a"))) {
            _ = try parse("*D_NET a 1\n*CAP\n1 b 1\n*END\n*D_NET b 0\n*END\n")
        }
        #expect(throws: TimingError.self) {
            _ = try parse("*D_NET a 2\n*CAP\n1 a 1\n1 a 1\n*END\n")
        }
    }

    @Test("Old source schema, nonfinite values and numeric aggregate overflow cannot be admitted")
    func schemaAndNumericBounds() throws {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TimingParasitics.self, from: Data("{\"schemaVersion\":1,\"networks\":[]}".utf8))
        }
        let endpoint = TimingParasitics.Endpoint(name: "a", ownerNet: "a")
        for value in [Double.nan, .infinity, -1] {
            let source = TimingParasitics(networks: [.init(name: "a", capacitances: [
                .init(source: .init(declaringNet: "a", identifier: 1, line: 1), first: endpoint, capacitance: value)
            ])])
            #expect(throws: TimingError.self) { _ = try EquipotentialTimingParasiticReducer().reduce(source) }
        }
        #expect(throws: TimingError.self) {
            _ = try EquipotentialTimingParasiticReducer().reduce(parse("*D_NET a 0\n*CAP\n1 a 1e308\n2 a external 1e308\n*END\n"))
        }
    }
}

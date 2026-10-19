import Foundation
import Testing
import TimingCore
@testable import STAEngine

@Suite("Source-preserving ideal-short RC", .timeLimit(.minutes(1)))
struct STAIdealShortRCTests {
    private func inventory(_ resistors: String, caps: String = "1 sink 1", extraConnection: String = "", driver: String = "source") throws -> TimingParasitics {
        try SPEFParser().parse(Data("""
        *SPEF "IEEE 1481-1998"
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *D_NET n 1
        *CONN
        *P \(driver) I
        *P sink O
        \(extraConnection)
        *CAP
        \(caps)
        *RES
        \(resistors)
        *END
        """.utf8))
    }
    private func solver(_ inventory: TimingParasitics, work: inout UInt64, driverCell: Bool = false,
                        extraSink: Bool = false, receiverCell: Bool = false, conflictingDriver: Bool = false,
                        nodes: Int = 16, limits: STAExecutionLimits? = nil) throws -> NativeSTADistributedRC {
        let text = """
        library (rc) { time_unit : "1ns"; capacitive_load_unit (1, pf);
        input_threshold_pct_rise : 40; output_threshold_pct_rise : 60;
        input_threshold_pct_fall : 60; output_threshold_pct_fall : 40;
        slew_lower_threshold_pct_rise : 20; slew_upper_threshold_pct_rise : 80;
        slew_lower_threshold_pct_fall : 20; slew_upper_threshold_pct_fall : 80;
        cell (BUF) { pin (Y) { direction : output; function : "0"; } }
        cell (LOAD) { pin (A) { direction : input; capacitance : 0.5; } }
        }
        """
        let bytes = Array(text.utf8)
        let source = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 32), resources: STALibertyResources())
        var ports: [TimingDesign.Port] = [.init(name: "sink", direction: .output, net: "n")]
        if !driverCell { ports.append(.init(name: "source", direction: .input, net: "n")) }
        if extraSink { ports.append(.init(name: "sink2", direction: .output, net: "n")) }
        if conflictingDriver { ports.append(.init(name: "driver2", direction: .input, net: "n")) }
        let instances: [TimingDesign.Instance] = (driverCell ? [.init(name: "U", cell: "BUF", connections: ["Y": "n"])] : [])
            + (receiverCell ? [.init(name: "G", cell: "LOAD", connections: ["A": "n"])] : [])
        let cells = try (driverCell ? [source.library.cell(named: "BUF")] : []) + (receiverCell ? [source.library.cell(named: "LOAD")] : [])
        let design = TimingDesign(topDesignName: "top", ports: ports,
            instances: instances, nets: [.init(name: "n")])
        return try .init(options: .init(maximumTimeStep: 1e-11, stopTime: 2e-8, crossingTolerance: 1e-12,
            maximumRefinements: 10, maximumNodes: nodes, maximumSteps: 1_000_000), limits: limits ?? .init(), parasitics: inventory,
            design: design, cells: cells, source: source,
            mode: "functional", corner: "exact", initialSteps: 0, work: &work)
    }

    @Test func zeroSourceRecordsAndTerminalIdentitiesRoundTrip() throws {
        let source = try inventory("1 source sink 0")
        let record = try #require(source.networks.first?.resistances.first)
        #expect(record.resistance == 0 && record.first.name == "source" && record.second.name == "sink")
        #expect(record.source.identifier == 1 && record.source.line > 0)
        #expect(try JSONDecoder().decode(TimingParasitics.self, from: JSONEncoder().encode(source)) == source)
        var work: UInt64 = 0
        var rc = try solver(source, work: &work)
        for edge in [TimingEdge.rise, .fall] {
            let response = try rc.response(net: "n", sink: "sink", sourceSlew: 6e-10, edge: edge, work: &work)
            #expect(response.delay == 0 && response.slew == 6e-10)
        }
        #expect(rc.steps == 0 && rc.observations.count == 2)
        #expect(rc.observations.allSatisfy { $0.source == "source" && $0.sink == "sink" && $0.method == .idealConstraint
            && $0.observedCrossingDifference == nil && $0.finalMaximumTimeStep == nil && $0.observedCycleDifference == nil })
        #expect(try JSONDecoder().decode([STADistributedRCObservation].self, from: JSONEncoder().encode(rc.observations)) == rc.observations)
    }

    @Test func idealCellThresholdOffsetsAndZeroSlewAreAnalytical() throws {
        let source = try inventory("1 U:Y sink 0", driver: "U:Y")
        var work: UInt64 = 0
        var rc = try solver(source, work: &work, driverCell: true)
        for edge in [TimingEdge.rise, .fall] {
            let measured = try rc.response(net: "n", sink: "sink", sourceSlew: 6e-10, edge: edge, work: &work)
            #expect(abs(measured.delay + 2e-10) < 1e-24 && measured.slew == 6e-10)
        }
        let step = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
        #expect(step.delay == 0 && step.slew == 0 && rc.observations.last?.method == .idealConstraint)
        let periodic = try rc.periodicResponse(net: "n", sink: "sink",
            source: .init(period: 4e-9, risePhase: 0, fallPhase: 2e-9, riseSlew: 6e-10, fallSlew: 6e-10), work: &work)
        #expect(abs(periodic.riseDelay + 2e-10) < 1e-24 && abs(periodic.fallDelay + 2e-10) < 1e-24)
        #expect(rc.observations.suffix(2).allSatisfy { $0.period == 4e-9 && $0.observedCycleDifference == nil && $0.method == .idealConstraint })
    }

    @Test func coalescedCapacitorsMatchIndependentOnePoleAndPreserveTwoReceivers() throws {
        let source = try inventory("1 source n:1 1000\n2 n:1 sink 0\n3 sink sink2 0\n4 sink n:1 5\n5 n:1 n:1 0\n6 sink G:A 0",
            caps: "1 n:1 0.5\n2 sink 0.5\n3 sink n:1 100", extraConnection: "*P sink2 O\n*I G:A I")
        var work: UInt64 = 0
        var rc = try solver(source, work: &work, extraSink: true, receiverCell: true)
        let a = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
        let b = try rc.response(net: "n", sink: "sink2", sourceSlew: 0, edge: .rise, work: &work)
        // 1000 ohm times (0.5 + 0.5 pF source CAP + 0.5 pF receiver pin).
        #expect(abs(a.delay + log(0.6) * 1.5e-9) < 2e-12 && abs(a.slew - log(4) * 1.5e-9) < 2e-12)
        #expect(a.delay == b.delay && a.slew == b.slew)
        #expect(rc.observations.map(\.sink) == ["sink", "sink2"])
        #expect(rc.observations.allSatisfy { $0.method == .backwardEuler })
        #expect(source.networks[0].resistances.count == 6 && source.networks[0].capacitances.count == 3)
    }

    @Test func missingEquivalenceConflictingDriversAndBudgetsRefuse() throws {
        var work: UInt64 = 0
        #expect(throws: TimingError.self) { _ = try solver(inventory(""), work: &work) }
        #expect(throws: TimingError.self) { _ = try solver(inventory("1 source n:1 0"), work: &work) }
        #expect(throws: TimingError.self) { _ = try solver(inventory("1 source foreign 0"), work: &work) }
        #expect(throws: TimingError.self) { _ = try solver(inventory("1 source sink 0\n2 driver2 source 0", extraConnection: "*P driver2 I"), work: &work, conflictingDriver: true) }
        #expect(throws: STAPathAnalysisError.self) { _ = try solver(inventory("1 source sink 0"), work: &work, nodes: 1) }
        #expect(throws: STAPathAnalysisError.self) { _ = try solver(inventory("1 source sink 0"), work: &work, limits: .init(maximumPathStates: 1)) }
        #expect(throws: STAPathAnalysisError.self) { _ = try solver(inventory("1 source sink 0"), work: &work, limits: .init(maximumPathWorkUnits: 1)) }
    }

    @Test func timingConsumesCanonicalStandardTokensWithoutPrivateIdentityDecode() throws {
        let source = """
        *SPEF "IEEE 1481-1998"
        *PROGRAM "PEXEngine PEX_CANONICAL_TERMINALS_V1 PEX_IDENTITY_V1"
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *NAME_MAP
        *1 PEX_IDENTITY_V1_not-a-timing-authority
        *2 U/A$1
        *D_NET n 1
        *CONN
        *P source I
        *I *2 O
        *CAP
        1 *2 1
        *RES
        1 source *2 0
        *END
        """
        let parsed = try SPEFParser().parse(Data(source.utf8))
        #expect(parsed.networks[0].connections.map(\.name) == ["U/A$1", "source"])
        #expect(parsed.networks[0].resistances[0].second.name == "U/A$1")
        #expect(throws: TimingError.self) { _ = try SPEFParser().parse(Data(source.replacingOccurrences(of: " PEX_CANONICAL_TERMINALS_V1", with: "").utf8)) }
    }

    @Test func idealResponsePreservesCancellation() async throws {
        let task = Task {
            var work: UInt64 = 0
            var rc = try solver(inventory("1 source sink 0"), work: &work)
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try rc.response(net: "n", sink: "sink", sourceSlew: 1e-10, edge: .rise, work: &work)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

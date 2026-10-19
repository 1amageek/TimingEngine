import Testing
import TimingCore
@testable import STAEngine

@Suite("Owned source-history composition", .timeLimit(.minutes(1)))
struct STAConservativeHistoryCompositionTests {
    private struct Fixture {
        let source: OwnedLibertySource
        let characterized: CharacterizedTimingLibrary
        let design: TimingDesign
        let cells: [TimingCell]
        let plans: [Int: NativeSTASequentialExecution.Plan]
        let constraints: TimingConstraintSet
        let parasitics: TimingParasitics
        let loads: [String: Double]
        let limits: STAExecutionLimits
        let budget: NativeSTAStateBudget
        let resources: STALibertyResources
    }

    private func fixture(inverting: Bool = false) throws -> Fixture {
        let tables = """
        cell_rise(t){values("0.1,0.1","0.1,0.1");}cell_fall(t){values("0.1,0.1","0.1,0.1");}
        rise_transition(t){values("0.2,0.2","0.2,0.2");}fall_transition(t){values("0.2,0.2","0.2,0.2");}
        """
        let text = """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;
            index_1("0.1,1");index_2("1,3");}
          cell(B){pin(A){direction:input;capacitance:0.01;}
            pin(Y){direction:output;function:"\(inverting ? "!A" : "A")";
              timing(){related_pin:A;timing_sense:\(inverting ? "negative_unate" : "positive_unate");\(tables)}}}
          cell(F){ff(IQ,IQN){next_state:D;clocked_on:C;}
            pin(D){direction:input;capacitance:0.01;}pin(C){direction:input;clock:true;capacitance:0.01;}
            pin(Q){direction:output;function:IQ;
              timing(){related_pin:C;timing_type:rising_edge;timing_sense:non_unate;\(tables)}}}}
        """
        let bytes = Array(text.utf8), resources = STALibertyResources()
        let source = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 64), resources: resources)
        let characterized = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["B", "F"],
            propagationCellNames: ["B"], sequentialPropagationCellNames: ["F"],
            limits: .init(maximumNestingDepth: 64), resources: resources)
        let design = TimingDesign(topDesignName: "top", ports: [
            .init(name: "CLK", direction: .input, net: "clk"), .init(name: "D0", direction: .input, net: "d0"),
            .init(name: "D1", direction: .input, net: "d1"), .init(name: "O0", direction: .output, net: "q0"),
            .init(name: "O1", direction: .output, net: "q1")], instances: [
                .init(name: "F0", cell: "F", connections: ["C": "b0", "D": "d0", "Q": "q0"]),
                .init(name: "F1", cell: "F", connections: ["C": "b1", "D": "d1", "Q": "q1"]),
                .init(name: "B1", cell: "B", connections: ["A": "b0", "Y": "b1"]),
                .init(name: "B0", cell: "B", connections: ["A": "clk", "Y": "b0"])],
            nets: ["clk", "d0", "d1", "b0", "b1", "q0", "q1"].map { .init(name: $0) })
        let cells = try design.instances.map { try source.library.cell(named: $0.cell) }
        let limits = try STAExecutionLimits(maximumPathStates: 1_000_000)
        let budget = NativeSTAStateBudget(maximum: limits.maximumPathStates)
        var work: UInt64 = 0, plans: [Int: NativeSTASequentialExecution.Plan] = [:]
        for index in [0, 1] {
            let model = try #require(cells[index].sequentialModel)
            plans[index] = try NativeSTASequentialExecution.compile(model: model,
                source: source.cells.first { $0.name == "F" }, work: &work, limits: limits,
                stateBudget: budget, sourceResources: resources)
        }
        var networks: [TimingParasitics.Network] = []
        for (net, names) in [("clk", ["CLK", "B0:A"]), ("b0", ["B0:Y", "B1:A", "F0:C"]),
                             ("b1", ["B1:Y", "F1:C"]), ("d0", ["D0", "F0:D"]),
                             ("d1", ["D1", "F1:D"]), ("q0", ["F0:Q", "O0"]), ("q1", ["F1:Q", "O1"])] {
            let endpoints = names.map { TimingParasitics.Endpoint(name: $0, ownerNet: net) }
            let resistances = endpoints.indices.dropFirst().map { index in
                TimingParasitics.ResistanceRecord(source: .init(declaringNet: net, identifier: UInt64(index), line: index),
                    first: endpoints[0], second: endpoints[index], resistance: 0)
            }
            networks.append(.init(name: net, resistances: resistances, connections: endpoints))
        }
        let clock = TimingConstraintSet.Clock(name: "c", source: "CLK", period: 10e-9, waveform: [0, 5e-9],
            sourceRiseTransition: 0.2e-9, sourceFallTransition: 0.2e-9, isPropagated: true)
        let constraints = TimingConstraintSet(clocks: [clock], defaultInputSlew: 0.2e-9,
            inputTransition: .allInputsBothEdges(slew: 0.2e-9))
        return Fixture(source: source, characterized: characterized, design: design, cells: cells, plans: plans,
            constraints: constraints, parasitics: .init(networks: networks),
            loads: Dictionary(uniqueKeysWithValues: design.nets.map { ($0.name, 2e-12) }),
            limits: limits, budget: budget, resources: resources)
    }

    private func wires(_ fixture: Fixture, work: inout UInt64) throws -> NativeSTAConservativeWires {
        try .init(options: .init(maximumNodes: 32, maximumBasisSweeps: 2, maximumCertificateAttempts: 4,
            operatingHistory: .boundedOperatingHistory), design: fixture.design, cells: fixture.cells,
            source: fixture.source, characterized: fixture.characterized, constraints: fixture.constraints,
            pulseSources: [], constants: [:], loads: fixture.loads, parasitics: fixture.parasitics,
            limits: fixture.limits, budget: fixture.budget, resources: fixture.resources,
            mode: "functional", corner: "test", work: &work)
    }

    private func clocks(_ fixture: Fixture, wires: inout NativeSTAConservativeWires?, work: inout UInt64) throws -> NativeSTAClockPropagation {
        var rc: NativeSTADistributedRC?, evidence: NativeSTASourceEvidence?
        return try .init(design: fixture.design, cells: fixture.cells, source: fixture.source,
            constraints: fixture.constraints, sequentialPlans: fixture.plans, normalPowerValidated: true,
            sourceEvidence: &evidence, loads: fixture.loads, characterized: fixture.characterized,
            sourceResources: fixture.resources, stateBudget: fixture.budget, variation: .init(), limits: fixture.limits,
            delimiter: ":", mode: "functional", corner: "test", rc: &rc, conservative: &wires, work: &work)
    }

    @Test(arguments: [false, true])
    func allBufferFrontiersPrecedeEverySequentialLeaf(_ inverting: Bool) throws {
        let fixture = try fixture(inverting: inverting)
        var work: UInt64 = 0
        var owner: NativeSTAConservativeWires? = try wires(fixture, work: &work)
        let propagated = try clocks(fixture, wires: &owner, work: &work)
        let observations = try #require(owner?.observations)
        let bufferIndices = observations.indices.filter { ["B0:A", "B1:A"].contains(observations[$0].sink.name) }
        let leafIndices = observations.indices.filter { ["F0:C", "F1:C"].contains(observations[$0].sink.name) }
        #expect(bufferIndices.count == 4 && leafIndices.count == 4)
        let lastBuffer = try #require(bufferIndices.max()), firstLeaf = try #require(leafIndices.min())
        #expect(lastBuffer < firstLeaf)
        #expect(propagated.leaves.count == 2)
        let first = try #require(propagated.leaves["F0"])
        let second = try #require(propagated.leaves["F1"])
        #expect(first.rise.rootEdge == (inverting ? .fall : .rise))
        #expect(second.rise.rootEdge == .rise)
        #expect(first.rise.clock.period == 10e-9)
        #expect(first.rise.late - first.rise.rootPhase > 0)
    }

    @Test func clockPublicationInvalidatesCacheOnlyAfterAValidBatch() throws {
        let fixture = try fixture()
        var work: UInt64 = 0
        var owner: NativeSTAConservativeWires? = try wires(fixture, work: &work)
        let propagated = try clocks(fixture, wires: &owner, work: &work)
        var value = try #require(owner)
        let wave = try #require(propagated.nets["b0"])
        let sourceSlew = NativeSTATimingBounds.slew(wave.rise.earlySlew, wave.rise.lateSlew)
        _ = try value.response(net: "b0", sink: "F0:C", edge: .rise, sourceSlew: sourceSlew, work: &work)
        let count = value.observations.count
        let identity = try #require(fixture.cells[3].arcs.first?.sourceIdentity)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try value.publishClockHistories([.init(net: "b0", wave: wave, load: 3e-12, sourceIdentity: identity)], work: &work)
        }
        _ = try value.response(net: "b0", sink: "F0:C", edge: .rise, sourceSlew: sourceSlew, work: &work)
        #expect(value.observations.count == count)
        try value.publishClockHistories([.init(net: "b0", wave: wave, load: 2e-12, sourceIdentity: identity)], work: &work)
        _ = try value.response(net: "b0", sink: "F0:C", edge: .rise, sourceSlew: sourceSlew, work: &work)
        #expect(value.observations.count == count + 1)
    }

    @Test func sequentialPlateauNeedsCompletedClockProofAndAllowsHeldCycles() throws {
        let fixture = try fixture()
        var work: UInt64 = 0
        var owner: NativeSTAConservativeWires? = try wires(fixture, work: &work)
        let arc = try #require(fixture.cells[0].arcs.first)
        let identity = try #require(arc.sourceIdentity)
        func envelope(_ edge: TimingEdge, clock: NativeSTAClockEvent?) throws
            -> (arrival: ClosedRange<Double>, slew: ClosedRange<Double>) {
            let first = try #require(arc.delayRise.inputSlews.first)
            let last = try #require(arc.delayRise.inputSlews.last)
            let input = clock.map { NativeSTATimingBounds.slew($0.earlySlew, $0.lateSlew) } ?? (first...last)
            let sample = try fixture.characterized.evaluatePropagation(cell: "F", fromPin: "C", toPin: "Q",
                edge: edge, inputSlew: input, outputLoad: 2e-12...2e-12)
            try fixture.characterized.validate(sample)
            let reference = clock.map { $0.early...$0.late } ?? (0.0...0.0)
            let arrival = try TimingNumericInterval(reference).adding(TimingNumericInterval(sample.delay.result))
            return (arrival.lowerBound...arrival.upperBound, sample.outputSlew.result)
        }
        func publish(_ value: inout NativeSTAConservativeWires, period: Double = 10e-9,
                     clock: NativeSTAClockEvent? = nil) throws {
            let rise = try envelope(.rise, clock: clock), fall = try envelope(.fall, clock: clock)
            try value.publishSequentialPlateau(net: "q0", instance: 0, period: period,
                riseArrival: rise.arrival, fallArrival: fall.arrival, riseSlew: rise.slew, fallSlew: fall.slew,
                load: 2e-12, sourceIdentity: identity, work: &work)
        }
        var before = try #require(owner)
        #expect(throws: NativeSTAConservativeCouplingError.self) { try publish(&before) }
        let propagated = try clocks(fixture, wires: &owner, work: &work)
        let clock = try #require(propagated.leaves["F0"]?.rise)
        var after = try #require(owner)
        #expect(throws: NativeSTAConservativeCouplingError.self) { try publish(&after, period: 9e-9, clock: clock) }
        try publish(&after, clock: clock)
        for edge in [TimingEdge.rise, .fall] {
            let sample = try fixture.characterized.evaluatePropagation(cell: "F", fromPin: "C", toPin: "Q",
                edge: edge, inputSlew: clock.earlySlew, outputLoad: 2e-12)
            try fixture.characterized.validate(sample.delay)
            try fixture.characterized.validate(sample.outputSlew)
            let slew = sample.outputSlew.result
            // Isolated DATA queries have no Q phase or mandatory per-cycle-toggle input.
            _ = try after.response(net: "q0", sink: "O0", edge: edge, sourceSlew: slew...slew, work: &work)
        }
    }
}

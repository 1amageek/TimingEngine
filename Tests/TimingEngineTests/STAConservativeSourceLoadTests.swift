import Testing
import TimingCore
@testable import STAEngine

@Suite("Fixed-load conservative source authority", .timeLimit(.minutes(1)))
struct STAConservativeSourceLoadTests {
    private struct Fixture {
        let source: OwnedLibertySource
        let characterized: CharacterizedTimingLibrary
        let cell: TimingCell
        let design: TimingDesign
        let resources: STALibertyResources
    }

    private func fixture(cell name: String = "BUF", selected: String, control: Bool = false) throws -> Fixture {
        func tables(_ key: String) -> String {
            let ordinary = "\"0.1,0.3\",\"0.1,0.3\",\"0.1,0.3\",\"0.1,0.3\""
            let extreme = "\"0.2,0.4\",\"0.04,0.06\",\"0.7,0.9\",\"0.2,0.4\""
            let rise = selected == key + "-rise" ? extreme : ordinary
            let fall = selected == key + "-fall" ? extreme : ordinary
            return """
            cell_rise(t){values("0.01,0.01","0.01,0.01","0.01,0.01","0.01,0.01");}
            cell_fall(t){values("0.01,0.01","0.01,0.01","0.01,0.01","0.01,0.01");}
            rise_transition(t){values(\(rise));}fall_transition(t){values(\(fall));}
            """
        }
        let body: String
        let connections: [String: String]
        if name == "BUF" {
            body = """
            pin(A){direction:input;capacitance:0.01;}
            pin(B){direction:input;capacitance:0.01;}
            pin(Y){direction:output;function:"A B";
              timing(){related_pin:A;timing_sense:positive_unate;\(tables("A"))}
              timing(){related_pin:B;timing_sense:positive_unate;\(tables("B"))}}
            """
            connections = ["A": "a", "B": "b", "Y": "out"]
        } else {
            let clear = control ? "clear:\"!RN\";" : ""
            let controlPin = control ? "pin(RN){direction:input;capacitance:0.01;}" : ""
            let controlArc = control ? "timing(){related_pin:RN;timing_type:clear;timing_sense:positive_unate;\(tables("RN"))}" : ""
            body = """
            ff(S,SN){next_state:D;clocked_on:C;\(clear)}
            pin(D){direction:input;capacitance:0.01;}
            pin(C){direction:input;capacitance:0.01;}\(controlPin)
            pin(Q){direction:output;function:S;
              timing(){related_pin:C;timing_type:rising_edge;timing_sense:positive_unate;\(tables("C"))}
              \(controlArc)}
            """
            connections = control ? ["D": "d", "C": "clk", "RN": "reset", "Q": "out"]
                : ["D": "d", "C": "clk", "Q": "out"]
        }
        let text = """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;
            index_1("0.1,0.2,0.3,0.4");index_2("1,3");}
          cell(\(name)){\(body)}}
        """
        let bytes = Array(text.utf8), resources = STALibertyResources()
        let source = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 64), resources: resources)
        let characterized = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: [name],
            propagationCellNames: name == "BUF" ? [name] : [],
            sequentialPropagationCellNames: name == "BUF" ? [] : [name],
            limits: .init(maximumNestingDepth: 64), resources: resources)
        let cell = try source.library.cell(named: name)
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "out", direction: .output)],
            instances: [.init(name: "U", cell: name, connections: connections)],
            nets: Set(connections.values).sorted().map { .init(name: $0) })
        return Fixture(source: source, characterized: characterized, cell: cell, design: design, resources: resources)
    }

    private func authority(_ fixture: Fixture, load: Double?, constants: [String: TimingDesign.Constant] = [:],
                           roots: [String: Double] = [:], maximumWork: UInt64 = 100_000_000) throws -> STAConservativeSourceAuthority {
        let pin = fixture.cell.name == "BUF" ? "Y" : "Q"
        let driver = TimingParasitics.Endpoint(name: "U:" + pin, ownerNet: "out")
        let sink = TimingParasitics.Endpoint(name: "out", ownerNet: "out")
        var networks: [TimingParasitics.Network] = [.init(name: "out",
            resistances: [.init(source: .init(declaringNet: "out", identifier: 1, line: 1),
                first: driver, second: sink, resistance: 0)], connections: [driver, sink])]
        var design = fixture.design
        var clocks: [TimingConstraintSet.Clock] = []
        for pin in roots.keys.sorted() {
            let net = try #require(design.instances[0].connections[pin])
            let name = "root-" + pin
            design.ports.append(.init(name: name, direction: .input, net: net))
            let source = TimingParasitics.Endpoint(name: name, ownerNet: net)
            let receiver = TimingParasitics.Endpoint(name: "U:" + pin, ownerNet: net)
            networks.append(.init(name: net, resistances: [.init(source: .init(declaringNet: net, identifier: 1, line: 1),
                first: source, second: receiver, resistance: try #require(roots[pin]))], connections: [source, receiver]))
            clocks.append(.init(name: name, source: name, period: 10e-9, waveform: [0, 5e-9],
                sourceRiseTransition: 0.3e-9, sourceFallTransition: 0.3e-9))
        }
        let parasitics = TimingParasitics(networks: networks)
        let limits = try STAExecutionLimits(maximumPathStates: 100_000, maximumPathWorkUnits: maximumWork)
        var work: UInt64 = 0
        var wires = try NativeSTAConservativeWires(options: .init(maximumNodes: 8,
            maximumBasisSweeps: 2, maximumCertificateAttempts: 4, operatingHistory: .boundedOperatingHistory),
            design: design, cells: [fixture.cell], source: fixture.source,
            characterized: fixture.characterized, constraints: .init(clocks: clocks), pulseSources: [], constants: constants,
            loads: load.map { ["out": $0] } ?? [:], parasitics: parasitics, limits: limits,
            budget: .init(maximum: limits.maximumPathStates), resources: fixture.resources,
            mode: "functional", corner: "test", work: &work)
        _ = try wires.response(net: "out", sink: "out", edge: .rise, sourceSlew: 0.2e-9...0.2e-9, work: &work)
        let authorities = try #require(wires.observations.first?.sourceAuthorities)
        for clock in clocks {
            let retained = try #require(authorities.first { $0.endpoint.name == clock.source })
            #expect(retained.sourceIsPort)
            #expect(retained.riseSlew == 0.3e-9...0.3e-9)
            #expect(retained.fallSlew == 0.3e-9...0.3e-9)
            #expect(retained.sourceArcs.isEmpty)
        }
        return try #require(authorities.first { $0.endpoint == driver })
    }

    private func assertFixedRange(_ value: STAConservativeSourceAuthority, low: Double, high: Double, load: Double,
                                  arcs: Int, edge: TimingEdge? = nil, otherSlew: Double = 0.2e-9) throws {
        let rise = try #require(value.riseSlew), fall = try #require(value.fallSlew)
        let range = edge == .fall ? fall : rise
        if let edge {
            let other = edge == .rise ? fall : rise
            #expect(abs(other.lowerBound - otherSlew) < 1e-22)
            #expect(abs(other.upperBound - otherSlew) < 1e-22)
        } else { #expect(rise == fall) }
        #expect(abs(range.lowerBound - low) < 1e-22)
        #expect(abs(range.upperBound - high) < 1e-22)
        #expect(value.prescribedBoundaryLoad == load)
        #expect(value.sourceArcs.count == arcs)
    }

    @Test(arguments: ["A-rise", "A-fall", "B-rise", "B-fall"])
    func everyArcAndOutputDirectionIncludesInteriorInputKnotsAtTheActualLoad(_ selected: String) throws {
        let fixture = try fixture(selected: selected)
        let value = try authority(fixture, load: 2e-12)
        try assertFixedRange(value, low: 0.05e-9, high: 0.8e-9, load: 2e-12, arcs: 2, edge: selected.hasSuffix("rise") ? .rise : .fall)
        #expect(Set(value.sourceArcs) == Set(fixture.cell.arcs.compactMap(\.sourceIdentity)))
        let full = try fixture.characterized.fullDomainOutputSlew(cell: "BUF", fromPin: String(selected.prefix(1)), toPin: "Y")
        let actual = try #require(selected.hasSuffix("rise") ? value.riseSlew : value.fallSlew)
        #expect(full.lowerBound < actual.lowerBound)
        #expect(full.upperBound > actual.upperBound)
        let arc = try #require(fixture.cell.arcs.first { $0.fromPin == String(selected.prefix(1)) })
        let firstInput = try #require(arc.delayRise.inputSlews.first)
        let lastInput = try #require(arc.delayRise.inputSlews.last)
        let input = firstInput...lastInput
        for edge in [TimingEdge.rise, .fall] {
            let sample = try fixture.characterized.evaluatePropagation(cell: "BUF", fromPin: String(selected.prefix(1)),
                toPin: "Y", edge: edge, inputSlew: input, outputLoad: 2e-12...2e-12)
            try fixture.characterized.validate(sample)
            #expect(sample.outputSlew.firstInput == sample.outputSlew.firstDomain)
            #expect(sample.outputSlew.secondInput == 2e-12...2e-12)
        }
    }

    @Test(arguments: ["C-rise", "C-fall"])
    func clockToQUsesTheSameFixedLoadAuthority(_ selected: String) throws {
        try assertFixedRange(authority(fixture(cell: "FF", selected: selected), load: 2e-12),
            low: 0.05e-9, high: 0.8e-9, load: 2e-12, arcs: 1, edge: selected.hasSuffix("rise") ? .rise : .fall)
    }

    @Test(arguments: ["RN-rise", "RN-fall"])
    func directionalControlGroupsRetainTheirOwnSourceAndConstantExclusion(_ selected: String) throws {
        let fixture = try fixture(cell: "FF", selected: selected, control: true)
        try assertFixedRange(authority(fixture, load: 2e-12), low: 0.05e-9, high: 0.8e-9, load: 2e-12, arcs: 2, edge: selected.hasSuffix("rise") ? .rise : .fall)
        try assertFixedRange(authority(fixture, load: 2e-12, constants: ["reset": .one]),
            low: 0.2e-9, high: 0.2e-9, load: 2e-12, arcs: 1)
    }

    @Test func changedAndUnavailableLoadsCannotReuseTheOldDomain() throws {
        let fixture = try fixture(selected: "A-rise")
        try assertFixedRange(authority(fixture, load: 3e-12), low: 0.06e-9, high: 0.9e-9, load: 3e-12, arcs: 2, edge: .rise, otherSlew: 0.3e-9)
        for load in [0.5e-12, 3.5e-12] {
            #expect(throws: TimingCharacterizationError.self) { _ = try authority(fixture, load: load) }
        }
        #expect(throws: TimingError.self) { _ = try authority(fixture, load: nil) }
    }

    @Test func previousBoxProvesRootClockInputBeforeNarrowingTheBuffer() throws {
        let fixture = try fixture(selected: "A-rise")
        let initial = try authority(fixture, load: 2e-12)
        let refined = try authority(fixture, load: 2e-12, roots: ["A": 0, "B": 0])
        try assertFixedRange(initial, low: 0.05e-9, high: 0.8e-9, load: 2e-12, arcs: 2, edge: .rise)
        try assertFixedRange(refined, low: 0.2e-9, high: 0.8e-9, load: 2e-12, arcs: 2, edge: .rise)
        #expect(refined.sourceArcs == initial.sourceArcs)
        let before = try #require(initial.riseSlew), after = try #require(refined.riseSlew)
        #expect(after.lowerBound > before.lowerBound)
    }

    @Test func missingOrUnprovedRequiredInputCannotNarrowTheDependentBuffer() throws {
        let fixture = try fixture(selected: "A-rise")
        for roots in [["A": 0.0], ["A": 0.0, "B": 1e9]] {
            let unchanged = try authority(fixture, load: 2e-12, roots: roots)
            try assertFixedRange(unchanged, low: 0.05e-9, high: 0.8e-9, load: 2e-12, arcs: 2, edge: .rise)
        }
        #expect(throws: STAPathAnalysisError.self) {
            _ = try authority(fixture, load: 2e-12, roots: ["A": 0, "B": 0], maximumWork: 1)
        }
    }

}

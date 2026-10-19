import Foundation
import Testing
import TimingCore
@testable import STAEngine

@Suite("Native prescribed-ramp distributed RC")
struct STADistributedRCTests {
    private func options(step: Double = 1e-11, horizon: Double = 2e-8, tolerance: Double = 1e-12,
                         refinements: Int = 10, nodes: Int = 16, steps: UInt64 = 1_000_000) throws -> STADistributedRCOptions {
        try .init(maximumTimeStep: step, stopTime: horizon, crossingTolerance: tolerance,
            maximumRefinements: refinements, maximumNodes: nodes, maximumSteps: steps)
    }
    private func source(_ extra: String = "") throws -> OwnedLibertySource {
        let bytes = Array("library (rc) { time_unit : \"1ns\"; capacitive_load_unit (1, pf); cell (DUMMY) { pin (Y) { direction : output; function : \"0\"; } } \(extra) }".utf8)
        return try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 32), resources: STALibertyResources())
    }
    private func inventory(resistors: String = "1 source sink 1000", caps: String = "1 sink 1",
                           connections: String = "*P source I\n*P sink O") throws -> TimingParasitics {
        try SPEFParser().parse(Data("""
        *SPEF "IEEE 1481-1998"
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *D_NET n 1
        *CONN
        \(connections)
        *CAP
        \(caps)
        *RES
        \(resistors)
        *END
        """.utf8))
    }
    private func solver(_ inventory: TimingParasitics, options selected: STADistributedRCOptions? = nil,
                        thresholds: String = "", work: inout UInt64, limits: STAExecutionLimits? = nil) throws -> NativeSTADistributedRC {
        try .init(options: selected ?? options(), limits: limits ?? .init(), parasitics: inventory,
            design: .init(topDesignName: "top", ports: [.init(name: "source", direction: .input, net: "n"),
                .init(name: "sink", direction: .output, net: "n")], instances: [], nets: [.init(name: "n")]),
            cells: [], source: source(thresholds), mode: "functional", corner: "exact", initialSteps: 0, work: &work)
    }

    @Test("one-pole source step matches independent analytical 50% and 20-80% crossings", arguments: [TimingEdge.rise, .fall])
    func onePole(_ edge: TimingEdge) throws {
        var work: UInt64 = 0
        var rc = try solver(inventory(), work: &work)
        let result = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: edge, work: &work)
        #expect(abs(result.delay - log(2) * 1e-9) < 2e-12)
        #expect(abs(result.slew - log(4) * 1e-9) < 2e-12)
        #expect(rc.observations.count == 1)
        #expect(try #require(rc.observations[0].observedCrossingDifference) <= 1e-12)
        #expect(rc.observations[0].cumulativeSteps > 0)
    }

    @Test("equal two-section ladder matches its independent two-exponential response")
    func twoSection() throws {
        var work: UInt64 = 0
        var rc = try solver(inventory(resistors: "1 source n:1 1000\n2 n:1 sink 1000", caps: "1 n:1 1\n2 sink 1"), work: &work)
        let result = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
        func crossing(_ level: Double) -> Double {
            let slow = (3 - sqrt(5)) / 2e-9, fast = (3 + sqrt(5)) / 2e-9
            var low = 0.0, high = 2e-8
            for _ in 0..<80 {
                let t = (low + high) / 2
                let y = 1 - (fast * exp(-slow * t) - slow * exp(-fast * t)) / (fast - slow)
                if y < level { low = t } else { high = t }
            }
            return (low + high) / 2
        }
        #expect(abs(result.delay - crossing(0.5)) < 3e-12)
        #expect(abs(result.slew - (crossing(0.8) - crossing(0.2))) < 3e-12)
    }

    @Test("same total capacitance with different placement and resistance produces different delay/slew")
    func topologyAndResistanceMatter() throws {
        var work: UInt64 = 0
        var rootCap = try solver(inventory(caps: "1 source 1\n2 sink 1"), work: &work)
        var sinkCap = try solver(inventory(caps: "1 sink 2"), work: &work)
        var resistance = try solver(inventory(resistors: "1 source sink 2000"), work: &work)
        let a = try rootCap.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
        let b = try sinkCap.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
        let c = try resistance.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
        #expect(abs(b.delay - 2 * a.delay) < 3e-12)
        #expect(abs(c.delay - b.delay) < 3e-12)
        #expect(b.slew > a.slew * 1.9)
    }

    @Test("finite ramp and receiver rise/fall thresholds are actually consumed")
    func thresholdsAndRamp() throws {
        var work: UInt64 = 0
        let threshold = "input_threshold_pct_rise : 40; input_threshold_pct_fall : 60; slew_lower_threshold_pct_rise : 10; slew_upper_threshold_pct_rise : 90; slew_lower_threshold_pct_fall : 10; slew_upper_threshold_pct_fall : 90;"
        var rc = try solver(inventory(), thresholds: threshold, work: &work)
        let rise = try rc.response(net: "n", sink: "sink", sourceSlew: 4e-10, edge: .rise, work: &work)
        let fall = try rc.response(net: "n", sink: "sink", sourceSlew: 4e-10, edge: .fall, work: &work)
        #expect(abs(rise.delay - fall.delay) < 1e-20)
        #expect(abs(rise.slew - fall.slew) < 1e-20)
        #expect(rc.observations[0].sinkThreshold == 0.4)
        #expect(rc.observations[1].sinkThreshold == 0.6)
        #expect(rise.slew > log(4) * 1e-9)
    }

    @Test("zero grounded receiver load cannot turn an algebraic ideal step into fabricated finite slew", arguments: ["1 sink 0", "1 source 1", "1 source sink 1"])
    func algebraicProfileRefusal(_ caps: String) throws {
        var work: UInt64 = 0
        #expect(throws: TimingError.self) { _ = try solver(inventory(caps: caps), work: &work) }
    }

    @Test("same-net differential capacitance remains in the nodal response")
    func differentialCapacitance() throws {
        var work: UInt64 = 0
        var rc = try solver(inventory(caps: "1 sink 1\n2 source sink 0.1"), work: &work)
        let result = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
        let tau = 1.1e-9
        #expect(abs(result.delay - tau * log((1 / 1.1) / 0.5)) < 3e-12)
        #expect(abs(result.slew - tau * log(4)) < 3e-12)
    }

    @Test("driver output threshold and receiver input threshold remain distinct")
    func driverReceiverThresholds() throws {
        let text = "input_threshold_pct_rise : 40; output_threshold_pct_rise : 60; cell (INV) { pin (Y) { direction : output; function : \"1\"; } }"
        let owned = try source(text)
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "sink", direction: .output, net: "n")],
            instances: [.init(name: "U1", cell: "INV", connections: ["Y": "n"])], nets: [.init(name: "n")])
        let inv = try inventory(resistors: "1 U1:Y sink 1000", connections: "*I U1:Y O\n*P sink O")
        var work: UInt64 = 0
        var rc = try NativeSTADistributedRC(options: options(), limits: .init(), parasitics: inv, design: design,
            cells: [owned.library.cell(named: "INV")], source: owned, mode: "functional", corner: "exact", initialSteps: 0, work: &work)
        _ = try rc.response(net: "n", sink: "sink", sourceSlew: 4e-10, edge: .rise, work: &work)
        #expect(rc.observations.first?.sourceThreshold == 0.6)
        #expect(rc.observations.first?.sinkThreshold == 0.4)
    }

    @Test("source inventory retains exact RES, CONN and delimiter; legacy v2 stays cap-only")
    func sourceRetention() throws {
        let value = try inventory()
        #expect(value.schemaVersion == 3)
        let network = try #require(value.networks.first)
        #expect(network.resistances.first?.first.name == "source")
        #expect(network.resistances.first?.second.name == "sink")
        #expect(network.resistances.first?.resistance == 1000)
        #expect(network.resistances.first?.source.identifier == 1)
        #expect(network.connections.map(\.name) == ["sink", "source"])
        #expect(try JSONDecoder().decode(TimingParasitics.self, from: JSONEncoder().encode(value)) == value)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json["schemaVersion"] = 2; json.removeValue(forKey: "pinDelimiter")
        let legacy = try JSONDecoder().decode(TimingParasitics.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!legacy.hasDistributedTopology)
        _ = try EquipotentialTimingParasiticReducer().reduce(legacy)
        var work: UInt64 = 0
        #expect(throws: TimingError.self) { _ = try solver(legacy, work: &work) }
    }

    @Test("missing source/sink, disconnected topology and unknown ownership are explicit refusal", arguments: ["missing", "open", "owner", "duplicate"])
    func refusesTopology(_ failure: String) throws {
        var work: UInt64 = 0
        switch failure {
        case "missing": #expect(throws: TimingError.self) { _ = try solver(inventory(connections: "*P source I"), work: &work) }
        case "open": #expect(throws: TimingError.self) { _ = try solver(inventory(resistors: "1 source n:1 1000"), work: &work) }
        case "owner": #expect(throws: TimingError.self) { _ = try inventory(resistors: "1 source foreign:1 1000") }
        default: #expect(throws: TimingError.self) { _ = try inventory(resistors: "1 source sink 1000\n1 source sink 1000") }
        }
    }

    @Test("horizon, convergence, cumulative step, node and work ceilings reject without successful response", arguments: ["horizon", "convergence", "steps", "nodes", "work"])
    func refusesNumericalScope(_ failure: String) throws {
        var work: UInt64 = 0
        if failure == "nodes" {
            #expect(throws: STAPathAnalysisError.self) { _ = try solver(inventory(), options: options(nodes: 1), work: &work) }
            return
        }
        if failure == "work" {
            var constructionWork: UInt64 = 0
            _ = try solver(inventory(), work: &constructionWork)
            var rc = try solver(inventory(), work: &work, limits: .init(maximumPathWorkUnits: constructionWork + 1))
            #expect(throws: STAPathAnalysisError.self) { _ = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work) }
            #expect(rc.observations.isEmpty)
            return
        }
        let selected = try failure == "horizon" ? options(step: 1e-12, horizon: 1e-11)
            : failure == "convergence" ? options(step: 1e-10, tolerance: 1e-18, refinements: 1)
            : options(steps: 10)
        var rc = try solver(inventory(), options: selected, work: &work)
        #expect(throws: (any Error).self) { _ = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work) }
        #expect(rc.observations.isEmpty)
    }

    @Test("cancelled network propagation retains cancellation")
    func cancellation() async throws {
        let task = Task {
            var work: UInt64 = 0
            var rc = try solver(inventory(), work: &work)
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

extension STADistributedRCTests {
    @Test("native STA composes distinct characterized corner delays with measured distributed wire delay/slew")
    func nativeExactCorners() async throws {
        let fixture = try STADistributedRCFixture()
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .completed)
        #expect(result.payload.analyzedCorners == ["typical", "slow"])
        let typical = try #require(result.payload.endpoints.first { $0.cornerID == "typical" })
        let slow = try #require(result.payload.endpoints.first { $0.cornerID == "slow" })
        let wire = try #require(result.payload.wireObservations.first { $0.cornerID == "typical" && $0.edge == .rise })
        #expect(wire.source == "U1:Y" && wire.sink == "out")
        #expect(wire.wireDelay > 6e-10 && wire.sinkSlew > 1.3e-9)
        #expect(abs(try #require(typical.setupSlack) - (6e-9 - wire.wireDelay)) < 1e-20)
        #expect(abs(try #require(slow.setupSlack) - (4e-9 - wire.wireDelay)) < 1e-20)
        #expect(abs(try #require(typical.dataSlew) - wire.sinkSlew) < 1e-20)
        #expect(result.payload.effectiveConfiguration?.distributedRC == fixture.request.distributedRC)
        #expect(result.payload.effectiveConfiguration?.reductionIdentity == "prescribed-linear-ramp.ideal-quotient.backward-euler.v3")
        #expect(result.payload.processSelection?.librariesByCorner["typical"] == fixture.request.libraries[0].artifact.reference)
        #expect(result.payload.processSelection?.librariesByCorner["slow"] == fixture.request.libraries[1].artifact.reference)
        #expect(result.inputBindings.contains { $0 == fixture.request.parasitics })
        #expect(try JSONDecoder().decode(STAExecutionResult.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test("wire derates change only measured wire delay; cell derates retain their independent meaning")
    func nativeDerates() async throws {
        let baseline = try STADistributedRCFixture()
        let wires = try STADistributedRCFixture(variation: .init(lateInterconnectDelayScale: 2, earlyInterconnectDelayScale: 0.5))
        let cells = try STADistributedRCFixture(variation: .init(lateCellDelayScale: 2, earlyCellDelayScale: 0.5))
        let a = try await NativeSTAEngine(reader: baseline.reader).execute(baseline.request)
        let b = try await NativeSTAEngine(reader: wires.reader).execute(wires.request)
        let c = try await NativeSTAEngine(reader: cells.reader).execute(cells.request)
        #expect(a.status == .completed && b.status == .completed && c.status == .completed)
        let wire = try #require(a.payload.wireObservations.first).wireDelay
        let pa = try #require(a.payload.criticalPaths.first { $0.cornerID == "typical" && $0.analysisKind == .setup })
        let pb = try #require(b.payload.criticalPaths.first { $0.cornerID == "typical" && $0.analysisKind == .setup })
        let pc = try #require(c.payload.criticalPaths.first { $0.cornerID == "typical" && $0.analysisKind == .setup })
        #expect(abs(pb.arrival - pa.arrival - wire) < 1e-20)
        #expect(abs(pc.arrival - pa.arrival - 1e-9) < 1e-20)
        #expect(pb.stages.first?.delay == pa.stages.first?.delay)
    }

    @Test("distributed configuration tamper and stale expected digest fail closed")
    func staleConfiguration() async throws {
        let fixture = try STADistributedRCFixture()
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.payload.effectiveConfiguration)) as? [String: Any])
        var options = try #require(object["distributedRC"] as? [String: Any]); options["maximumTimeStep"] = 2e-11
        object["distributedRC"] = options
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(STAEffectiveConfiguration.self, from: JSONSerialization.data(withJSONObject: object)) }
        let changed = try STADistributedRCFixture(selected: self.options(step: 2e-11), expected: result.payload.effectiveConfiguration?.digest)
        let refused = try await NativeSTAEngine(reader: changed.reader).execute(changed.request)
        #expect(refused.status == .blocked && refused.artifactBindings.isEmpty && refused.payload.wireObservations.isEmpty)
    }

    @Test("one missing exact corner, dynamic coupling and finite-R clock network block all report publication", arguments: ["missing-library", "clock", "coupling"])
    func nativeFailure(_ failure: String) async throws {
        let text: String
        if failure == "clock" {
            text = """
            *C_UNIT 1 PF
            *R_UNIT 1 OHM
            *D_NET in 1
            *CONN
            *P in I
            *I U1:A I
            *CAP
            1 U1:A 1
            *RES
            1 in U1:A 1000
            *END
            """
        } else if failure == "coupling" {
            text = STADistributedRCFixture.spef.replacingOccurrences(of: "1 out 1", with: "1 out in 1")
        } else { text = STADistributedRCFixture.spef }
        let fixture = try STADistributedRCFixture(spef: text, failure: failure == "missing-library" ? failure : nil)
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty)
        #expect(result.payload.wireObservations.isEmpty && result.payload.analyzedCorners.isEmpty)
    }
}

extension STADistributedRCTests {
    @Test("distributed receiver slew feeds the next actual cell LUT")
    func receiverSlewFeedsNextCell() async throws {
        let root = try TimingTestResources.corpusRoot.appending(path: "fixtures/simple")
        let original = try String(contentsOf: root.appending(path: "library.lib"), encoding: .utf8)
        let table = "index_1 (\"0.1\"); index_2 (\"0.0\"); values (\"1.0\");"
        let libraryBytes = Data(original.replacingOccurrences(of: table,
            with: "index_1 (\"0.0, 10.0\"); index_2 (\"0.0\"); values (\"1.0\", \"11.0\");").utf8)
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "in", direction: .input), .init(name: "out", direction: .output)],
            instances: [.init(name: "U1", cell: "INV", connections: ["A": "in", "Y": "mid"]),
                .init(name: "U2", cell: "INV", connections: ["A": "mid", "Y": "out"])], nets: [.init(name: "mid")])
        let designBytes = try JSONEncoder().encode(design)
        let constraintsBytes = try Data(contentsOf: root.appending(path: "constraints.sdc"))
        let manifestBytes = try STATestProcessFactory.data(library: libraryBytes)
        let spefBytes = Data("""
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *D_NET mid 1
        *CONN
        *I U1:Y O
        *I U2:A I
        *CAP
        1 U2:A 1
        *RES
        1 U1:Y U2:A 1000
        *END
        """.utf8)
        let d = try STAProcessTestFixture.binding(designBytes, path: "design.json", kind: .netlist, format: .json)
        let l = try STAProcessTestFixture.binding(libraryBytes, path: "typical.lib", kind: .model, format: .liberty)
        let c = try STAProcessTestFixture.binding(constraintsBytes, path: "constraints.sdc", kind: .constraints, format: .sdc)
        let m = try STAProcessTestFixture.binding(manifestBytes, path: "pdk.json", kind: .technology, format: .json)
        let p = try STAProcessTestFixture.binding(spefBytes, path: "network.spef", kind: .parasitics, format: .spef)
        let reader = InMemoryTimingArtifactReader(artifacts: [d.id: designBytes, l.id: libraryBytes, c.id: constraintsBytes, m.id: manifestBytes, p.id: spefBytes])
        let request = try STARequest(runID: "distributed-next-cell", design: d, topDesignName: "top", libraries: [.init(artifact: l, cornerIDs: ["typical"])],
            constraints: c, requestedCornerIDs: ["typical"], pdkManifest: m, processID: "test", pdkVersion: "1", parasitics: p,
            requiresPostLayoutInputs: true, distributedRC: STADistributedRCFixture.options)
        let result = try await NativeSTAEngine(reader: reader).execute(request)
        #expect(result.status == .completed)
        let wire = try #require(result.payload.wireObservations.first { $0.sink == "U2:A" })
        let stage = try #require(result.payload.criticalPaths.first { $0.analysisKind == .setup }?.stages.first { $0.instance == "U2" })
        #expect(wire.sinkSlew > 1e-9)
        #expect(abs(stage.delay - 1e-9 - wire.sinkSlew) < 1e-20)
        #expect(abs(try #require(stage.inputWireDelay) - wire.wireDelay) < 1e-20)
    }
}

extension STADistributedRCTests {
    @Test("host-required exact net/corner coverage rejects rehashed omission, ideal clocks and stale candidates")
    func requiredCoverageGate() async throws {
        let fixture = try STADistributedRCFixture()
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        let checker: any STADistributedCoverageValidating = StrictSTADistributedCoverageValidator()
        try checker.validate(result, request: fixture.request, requiredNetNames: ["out"], requiredCornerIDs: ["typical", "slow"])
        #expect(result.payload.wireCoverage.contains { $0.net == "in" && $0.model == .idealClock })
        #expect(throws: STADistributedCoverageError.self) {
            try checker.validate(result, request: fixture.request, requiredNetNames: ["in", "out"], requiredCornerIDs: ["typical", "slow"])
        }
        #expect(throws: STADistributedCoverageError.self) {
            try checker.validate(result, request: fixture.request, requiredNetNames: ["out"], requiredCornerIDs: ["slow"])
        }
        var payload = result.payload
        payload.wireCoverage.removeAll { $0.net == "out" }
        payload.wireObservations.removeAll { $0.net == "out" }
        let rehashed = try STAExecutionResult(runID: result.runID, status: result.status, payload: payload,
            inputBindings: result.inputBindings, diagnostics: result.diagnostics, provenance: result.evidence.provenance)
        let reloaded = try JSONDecoder().decode(STAExecutionResult.self, from: JSONEncoder().encode(rehashed))
        #expect(throws: STADistributedCoverageError.self) {
            try checker.validate(reloaded, request: fixture.request, requiredNetNames: ["out"], requiredCornerIDs: ["typical", "slow"])
        }
        let changed = try STADistributedRCFixture(spef: STADistributedRCFixture.spef.replacingOccurrences(of: "1000", with: "2000"))
        #expect(throws: STADistributedCoverageError.self) {
            try checker.validate(result, request: changed.request, requiredNetNames: ["out"], requiredCornerIDs: ["typical", "slow"])
        }
    }

    @Test("retained reader refuses missing coverage and impossible measured observations", arguments: ["coverage", "negative-slew", "agreement", "step-budget"])
    func retainedReaderRefusal(_ failure: String) async throws {
        let fixture = try STADistributedRCFixture()
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.payload)) as? [String: Any])
        if failure == "coverage" { payload.removeValue(forKey: "wireCoverage") }
        else {
            var observations = try #require(payload["wireObservations"] as? [[String: Any]])
            if failure == "negative-slew" { observations[0]["sinkSlew"] = -1.0 }
            else if failure == "agreement" { observations[0]["observedCrossingDifference"] = 1.0 }
            else { observations[0]["cumulativeSteps"] = 1_000_001 }
            payload["wireObservations"] = observations
        }
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(STAPayload.self, from: JSONSerialization.data(withJSONObject: payload)) }
    }

    @Test("cross-net RES is preserved for legacy inventory and refused by distributed consumption")
    func legacyCrossNetResistance() throws {
        let parsed = try inventory(resistors: "1 source external 1000")
        #expect(parsed.networks.first?.resistances.first?.second.ownerNet == "external")
        #expect(parsed.networks.first?.resistanceInventory == 1000)
        _ = try EquipotentialTimingParasiticReducer().reduce(parsed)
        var work: UInt64 = 0
        #expect(throws: TimingError.self) { _ = try solver(parsed, work: &work) }
    }

    @Test("cap-only provided network and unsupported threshold conventions cannot claim distributed timing")
    func refusesMissingElectricalTopology() async throws {
        let fixture = try STADistributedRCFixture(spef: STADistributedRCFixture.spef.replacingOccurrences(of: "*RES\n1 U1:Y out 1000\n", with: ""))
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .blocked && result.artifactBindings.isEmpty)
        let unavailable = try source("slew_derate_from_library : 2;")
        #expect(unavailable.thresholds == nil && unavailable.thresholdIssue != nil)
        var work: UInt64 = 0
        #expect(throws: TimingError.self) { _ = try solver(inventory(), thresholds: "slew_derate_from_library : 2;", work: &work) }
    }
}

import Foundation
import Testing
import TimingCore
@testable import STAEngine

@Suite("Native propagated primary clocks")
struct STAPropagatedClockTests {
    @Test("strict numeric waveform and explicit source facts", .timeLimit(.minutes(1)))
    func sourceAdmission() throws {
        let constraints = try SDCParser().parse(Data(STAPropagatedClockFixture.sdc.utf8))
        let clock = try #require(constraints.clocks.first)
        #expect(clock.hasValidPropagatedSource && clock.isPropagated)
        #expect(abs(clock.waveform[0] - 1e-9) < 1e-23 && abs(clock.waveform[1] - 11e-9) < 1e-23)
        let riseTransition = try #require(clock.sourceRiseTransition), fallTransition = try #require(clock.sourceFallTransition)
        #expect(abs(riseTransition - 0.2e-9) < 1e-23 && abs(fallTransition - 0.3e-9) < 1e-23)
        for source in ["create_clock -period 20 -waveform {0 junk 10} clk", "create_clock -period 20 -waveform {10 0} clk",
                       "create_clock -period 20 -waveform {0 20} clk", "create_clock -period nan clk",
                       "create_clock -period 20", "create_clock -period 20 clk extra",
                       "create_clock -name clk -period 20 clk\nset_clock_transition 0.2 [get_clocks unknown]",
                       "create_clock -name clk -period 20 clk\nset_clock_latency 1 [get_clocks clk]"] {
            #expect(throws: TimingError.self) { _ = try SDCParser().parse(Data(source.utf8)) }
        }
        let legacy = try JSONDecoder().decode(TimingConstraintSet.Clock.self,
            from: Data(#"{"name":"clk","source":"clk","period":2e-8,"waveform":[],"uncertainty":0}"#.utf8))
        #expect(!legacy.isPropagated && legacy.sourceRiseTransition == nil)
    }

    @Test("periodic RC matches independent piecewise exponential steady-state solution", .timeLimit(.minutes(1)))
    func periodicAnalytical() throws {
        let text = "library (rc) { time_unit : \"1ns\"; capacitive_load_unit (1,pf); cell (C) { pin (Y) { direction : output; function : \"0\"; } } }"
        let bytes = Array(text.utf8)
        let source = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 8), resources: STALibertyResources())
        let spef = """
        *SPEF "IEEE 1481-1998"
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *D_NET n 1
        *CONN
        *P source I
        *P sink O
        *CAP
        1 sink 1
        *RES
        1 source sink 1000
        *END
        """
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "source", direction: .input, net: "n"), .init(name: "sink", direction: .output, net: "n")], instances: [], nets: [.init(name: "n")])
        var work: UInt64 = 0
        var solver = try NativeSTADistributedRC(options: .init(maximumTimeStep: 1e-11, stopTime: 8e-8, crossingTolerance: 1e-12, maximumRefinements: 10, maximumNodes: 4, maximumSteps: 1_000_000), limits: .init(), parasitics: SPEFParser().parse(Data(spef.utf8)), design: design, cells: [], source: source, mode: "functional", corner: "analytical", initialSteps: 0, work: &work)
        let response = try solver.periodicResponse(net: "n", sink: "sink", source: .init(period: 4e-9, risePhase: 0.5e-9, fallPhase: 2.5e-9, riseSlew: 0.06e-9, fallSlew: 0.06e-9), work: &work)
        // Exact solution of tau*y' + y = v for piecewise linear v, with y(0)=y(T).
        let segments: [(Double, Double, Double)] = [(0.45e-9,0,0),(0.1e-9,0,1e10),(1.9e-9,1,0),(0.1e-9,1,-1e10),(1.45e-9,0,0)]
        func advance(_ y: Double, duration: Double, voltage: Double, slope: Double) -> Double {
            voltage + slope * (duration - 1e-9) + (y - voltage + slope * 1e-9) * exp(-duration / 1e-9)
        }
        func end(_ initial: Double) -> Double { segments.reduce(initial) { advance($0, duration: $1.0, voltage: $1.1, slope: $1.2) } }
        let initial = end(0) / (1 - exp(-4))
        func voltage(_ t: Double) -> Double {
            var remaining = t, y = initial
            for segment in segments {
                let dt = min(remaining, segment.0)
                y = advance(y, duration: dt, voltage: segment.1, slope: segment.2)
                remaining -= dt; if remaining <= 0 { break }
            }
            return y
        }
        func crossing(_ level: Double, rising: Bool) -> Double {
            var low = rising ? 0.55e-9 : 2.55e-9, high = rising ? 2.45e-9 : 4e-9
            for _ in 0..<80 { let t = (low + high) / 2; if (voltage(t) < level) == rising { low = t } else { high = t } }
            return (low + high) / 2
        }
        #expect(abs(response.riseDelay - (crossing(0.5, rising: true) - 0.5e-9)) < 3e-12)
        #expect(abs(response.fallDelay - (crossing(0.5, rising: false) - 2.5e-9)) < 3e-12)
        #expect(abs(response.riseSlew - (crossing(0.8, rising: true) - crossing(0.2, rising: true))) < 3e-12)
        #expect(response.riseDelay < log(2) * 1e-9 - 5e-11)
        #expect(solver.observations.allSatisfy { $0.period == 4e-9 && $0.observedCycleDifference! <= 1e-12 })
    }

    @Test("actual characterized buffered clock tree drives FF arrival, slew and two exact corners", .timeLimit(.minutes(1)), arguments: [false, true])
    func characterizedTree(_ invert: Bool) async throws {
        let fixture = try STAPropagatedClockFixture(invert: invert)
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        #expect(result.payload.clockObservations.count == 8)
        try StrictSTADistributedCoverageValidator().validate(result, request: fixture.request,
            requiredNetNames: ["root", "leaf", "data"], requiredCornerIDs: ["typical", "slow"])
        for corner in ["typical", "slow"] {
            let launch = try #require(result.payload.clockObservations.first { $0.cornerID == corner && $0.receiver == "L:CLK" && $0.edge == .rise })
            let capture = try #require(result.payload.clockObservations.first { $0.cornerID == corner && $0.receiver == "C:CLK" && $0.edge == .rise })
            #expect(launch.rootEdge == (invert ? .fall : .rise))
            #expect(abs(launch.rootPhase - (invert ? 11e-9 : 1e-9)) < 1e-23)
            #expect(capture.lateArrival > launch.lateArrival)
            let endpoint = try #require(result.payload.endpoints.first { $0.cornerID == corner && $0.endpoint == "C/D" })
            let delay = corner == "typical" ? 0.6e-9 : 1e-9
            let riseWire = try #require(result.payload.wireObservations.first { $0.cornerID == corner && $0.net == "data" && $0.edge == .rise })
            let fallWire = try #require(result.payload.wireObservations.first { $0.cornerID == corner && $0.net == "data" && $0.edge == .fall })
            // Source tables vary with actual received clock slew (slope 0.1).
            let riseData = launch.lateArrival + delay + 0.1 * launch.lateSlew + riseWire.wireDelay
            let fallData = launch.lateArrival + delay + 0.1e-9 + 0.1 * launch.lateSlew + fallWire.wireDelay
            let riseConstraint = 0.1e-9 + 0.1 * (riseWire.sinkSlew + capture.earlySlew)
            let fallConstraint = 0.2e-9 + 0.1 * (fallWire.sinkSlew + capture.earlySlew)
            let expectedSetup = min(20e-9 + capture.earlyArrival - riseData - riseConstraint - 0.01e-9,
                20e-9 + capture.earlyArrival - fallData - fallConstraint - 0.01e-9)
            #expect(abs(try #require(endpoint.setupSlack) - expectedSetup) < 1e-20)
            #expect(result.payload.wireCoverage.filter { $0.cornerID == corner && ["root", "leaf"].contains($0.net) }.allSatisfy { $0.model == .propagatedClock })
        }
        let typical = try #require(result.payload.endpoints.first { $0.cornerID == "typical" && $0.endpoint == "C/D" }?.setupSlack)
        let slow = try #require(result.payload.endpoints.first { $0.cornerID == "slow" && $0.endpoint == "C/D" }?.setupSlack)
        #expect(typical > slow + 0.3e-9)
        #expect(try JSONDecoder().decode(STAExecutionResult.self, from: JSONEncoder().encode(result)).payload == result.payload)
    }

    @Test("missing source, missing clock wire, ambiguous topology and missing tables refuse", .timeLimit(.minutes(1)), arguments: ["rise", "propagated", "waveform", "wire", "table", "loop", "function", "gated", "multiple", "generated", "domain", "clock-control", "source-direction"])
    func refusal(_ failure: String) async throws {
        var sdc = STAPropagatedClockFixture.sdc, spef = STAPropagatedClockFixture.spef
        var design = STAPropagatedClockFixture.design
        if failure == "rise" { sdc = sdc.replacingOccurrences(of: "set_clock_transition -rise 0.2ns [get_clocks clk]", with: "") }
        if failure == "propagated" { sdc = sdc.replacingOccurrences(of: "set_propagated_clock [get_clocks clk]", with: "") }
        if failure == "waveform" { sdc = sdc.replacingOccurrences(of: "-waveform {1ns 11ns}", with: "") }
        if failure == "wire" { spef = spef.components(separatedBy: "*D_NET root")[0] + "*D_NET leaf" + spef.components(separatedBy: "*D_NET leaf")[1] }
        if failure == "loop" { design.instances[0].connections["A"] = "leaf" }
        if failure == "source-direction" { design.ports[0].direction = .output }
        if failure == "gated" { design.instances[0].connections["G"] = "din" }
        if failure == "multiple" { design.instances.append(.init(name: "B2", cell: "BUF", connections: ["A":"root", "Y":"leaf"])) }
        if failure == "generated" { sdc += "\ncreate_generated_clock -name g -source [get_ports clk] -divide_by 2 [get_pins B/Y]\n" }
        let mutation: ((String) -> String)? = failure == "table" ? { $0.replacingOccurrences(of: "rise_transition (nldm)", with: "missing_transition (nldm)") }
            : failure == "function" ? { $0.replacingOccurrences(of: "function : \"A\"", with: "function : \"0\"") }
            : failure == "gated" ? { $0.replacingOccurrences(of: "cell (BUF) {", with: "cell (BUF) { pin (G) { direction : input; capacitance : 0.05; }") }
            : failure == "domain" ? { $0.replacingOccurrences(of: "index_1 (\"0, 20\")", with: "index_1 (\"1, 20\")") }
            : failure == "clock-control" ? { $0.replacingOccurrences(of: "clocked_on : \"CLK\"", with: "clocked_on : \"CLK & D\"") } : nil
        let fixture = try STAPropagatedClockFixture(sdc: sdc, spef: spef, design: design, libraryMutation: mutation)
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .blocked)
        #expect(result.payload.clockObservations.isEmpty && result.payload.wireObservations.isEmpty && result.artifactBindings.isEmpty)
    }
}

extension STAPropagatedClockTests {
    @Test("root phase selects the next setup and previous hold cycle across inversion", .timeLimit(.minutes(1)))
    func oppositeEdgeCycles() async throws {
        var design = STAPropagatedClockFixture.design
        design.instances[1].connections["CLK"] = "root"
        let spef = STAPropagatedClockFixture.spef
            .replacingOccurrences(of: "*I B:A I", with: "*I B:A I\n*I L:CLK I")
            .replacingOccurrences(of: "1 clk B:A 1000", with: "1 clk B:A 1000\n2 clk L:CLK 1000")
            .replacingOccurrences(of: "*I L:CLK I\n*I C:CLK I", with: "*I C:CLK I")
            .replacingOccurrences(of: "1 L:CLK 0.1\n2 C:CLK 0.2", with: "1 C:CLK 0.2")
            .replacingOccurrences(of: "1 B:Y L:CLK 1000\n2 B:Y C:CLK 1500", with: "1 B:Y C:CLK 1500")
        let fixture = try STAPropagatedClockFixture(spef: spef, invert: true, design: design)
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        for corner in ["typical", "slow"] {
            let capture = try #require(result.payload.clockObservations.first { $0.cornerID == corner && $0.receiver == "C:CLK" && $0.edge == .rise })
            let endpoint = try #require(result.payload.endpoints.first { $0.cornerID == corner && $0.endpoint == "C/D" })
            // Root launch is at 1 ns, capture's inverted root fall is at 11 ns in the same cycle.
            #expect(capture.rootEdge == .fall)
            #expect(try #require(endpoint.setupSlack) < 12e-9)
            #expect(try #require(endpoint.setupSlack) > 7e-9)
            // Hold uses the preceding 11 ns edge, one source period earlier.
            #expect(try #require(endpoint.holdSlack) > 7e-9)
        }
    }

    @Test("identical physical leaf clock contributions cancel static derates on a self path", .timeLimit(.minutes(1)))
    func commonLeafCorrection() async throws {
        var design = STAPropagatedClockFixture.design
        design.instances[1].connections["D"] = "data"
        design.instances[2].connections["D"] = "din"
        let spef = STAPropagatedClockFixture.spef.replacingOccurrences(of: "C:D", with: "L:D")
        let variation = STAVariation(lateCellDelayScale: 1.2, earlyCellDelayScale: 0.8, lateInterconnectDelayScale: 1.3, earlyInterconnectDelayScale: 0.7)
        let fixture = try STAPropagatedClockFixture(spef: spef, variation: variation, design: design)
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        for corner in ["typical", "slow"] {
            let clock = try #require(result.payload.clockObservations.first { $0.cornerID == corner && $0.receiver == "L:CLK" && $0.edge == .rise })
            let endpoint = try #require(result.payload.endpoints.first { $0.cornerID == corner && $0.endpoint == "L/D" })
            let delay = corner == "typical" ? 0.6e-9 : 1e-9
            let wires = result.payload.wireObservations.filter { $0.cornerID == corner && $0.net == "data" }
            func slack(_ edge: TimingEdge, setup: Bool) throws -> Double {
                let wire = try #require(wires.first { $0.edge == edge })
                let constraint = (edge == .rise ? 0.1e-9 : 0.2e-9) + 0.1 * (wire.sinkSlew + (setup ? clock.earlySlew : clock.lateSlew))
                let ctoq = delay + (edge == .rise ? 0 : 0.1e-9) + 0.1 * (setup ? clock.lateSlew : clock.earlySlew)
                return setup ? 20e-9 - ctoq * 1.2 - wire.wireDelay * 1.3 - constraint - 0.01e-9
                    : ctoq * 0.8 + wire.wireDelay * 0.7 - constraint - 0.01e-9
            }
            #expect(abs(try #require(endpoint.setupSlack) - min(try slack(.rise, setup: true), slack(.fall, setup: true))) < 1e-20)
            #expect(abs(try #require(endpoint.holdSlack) - min(try slack(.rise, setup: false), slack(.fall, setup: false))) < 1e-20)
        }
    }

    @Test("clock coverage and receiver omission cannot be reused as complete evidence", .timeLimit(.minutes(1)))
    func staleCoverage() async throws {
        let fixture = try STAPropagatedClockFixture()
        let initial = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        let original = try JSONEncoder().encode(initial)
        var changedPayload = initial.payload
        changedPayload.clockObservations.removeAll { $0.receiver == "C:CLK" }
        let result = try STAExecutionResult(runID: initial.runID, status: initial.status, payload: changedPayload,
            inputBindings: initial.inputBindings, provenance: initial.evidence.provenance)
        #expect(throws: STADistributedCoverageError.self) {
            try StrictSTADistributedCoverageValidator().validate(result, request: fixture.request, requiredNetNames: ["root", "leaf", "data"], requiredCornerIDs: ["typical", "slow"])
        }
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(STAExecutionResult.self, from: JSONEncoder().encode(result)) }
        var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var payload = try #require(json["payload"] as? [String: Any])
        var clocks = try #require(payload["clockObservations"] as? [[String: Any]])
        clocks[0]["rootPhase"] = 0
        payload["clockObservations"] = clocks; json["payload"] = payload
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(STAExecutionResult.self, from: JSONSerialization.data(withJSONObject: json)) }
        let changed = try STAPropagatedClockFixture(sdc: STAPropagatedClockFixture.sdc.replacingOccurrences(of: "0.2ns", with: "0.4ns"))
        let changedResult = try await NativeSTAEngine(reader: changed.reader).execute(changed.request)
        #expect(changedResult.payload.effectiveConfiguration?.digest != result.payload.effectiveConfiguration?.digest)
        #expect(throws: STADistributedCoverageError.self) {
            try StrictSTADistributedCoverageValidator().validate(changedResult, request: fixture.request, requiredNetNames: ["root", "leaf", "data"], requiredCornerIDs: ["typical", "slow"])
        }
    }

    @Test("warmup horizon, cumulative clock/data steps and cancellation refuse", .timeLimit(.minutes(1)))
    func boundedClockWork() async throws {
        for options in [try STADistributedRCOptions(maximumTimeStep: 2e-11, stopTime: 3e-8, crossingTolerance: 2e-12, maximumRefinements: 10, maximumNodes: 16, maximumSteps: 2_000_000),
                        try STADistributedRCOptions(maximumTimeStep: 2e-11, stopTime: 2e-7, crossingTolerance: 2e-12, maximumRefinements: 10, maximumNodes: 16, maximumSteps: 10)] {
            let fixture = try STAPropagatedClockFixture(selected: options)
            do {
                let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
                #expect(result.status == .blocked && result.payload.clockObservations.isEmpty && result.artifactBindings.isEmpty)
            } catch STAExecutionError.underlying(let cause) { #expect(cause is STAPathAnalysisError) }
        }
        let fixture = try STAPropagatedClockFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        }
        let result = try await task.value
        #expect(result.status == .cancelled && result.payload.clockObservations.isEmpty && result.artifactBindings.isEmpty)
    }
}

extension STAPropagatedClockTests {
    @Test("prepared execution retains the original external deadline", .timeLimit(.minutes(1)))
    func cumulativeDeadline() async throws {
        let fixture = try STAPropagatedClockFixture(), accountant = STAClockTestResources()
        let engine = NativeSTAEngine(reader: fixture.reader)
        let prepared = try await engine.prepare(fixture.request, resources: .init(reader: fixture.reader,
            sourceLimits: .init(maximumNestingDepth: 64), sourceResources: accountant, limits: .init()))
        accountant.expire()
        do { _ = try await engine.execute(prepared); Issue.record("Expired prepared execution must fail") }
        catch STAExecutionError.underlying(let cause) { #expect(cause is STAClockTestResources.Failure) }
    }

    @Test("received clock slew and phase drive source-bound recovery/removal and high-pulse checks", .timeLimit(.minutes(1)))
    func controlAndPulseChecks() async throws {
        var design = STAPropagatedClockFixture.design
        design.ports.append(.init(name: "reset", direction: .input, net: "reset"))
        design.nets.append(.init(name: "reset"))
        for index in [1,2] { design.instances[index].connections["RST"] = "reset" }
        let sdc = STAPropagatedClockFixture.sdc + "\nset_input_delay -clock clk -max 2ns [get_ports reset]\nset_input_delay -clock clk -min 1ns [get_ports reset]\n"
        let fixture = try STAPropagatedClockFixture(sdc: sdc, design: design, analysisKinds: [.setup,.hold,.recovery,.removal,.pulseWidth], libraryMutation: { source in
            let controls = """
            pin (RST) { direction : input; capacitance : 0.05;
              timing () { related_pin : "CLK"; timing_type : recovery_rising;
                rise_constraint (checks) { values ("0.1, 2.1", "2.1, 4.1"); }
                fall_constraint (checks) { values ("0.2, 2.2", "2.2, 4.2"); } }
              timing () { related_pin : "CLK"; timing_type : removal_rising;
                rise_constraint (checks) { values ("0.1, 2.1", "2.1, 4.1"); }
                fall_constraint (checks) { values ("0.2, 2.2", "2.2, 4.2"); } } }
            """
            return source.replacingOccurrences(of: "pin (D) {", with: controls + " pin (D) {")
                .replacingOccurrences(of: "min_pulse_width_high : 0.5;", with: "timing () { related_pin : \"CLK\"; timing_type : min_pulse_width; rise_constraint (scalar) { values (\"0.5\"); } }")
        })
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        for endpoint in result.payload.endpoints where endpoint.endpoint == "C/D" {
            let rise = try #require(result.payload.clockObservations.first { $0.cornerID == endpoint.cornerID && $0.receiver == "C:CLK" && $0.edge == .rise })
            let fall = try #require(result.payload.clockObservations.first { $0.cornerID == endpoint.cornerID && $0.receiver == "C:CLK" && $0.edge == .fall })
            let value = 0.2e-9 + 0.1 * (0.2e-9 + rise.earlySlew)
            #expect(abs(try #require(endpoint.recoverySlack) - (20e-9 + rise.earlyArrival - 3e-9 - value - 0.01e-9)) < 1e-20)
            #expect(abs(try #require(endpoint.removalSlack) - (2e-9 - rise.lateArrival - value - 0.01e-9)) < 1e-20)
            #expect(abs(try #require(endpoint.pulseWidthSlack) - (fall.earlyArrival - rise.lateArrival - 0.5e-9 - 0.01e-9)) < 1e-20)
        }
    }
}

extension STAPropagatedClockTests {
    @Test("clock and data steps remain cumulative across exact corner scenarios", .timeLimit(.minutes(1)))
    func cumulativeCornerSteps() async throws {
        let fixture = try STAPropagatedClockFixture()
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        let first = try #require(result.payload.wireObservations.filter { $0.cornerID == "typical" }.map(\.cumulativeSteps).max())
        let second = try #require(result.payload.wireObservations.filter { $0.cornerID == "slow" }.map(\.cumulativeSteps).max())
        #expect(second > first)
        let bounded = try STAPropagatedClockFixture(selected: .init(maximumTimeStep: 2e-11, stopTime: 2e-7, crossingTolerance: 2e-12,
            maximumRefinements: 10, maximumNodes: 16, maximumSteps: first + 1))
        do { _ = try await NativeSTAEngine(reader: bounded.reader).execute(bounded.request); Issue.record("Second corner must share the first scenario step budget") }
        catch STAExecutionError.underlying(let cause) {
            guard case STAPathAnalysisError.capacity(let resource, let limit) = cause else { Issue.record("Unexpected capacity failure: \(cause)"); return }
            #expect(resource == "RC time steps" && limit == first + 1)
        }
    }
}

extension STAPropagatedClockTests {
    @Test("clock, RC workspace and data records share one request state ceiling", .timeLimit(.minutes(1)))
    func cumulativeStateBudget() async throws {
        let fixture = try STAPropagatedClockFixture()
        let engine = NativeSTAEngine(reader: fixture.reader)
        let prepared = try await engine.prepare(fixture.request, resources: .init(reader: fixture.reader,
            sourceLimits: .init(maximumNestingDepth: 64), sourceResources: STALibertyResources(),
            limits: .init(maximumPathStates: 220)))
        do { _ = try await engine.execute(prepared); Issue.record("Independent per-component ceilings must not exceed the request sum") }
        catch STAExecutionError.underlying(let cause) {
            guard case STAPathAnalysisError.capacity(let resource, let limit) = cause else { Issue.record("Unexpected state failure: \(cause)"); return }
            #expect(resource == "cumulative native state slots" && limit == 220)
        }
    }
}

extension STAPropagatedClockTests {
    @Test("falling-edge FF source control and clock-to-Q use the actual falling receiver", .timeLimit(.minutes(1)))
    func fallingSequentialClock() async throws {
        let fixture = try STAPropagatedClockFixture(libraryMutation: { source in
            source.replacingOccurrences(of: "clocked_on : \"CLK\"", with: "clocked_on : \"!CLK\"")
                .replacingOccurrences(of: "timing_type : rising_edge", with: "timing_type : falling_edge")
                .replacingOccurrences(of: "_rising", with: "_falling")
        })
        let result = try await NativeSTAEngine(reader: fixture.reader).execute(fixture.request)
        #expect(result.status == .completed, "\(result.diagnostics)")
        for corner in ["typical", "slow"] {
            let launch = try #require(result.payload.clockObservations.first { $0.cornerID == corner && $0.receiver == "L:CLK" && $0.edge == .fall })
            let capture = try #require(result.payload.clockObservations.first { $0.cornerID == corner && $0.receiver == "C:CLK" && $0.edge == .fall })
            let endpoint = try #require(result.payload.endpoints.first { $0.cornerID == corner && $0.endpoint == "C/D" })
            let wire = try #require(result.payload.wireObservations.first { $0.cornerID == corner && $0.net == "data" && $0.edge == .fall })
            let ctoq = (corner == "typical" ? 0.6e-9 : 1e-9) + 0.1e-9 + 0.1 * launch.lateSlew
            let constraint = 0.2e-9 + 0.1 * (wire.sinkSlew + capture.earlySlew)
            let arrival = launch.lateArrival + ctoq + wire.wireDelay
            #expect(launch.rootEdge == .fall && abs(launch.rootPhase - 11e-9) < 1e-23)
            #expect(abs(try #require(endpoint.dataArrival) - arrival) < 1e-20)
            #expect(abs(try #require(endpoint.setupSlack) - (20e-9 + capture.earlyArrival - arrival - constraint - 0.01e-9)) < 1e-20)
        }
    }
}

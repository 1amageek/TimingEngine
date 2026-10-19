import CircuiteFoundation
import Foundation
import Synchronization
import Testing
import TimingCore
@testable import STAEngine

@Suite("Certified coupled-boundary STA integration", .timeLimit(.minutes(1)))
struct STAConservativeIntegrationTests {
    private var options: STAConservativeCoupledRCOptions {
        get throws { try .init(maximumNodes: 64, maximumBasisSweeps: 32, maximumCertificateAttempts: 16,
            operatingHistory: .boundedOperatingHistory) }
    }

    private func selecting(_ value: STARequest, strict: Bool = true,
                           observed: STADistributedRCOptions? = nil) throws -> STARequest {
        try .init(runID: value.runID, design: value.design, topDesignName: value.topDesignName,
            canonicalDesignDigest: value.canonicalDesignDigest, libraries: value.libraries,
            constraints: value.constraints, requestedModeIDs: value.requestedModeIDs,
            requestedCornerIDs: value.requestedCornerIDs, pdkManifest: value.pdkManifest,
            processID: value.processID, pdkVersion: value.pdkVersion, pdkDigest: value.pdkDigest,
            parasitics: value.parasitics, analysisKinds: value.analysisKinds, maxPaths: value.maxPaths,
            requiresPostLayoutInputs: value.requiresPostLayoutInputs, variation: value.variation,
            characterizationPolicy: value.characterizationPolicy, characterizationBindings: value.characterizationBindings,
            distributedRC: observed, conservativeCoupledRC: options, requireStrictSourceEvidence: strict,
            operatingSupplyAssumptions: value.operatingSupplyAssumptions, controlPulseSources: value.controlPulseSources)
    }

    private func prepared(_ request: STARequest, reader: InMemoryTimingArtifactReader) async throws -> (NativeSTAEngine, PreparedSTAExecution) {
        let engine = NativeSTAEngine(reader: reader)
        return (engine, try await engine.prepare(request, resources: .init(reader: reader,
            sourceLimits: .init(maximumNestingDepth: 64), sourceResources: STALibertyResources(), limits: .init())))
    }

    @Test func optInRequiresStrictAndCannotRelabelObservedMode() throws {
        let fixture = try STAPropagatedClockFixture()
        #expect(throws: TimingError.self) { _ = try selecting(fixture.request, strict: false) }
        #expect(throws: TimingError.self) { _ = try selecting(fixture.request, observed: fixture.request.distributedRC) }
        let old = try JSONDecoder().decode(STARequest.self, from: JSONEncoder().encode(fixture.request))
        #expect(old.conservativeCoupledRC == nil && old.distributedRC == fixture.request.distributedRC)
        let selected = try selecting(old)
        #expect(selected.schemaVersion == old.schemaVersion)
        #expect(try JSONDecoder().decode(STARequest.self, from: JSONEncoder().encode(selected)) == selected)
    }

    @Test func activeClockCouplingPropagatesAllBoundsAndReloadsWithExactReplay() async throws {
        let smallR = STAPropagatedClockFixture.spef.replacingOccurrences(of: "1000", with: "1")
            .replacingOccurrences(of: "1500", with: "1.5")
            .replacingOccurrences(of: "*D_NET root 0.2", with: "*D_NET root 0.200001")
            .replacingOccurrences(of: "1 B:A 0.2", with: "1 B:A 0.2\n2 B:A C:D 0.000001")
        // Recovery/removal are applicability-only for this FF; actual asynchronous checks have a separate check-only fixture.
        let fixture = try STAPropagatedClockFixture(sdc: STAPropagatedClockFixture.sdc + "\nset_output_delay 0ns -clock clk [get_ports out]", spef: smallR, analysisKinds: [.setup, .hold, .recovery, .removal, .pulseWidth])
        let request = try selecting(fixture.request)
        let (engine, owner) = try await prepared(request, reader: fixture.reader)
        let result = try await engine.execute(owner)
        #expect(result.status == .completed)
        #expect(result.payload.effectiveConfiguration?.encodingVersion == 10)
        #expect(result.payload.effectiveConfiguration?.reductionIdentity == STAConservativeCoupledRCOptions.modelIdentity)
        #expect(result.payload.wireObservations.isEmpty)
        #expect(!result.payload.conservativeWireObservations.isEmpty)
        #expect(result.payload.clockObservations.count == 8)
        #expect(result.payload.clockObservations.allSatisfy { $0.earlyArrival <= $0.lateArrival && $0.earlySlew <= $0.lateSlew })
        #expect(result.payload.conservativeWireObservations.allSatisfy {
            $0.slew.lowerBound > 0 && $0.minimumCrossingDerivative > 0 && !$0.sourceAuthorities.isEmpty
        })
        #expect(result.payload.sourceEvidence?.samples.contains { $0.rangeObservation != nil } == true)
        #expect(result.payload.sourceEvidence?.pulseWidthSamples.allSatisfy { $0.rangeObservation != nil } == true)
        try StrictSTADistributedCoverageValidator().validate(result, request: request,
            requiredNetNames: ["root", "leaf", "data"], requiredCornerIDs: request.requestedCornerIDs)
        let reloaded = try JSONDecoder().decode(STAExecutionResult.self, from: JSONEncoder().encode(result))
        try await engine.validateSourceEvidence(reloaded, against: owner)
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reloaded)) as? [String: Any])
        var payload = try #require(saved["payload"] as? [String: Any])
        let observations = try #require(payload["conservativeWireObservations"] as? [[String: Any]])
        payload["conservativeWireObservations"] = observations.filter { $0["net"] as? String != "data" }
        saved["payload"] = payload
        let omitted = try JSONDecoder().decode(STAExecutionResult.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(throws: STADistributedCoverageError.self) {
            try StrictSTADistributedCoverageValidator().validate(omitted, request: request,
                requiredNetNames: ["root", "leaf", "data"], requiredCornerIDs: request.requestedCornerIDs)
        }
        await #expect(throws: STAExecutionError.self) { try await engine.validateSourceEvidence(omitted, against: owner) }
    }

    private func nonmonotoneFixture(explicitInput: Bool = true, sourceTransition: String = "0.2") throws -> (STARequest, InMemoryTimingArtifactReader) {
        func tables(delay: String, slew: String) -> String {
            """
            cell_rise(t){values(\(delay));} cell_fall(t){values(\(delay));}
            rise_transition(t){values("\(slew),\(slew)","\(slew),\(slew)","\(slew),\(slew)");}
            fall_transition(t){values("\(slew),\(slew)","\(slew),\(slew)","\(slew),\(slew)");}
            """
        }
        let library = Data("""
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;
            index_1("0.1,0.2,0.3");index_2("0,10");}
          cell(B){pin(A){direction:input;capacitance:0.001;}pin(Y){direction:output;function:A;
            timing(){related_pin:A;timing_sense:positive_unate;\(tables(delay: "\"1,1\",\"1,1\",\"1,1\"", slew: sourceTransition))}}}
          cell(C){pin(A){direction:input;capacitance:0.001;}pin(Y){direction:output;function:A;
            timing(){related_pin:A;timing_sense:positive_unate;\(tables(delay: "\"1,1\",\"4,4\",\"1,1\"", slew: "0.2"))}}}
        }
        """.utf8)
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "clk", direction: .input),
            .init(name: "a", direction: .input), .init(name: "b", direction: .input), .init(name: "out", direction: .output)],
            instances: [.init(name: "B", cell: "B", connections: ["A":"a", "Y":"mid"]),
                .init(name: "C", cell: "C", connections: ["A":"mid", "Y":"out"])],
            nets: ["clk", "a", "b", "mid", "out"].map { .init(name: $0) })
        let sdc = Data("""
        create_clock -name clk -period 20ns [get_ports clk]
        \(explicitInput ? "set_input_transition 0.2ns [all_inputs]" : "")
        set_input_delay -clock clk -max 1ns [get_ports a]
        set_input_delay -clock clk -min 0.5ns [get_ports a]
        set_output_delay -clock clk 1ns [get_ports out]
        """.utf8)
        let spef = Data("""
        *SPEF "IEEE 1481-1998"
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *D_NET mid 0.010001
        *CONN
        *I B:Y O
        *I C:A I
        *CAP
        1 C:A 0.01
        2 C:A b:1 0.000001
        *RES
        1 B:Y C:A 1
        *END
        *D_NET b 0.01
        *CONN
        *P b I
        *CAP
        1 b:1 0.01
        *RES
        1 b b:1 1
        *END
        """.utf8)
        let manifest = try STATestProcessFactory.data(library: library)
        let data = [try JSONEncoder().encode(design), library, sdc, manifest, spef]
        let formats: [ArtifactFormat] = [.json, .liberty, .sdc, .json, .spef]
        let bindings = try data.enumerated().map { try STAProcessTestFixture.binding($0.element,
            path: "input-\($0.offset)", kind: .netlist, format: formats[$0.offset]) }
        let request = try STARequest(runID: "coupled-nonmonotone", design: bindings[0], topDesignName: "top",
            libraries: [.init(artifact: bindings[1], cornerIDs: ["typical"])], constraints: bindings[2],
            requestedModeIDs: ["functional"], requestedCornerIDs: ["typical"], pdkManifest: bindings[3],
            processID: "test", pdkVersion: "1", parasitics: bindings[4],
            conservativeCoupledRC: options, requireStrictSourceEvidence: true)
        return (request, .init(artifacts: Dictionary(uniqueKeysWithValues: zip(bindings.map(\.id), data))))
    }

    @Test func interiorLUTMaximumIsIncludedInActualDownstreamRangeReceipt() async throws {
        let (request, reader) = try nonmonotoneFixture()
        let (engine, owner) = try await prepared(request, reader: reader)
        let result = try await engine.execute(owner)
        #expect(result.status == .completed)
        let evidence = try #require(result.payload.sourceEvidence)
        let receipt = try #require(evidence.samples.first { evidence.roles[$0.role].instance == "C"
            && $0.context == .late && $0.observation.quantity == .cellDelay }?.rangeObservation)
        #expect(receipt.firstInput.lowerBound < 0.2e-9 && receipt.firstInput.upperBound > 0.2e-9)
        #expect(receipt.result.upperBound >= 4e-9)
        try await engine.validateSourceEvidence(result, against: owner)
    }

    @Test func implicitInputDefaultCannotBecomeGlobalSlopeAuthority() async throws {
        let (request, reader) = try nonmonotoneFixture(explicitInput: false)
        let (engine, owner) = try await prepared(request, reader: reader)
        await #expect(throws: STAExecutionError.self) { _ = try await engine.execute(owner) }
    }

    @Test func zeroMinimumSourceTransitionIsInconclusive() async throws {
        let (request, reader) = try nonmonotoneFixture(sourceTransition: "0")
        let (engine, owner) = try await prepared(request, reader: reader)
        await #expect(throws: STAExecutionError.self) { _ = try await engine.execute(owner) }
    }
    @Test func sequentialTransferUsesIndependentDelayAndSlewExtremaAcrossAllBranches() throws {
        typealias H = NativeSTASequentialExecution
        func arc(_ pin: String, type: String) -> String {
            """
            timing(){related_pin:\(pin);timing_type:\(type);timing_sense:positive_unate;
              cell_rise(t){values("1,1","4,4","1,1");}cell_fall(t){values("1,1","4,4","1,1");}
              rise_transition(t){values("0.3,0.3","0.1,0.1","0.3,0.3");}
              fall_transition(t){values("0.3,0.3","0.1,0.1","0.3,0.3");}}
            """
        }
        let text = """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;index_1("0.1,0.2,0.3");index_2("0,10");}
          cell(FF){ff(S,SN){next_state:D;clocked_on:C;}pin(D){direction:input;capacitance:0.1;}
            pin(C){direction:input;capacitance:0.1;}pin(Q){direction:output;function:S;\(arc("C",type:"rising_edge"))}}
          cell(LAT){latch(S,SN){data_in:D;enable:G;}pin(D){direction:input;capacitance:0.1;}
            pin(G){direction:input;capacitance:0.1;}pin(Q){direction:output;function:S;\(arc("D",type:"combinational"))\(arc("G",type:"rising_edge"))}}
        }
        """
        let bytes = Array(text.utf8), resources = STALibertyResources()
        let source = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 64), resources: resources)
        let characterized = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["FF", "LAT"],
            propagationCellNames: [], sequentialPropagationCellNames: ["FF", "LAT"],
            limits: .init(maximumNestingDepth: 64), resources: resources)
        let budget = NativeSTAStateBudget(maximum: 100_000), limits = try STAExecutionLimits()
        var work: UInt64 = 0
        for name in ["FF", "LAT"] {
            let cell = try source.library.cell(named: name)
            let tables = cell.arcs.flatMap { [$0.delayRise, $0.delayFall, $0.transitionRise, $0.transitionFall] }
            let minimumInput = try #require(tables.map { $0.inputSlews[0] }.max())
            let maximumInput = try #require(tables.map { $0.inputSlews[$0.inputSlews.count - 1] }.min())
            let transitionValues = cell.arcs.flatMap { $0.transitionRise.values.flatMap { $0 } + $0.transitionFall.values.flatMap { $0 } }
            let minimumOutput = try #require(transitionValues.min()), maximumOutput = try #require(transitionValues.max())
            let plan = try H.compile(model: #require(cell.sequentialModel), source: source.cells.first { $0.name == name },
                work: &work, limits: limits, stateBudget: budget, sourceResources: resources)
            let transition = H.Transition(pin: name == "FF" ? "C" : "D", edge: .rise,
                early: 1e-9, late: name == "FF" ? 2e-9 : 4e-9,
                earlySlew: minimumInput, lateSlew: maximumInput, parentRouteIndex: 0)
            let request: H.TransferRequest
            if name == "FF" {
                request = try H.requestFF(plan: plan, cell: cell, output: "Q", outputEdge: .rise,
                    clock: transition, outputLoad: 1e-12, work: &work, limits: limits, stateBudget: budget)
            } else {
                let window = H.Window(open: .init(edge: .rise, early: 2.5e-9, late: 2.5e-9, earlySlew: minimumInput, lateSlew: maximumInput),
                    close: .init(edge: .fall, early: 10e-9, late: 10e-9, earlySlew: minimumInput, lateSlew: maximumInput), period: 20e-9)
                request = try H.requestLatch(plan: plan, cell: cell, output: "Q", outputEdge: .rise,
                    input: transition, window: window, outputLoad: 1e-12, certified: true, work: &work, limits: limits, stateBudget: budget)
                #expect(request.earlyCandidates.count == 2 && request.lateCandidates.count == 2)
            }
            func point(_ value: H.SampleRequest) throws -> TimingSourcePropagationSample {
                try characterized.evaluatePropagation(cell: name, fromPin: value.pin, toPin: "Q", edge: .rise,
                    inputSlew: value.inputSlew, outputLoad: value.outputLoad)
            }
            func range(_ value: H.SampleRequest) throws -> TimingSourcePropagationRangeSample {
                try characterized.evaluatePropagation(cell: name, fromPin: value.pin, toPin: "Q", edge: .rise,
                    inputSlew: #require(value.inputSlewBounds), outputLoad: value.outputLoad...value.outputLoad)
            }
            let result = try H.complete(request, earlySamples: request.earlyCandidates.map(point), lateSamples: request.lateCandidates.map(point),
                earlyReceiptIndices: Array(request.earlyCandidates.indices), lateReceiptIndices: Array(request.lateCandidates.indices),
                characterized: characterized, earlyRanges: request.earlyCandidates.map(range), lateRanges: request.lateCandidates.map(range),
                work: &work, limits: limits, stateBudget: budget, sourceResources: resources)
            #expect(result.early.outputSlew <= minimumOutput && result.late.outputSlew >= maximumOutput)
            #expect(result.late.arrival >= (name == "FF" ? 6e-9 : 8e-9))
            #expect(result.early.arrival <= (name == "FF" ? 2e-9 : 3.5e-9))
        }
    }

    @Test func publicAPIAndActualCLIKeepCertifiedEvidenceThroughSavedPayloadAndFreshReplay() async throws {
        for invalid in [false, true] {
            let (request, memory) = try nonmonotoneFixture(sourceTransition: invalid ? "0" : "0.2")
            let root = FileManager.default.temporaryDirectory.appending(path: "sta-coupled-cli-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: root) }
                catch { Issue.record("Coupled CLI fixture cleanup failed: \(error)") }
            }
            for binding in request.artifactBindings {
                let path = try binding.localFileURL(relativeTo: root)
                try await memory.read(binding).write(to: path)
            }
            let requestFile = root.appending(path: "request.json")
            try JSONEncoder().encode(request).write(to: requestFile)
            let args = ["run-sta", "--request", requestFile.path, "--maximum-request-bytes", "1048576",
                "--workspace-root", root.path, "--out", root.appending(path: "out").path,
                "--maximum-input-bytes", "33554432", "--maximum-source-storage-bytes", "1073741824",
                "--maximum-source-work", "1000000000", "--source-timeout-seconds", "90"]
            let process = try TimingCLIProcessTests().runExecutable(named: "timingengine", arguments: args)
            if let destination = ProcessInfo.processInfo.environment["TIMING_CLI_EVIDENCE_ROOT"] {
                let folder = URL(fileURLWithPath: destination).appending(path: invalid ? "conservative-request-zero" : "conservative-request-success")
                try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: root, to: folder)
                try Data(process.standardOutput.utf8).write(to: folder.appending(path: "execution-result.json"))
            }
            if invalid {
                #expect(process.exitCode != 0 && process.standardOutput.contains("error"))
                #expect(!FileManager.default.fileExists(atPath: root.appending(path: "out").path))
                continue
            }
            #expect(process.exitCode == 0, Comment(rawValue: process.standardOutput))
            let result = try JSONDecoder().decode(STAExecutionResult.self, from: Data(process.standardOutput.utf8))
            #expect(result.status == .completed && !result.payload.conservativeWireObservations.isEmpty)
            let reader = FileSystemTimingArtifactReader(workspaceRoot: root), engine = NativeSTAEngine(reader: reader)
            let direct = try await engine.execute(request)
            #expect(direct.status == .completed && direct.payload == result.payload)
            let saved = try #require(result.artifactBindings.first)
            let savedBytes = try await reader.read(saved)
            #expect(try JSONDecoder().decode(STAPayload.self, from: savedBytes) == result.payload)
            let fresh = NativeSTAEngine(reader: FileSystemTimingArtifactReader(workspaceRoot: root))
            let prepared = try await fresh.prepare(request, resources: .init(reader: reader,
                sourceLimits: .init(maximumNestingDepth: 64), sourceResources: STALibertyResources(), limits: .init()))
            try await fresh.validateSourceEvidence(result, against: prepared)
            try StrictSTADistributedCoverageValidator().validate(result, request: request,
                requiredNetNames: ["mid"], requiredCornerIDs: request.requestedCornerIDs)
        }
    }

    @Test func negativeThresholdWireDelayBoundsRetainBothDerateExtremes() async throws {
        let spef = STAPropagatedClockFixture.spef.replacingOccurrences(of: "1000", with: "1")
            .replacingOccurrences(of: "1500", with: "1.5")
        let variation = STAVariation(lateCellDelayScale: 1.1, earlyCellDelayScale: 0.9,
            lateInterconnectDelayScale: 1.5, earlyInterconnectDelayScale: 0.5)
        let fixture = try STAPropagatedClockFixture(sdc: STAPropagatedClockFixture.sdc + "\nset_output_delay 0ns -clock clk [get_ports out]", spef: spef, variation: variation)
        let (engine, owner) = try await prepared(selecting(fixture.request), reader: fixture.reader)
        let result = try await engine.execute(owner)
        let raw = try #require(result.payload.conservativeWireObservations.first {
            $0.cornerID == "typical" && $0.net == "leaf" && $0.sink.name == "L:CLK" && $0.edge == .rise
        })
        let clock = try #require(result.payload.clockObservations.first {
            $0.cornerID == "typical" && $0.receiver == "L:CLK" && $0.edge == .rise
        })
        let segment = try #require(clock.segments.first { $0.physicalIdentity == "wire:leaf:L:CLK:rise" })
        #expect(raw.delay.upperBound < 0)
        #expect(segment.earlyDelay <= raw.delay.lowerBound * variation.lateInterconnectDelayScale)
        #expect(segment.lateDelay >= raw.delay.upperBound * variation.earlyInterconnectDelayScale)
        #expect(clock.earlyArrival <= clock.lateArrival)
    }

    @Test(arguments: [false, true]) func idealCaptureChecksUseExplicitClockTransitionInsteadOfGlobalInputSlew(_ controlsOnly: Bool) async throws {
        let original = """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;index_1("0.1,0.4");index_2("0,10");}
          lu_table_template(c){variable_1:constrained_pin_transition;variable_2:related_pin_transition;index_1("0.1,0.4");index_2("0.2,0.3");}
          cell(FF){ff(S,SN){next_state:D;clocked_on:C;}
            pin(C){direction:input;capacitance:0.001;}
            pin(D){direction:input;capacitance:0.001;
              timing(){related_pin:C;timing_type:setup_rising;rise_constraint(c){values("1,4","1,4");}fall_constraint(c){values("1,4","1,4");}}
              timing(){related_pin:C;timing_type:hold_rising;rise_constraint(c){values("1,4","1,4");}fall_constraint(c){values("1,4","1,4");}}}
            pin(Q){direction:output;function:S;timing(){related_pin:C;timing_type:rising_edge;timing_sense:positive_unate;
              cell_rise(t){values("0.1,0.1","0.1,0.1");}cell_fall(t){values("0.1,0.1","0.1,0.1");}
              rise_transition(t){values("0.2,0.2","0.2,0.2");}fall_transition(t){values("0.2,0.2","0.2,0.2");}}}}
        }
        """
        let controlChecks = """
        pin(RN){direction:input;capacitance:0.001;
          timing(){related_pin:C;timing_type:recovery_rising;rise_constraint(c){values("1,4","1,4");}fall_constraint(c){values("1,4","1,4");}}
          timing(){related_pin:C;timing_type:removal_rising;rise_constraint(c){values("1,4","1,4");}fall_constraint(c){values("1,4","1,4");}}}
        """
        let library = Data((controlsOnly ? original.replacingOccurrences(of: "next_state:D;clocked_on:C;", with: "next_state:D;clocked_on:C;clear:\"!RN\";")
            .replacingOccurrences(of: "pin(Q){", with: controlChecks + "pin(Q){") : original).utf8)
        var ports = [TimingDesign.Port(name: "clk", direction: .input), .init(name: "din", direction: .input), .init(name: "out", direction: .output)]
        var connections = ["C":"clk", "D":"din", "Q":"out"]
        if controlsOnly { ports.append(.init(name: "reset", direction: .input)); connections["RN"] = "reset" }
        let design = TimingDesign(topDesignName: "top", ports: ports,
            instances: [.init(name: "F", cell: "FF", connections: connections)],
            nets: (controlsOnly ? ["clk", "din", "out", "reset"] : ["clk", "din", "out"]).map { .init(name: $0) })
        let sdc = Data("""
        create_clock -name clk -period 20ns [get_ports clk]
        set_clock_transition -rise 0.3ns [get_clocks clk]
        set_clock_transition -fall 0.4ns [get_clocks clk]
        set_input_transition 0.2ns [all_inputs]
        set_input_delay -clock clk -max 18ns [get_ports din]
        set_input_delay -clock clk -min 1ns [get_ports din]
        set_output_delay -clock clk 0ns [get_ports out]
        """.utf8)
        let net = controlsOnly ? "reset" : "din", pin = controlsOnly ? "RN" : "D"
        let spef = Data("""
        *SPEF "IEEE 1481-1998"
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *D_NET \(net) 0.001
        *CONN
        *P \(net) I
        *I F:\(pin) I
        *CAP
        1 F:\(pin) 0.001
        *RES
        1 \(net) F:\(pin) 0
        *END
        """.utf8)
        let data = [try JSONEncoder().encode(design), library, sdc, try STATestProcessFactory.data(library: library), spef]
        let formats: [ArtifactFormat] = [.json, .liberty, .sdc, .json, .spef]
        let bindings = try data.enumerated().map { try STAProcessTestFixture.binding($0.element,
            path: "ideal-\($0.offset)", kind: .netlist, format: formats[$0.offset]) }
        let period = try #require(SDCParser().parse(sdc).clocks.first?.period)
        let pulses = controlsOnly ? [try STAControlPulseSource(modeID: "functional", sourcePort: "reset", referenceClock: "clk", period: period,
            risePhase: 18e-9, fallPhase: 19e-9, riseTransition: 0.2e-9, fallTransition: 0.2e-9)] : []
        let request = try STARequest(runID: "ideal-capture-source", design: bindings[0], topDesignName: "top",
            libraries: [.init(artifact: bindings[1], cornerIDs: ["typical"])], constraints: bindings[2],
            requestedModeIDs: ["functional"], requestedCornerIDs: ["typical"], pdkManifest: bindings[3],
            processID: "test", pdkVersion: "1", parasitics: bindings[4],
            analysisKinds: controlsOnly ? [.recovery, .removal] : [.setup, .hold],
            conservativeCoupledRC: options, requireStrictSourceEvidence: true, controlPulseSources: pulses)
        let reader = InMemoryTimingArtifactReader(artifacts: Dictionary(uniqueKeysWithValues: zip(bindings.map(\.id), data)))
        let (engine, owner) = try await prepared(request, reader: reader)
        let result = try await engine.execute(owner)
        let endpoint = try #require(result.payload.endpoints.first { $0.endpoint == (controlsOnly ? "F/RN" : "F/D") })
        #expect(try #require(controlsOnly ? endpoint.recoverySlack : endpoint.setupSlack) <= (controlsOnly ? -3e-9 : -2e-9))
        let explicit = try #require(owner.effectiveConfiguration.clockSources["functional"]?.first?.sourceRiseTransition)
        let evidence = try #require(result.payload.sourceEvidence)
        let checks = evidence.samples.filter { evidence.roles[$0.role].kind == .sequentialCheck }
        if controlsOnly {
            #expect(checks.contains { evidence.roles[$0.role].checkKind == .recovery })
            #expect(checks.contains { evidence.roles[$0.role].checkKind == .removal })
            #expect(!evidence.samples.contains { $0.observation.quantity == .cellDelay })
        }
        #expect(!checks.isEmpty && checks.allSatisfy { $0.observation.secondInput == explicit
            && $0.rangeObservation?.secondInput == explicit...explicit })
        try await engine.validateSourceEvidence(result, against: owner)
    }

    @Test func sourceJoinAdmitsBeforeGrowthAndChargesEveryInnerPinScan() async throws {
        let (request, reader) = try nonmonotoneFixture(explicitInput: false)
        let design = try JSONDecoder().decode(TimingDesign.self, from: await reader.read(request.design))
        let original = String(decoding: try await reader.read(request.libraries[0].artifact), as: UTF8.self)
        let padding = (0..<32).map { "pin(unused\($0)){direction:input;capacitance:0.001;}" }.joined()
        let bytes = Array(original.replacingOccurrences(of: "cell(B){", with: "cell(B){" + padding).utf8)
        let resources = STALibertyResources()
        let source = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 64), resources: resources)
        let characterized = try LibertyParser().parseCharacterizedSource(bytes.span, cellNames: ["B", "C"],
            propagationCellNames: ["B", "C"], sequentialPropagationCellNames: [],
            limits: .init(maximumNestingDepth: 64), resources: resources)
        let cells = try design.instances.map { try source.library.cell(named: $0.cell) }
        let parasitics = try SPEFParser().parse(await reader.read(#require(request.parasitics)))
        let constraints = try SDCParser().parse(await reader.read(request.constraints), modeID: "functional")
        for stateLimited in [true, false] {
            let selected = try STAExecutionLimits(maximumPathWorkUnits: stateLimited ? 100_000 : 16)
            let budget = NativeSTAStateBudget(maximum: stateLimited ? 0 : 100_000)
            var work: UInt64 = 0
            do {
                _ = try NativeSTAConservativeWires(options: options, design: design, cells: cells,
                    source: source, characterized: characterized, constraints: constraints, pulseSources: [],
                    constants: [:], loads: ["mid": 1e-14, "b": 1e-14], parasitics: parasitics,
                    limits: selected, budget: budget, resources: resources, mode: "functional", corner: "typical", work: &work)
                Issue.record("Source join exceeded its admitted state/work boundary")
            } catch STAPathAnalysisError.capacity(let resource, let limit) {
                #expect(resource == (stateLimited ? "cumulative native state slots" : "path work units"))
                #expect(limit == (stateLimited ? 0 : 16))
                #expect(work <= selected.maximumPathWorkUnits)
            }
        }
    }

    private final class ArmedFailureResources: LibertySourceResourceAccounting {
        private let underlying = STALibertyResources()
        private let armed = Mutex(false)
        private let failure: NativeSTAConservativeCouplingError
        init(_ failure: NativeSTAConservativeCouplingError) { self.failure = failure }
        func arm() { armed.withLock { $0 = true } }
        func check() throws {
            let shouldFail = armed.withLock { $0 }
            if shouldFail { throw failure }
            try underlying.check()
        }
        func chargeWork(_ amount: UInt64) throws {
            try check()
            try underlying.chargeWork(amount)
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            try check()
            return try underlying.reserveStorage(kind: kind, byteCount: byteCount)
        }
    }

    @Test func preparedCatchPreservesBackendFaultAndClassifiesCapabilityRefusal() async throws {
        for failure in [NativeSTAConservativeCouplingError.nativeBackendFailure("native solve status -1"),
                        .unsupportedNativeCapability("native solver unavailable")] {
            let (request, reader) = try nonmonotoneFixture()
            let accounting = ArmedFailureResources(failure)
            let engine = NativeSTAEngine(reader: reader)
            let owner = try await engine.prepare(request, resources: .init(reader: reader,
                sourceLimits: .init(maximumNestingDepth: 64), sourceResources: accounting, limits: .init()))
            accounting.arm()
            do {
                _ = try await engine.execute(owner)
                Issue.record("Prepared execution discarded an armed native failure")
            } catch STAExecutionError.underlying(let cause) {
                switch failure {
                case .nativeBackendFailure:
                    #expect(cause as? NativeSTAConservativeCouplingError == failure)
                case .unsupportedNativeCapability(let message):
                    #expect(cause as? TimingError == .unsupportedSemantic(format: "native coupled RC capability", semantic: message))
                default:
                    Issue.record("Unexpected injected failure")
                }
            }
        }
    }

    @Test func requestCatchDiagnosticClassifiesBackendFaultWithoutConflatingRefusals() throws {
        // This verifies the helper used by the request catch, not an end-to-end backend/CLI execution.
        let diagnostic = try #require(NativeSTAEngine.nativeBackendFailureDiagnostic(
            for: NativeSTAConservativeCouplingError.nativeBackendFailure("native solve status -1")))
        #expect(diagnostic.code.rawValue == "timing.sta.native_backend_failed")
        #expect(diagnostic.summary == "native solve status -1")
        #expect(NativeSTAEngine.nativeBackendFailureDiagnostic(
            for: NativeSTAConservativeCouplingError.unsupportedNativeCapability("missing native solver")) == nil)
        #expect(NativeSTAEngine.nativeBackendFailureDiagnostic(
            for: NativeSTAConservativeCouplingError.invalidCertificate("not certified")) == nil)
        #expect(NativeSTAEngine.nativeBackendFailureDiagnostic(for: CancellationError()) == nil)
        #expect(NativeSTAEngine.nativeBackendFailureDiagnostic(
            for: STAPathAnalysisError.capacity(resource: "path work units", limit: 1)) == nil)
        #expect(NativeSTAEngine.nativeBackendFailureDiagnostic(
            for: STAPreparationError.capacity("Liberty source deadline exceeded")) == nil)
    }

    @Test func boundedReplayDiagnosticsPreserveAcceptanceAndIdentifyActualOperands() async throws {
        let (request, reader) = try nonmonotoneFixture()
        let (engine, owner) = try await prepared(request, reader: reader)
        let result = try await engine.execute(owner)
        #expect(result.status == .completed)
        try await engine.validateSourceEvidence(result, against: owner)
        let wire = try #require(result.payload.conservativeWireObservations.first)
        func changedWire(net: String) -> STAConservativeWireObservation {
            .init(modeID: wire.modeID, cornerID: wire.cornerID, net: net, source: wire.source,
                sink: wire.sink, edge: wire.edge, sourceAuthorities: wire.sourceAuthorities,
                sourceSlew: wire.sourceSlew, admittedSourceSlew: wire.admittedSourceSlew,
                delay: wire.delay, slew: wire.slew, voltageErrorUpperBound: wire.voltageErrorUpperBound,
                minimumCrossingDerivative: wire.minimumCrossingDerivative.nextDown,
                maximumAbsoluteDerivative: wire.maximumAbsoluteDerivative)
        }
        var altered = result.payload
        altered.conservativeWireObservations[0] = changedWire(net: wire.net)
        let tampered = try STAExecutionResult(runID: result.runID, status: result.status, payload: altered,
            inputBindings: result.inputBindings, artifactBindings: result.artifactBindings,
            diagnostics: result.diagnostics, provenance: result.evidence.provenance)
        do {
            try await engine.validateSourceEvidence(tampered, against: owner)
            Issue.record("A changed wire certificate passed exact replay")
        } catch STAExecutionError.underlying(let cause) {
            guard let timing = cause as? TimingError, case .invalidInput(let message) = timing else { throw cause }
            #expect(message.contains("conservativeWireObservations[0;"))
            #expect(message.contains("derivativeMin="))
            #expect(message.contains("authorityEqual=true"))
            #expect(message.contains("admittedLo="))
            #expect(message.contains(String(wire.minimumCrossingDerivative.bitPattern, radix: 16)))
            #expect(!message.contains("sourceEvidence"))
            #expect(message.utf8.count <= 4_100)
        }
        altered.conservativeWireObservations[0] = changedWire(net: String(repeating: "very-long-query-", count: 10_000))
        let wireMessage = try NativeSTAEngine.boundedReplayMismatch(observed: altered, actual: result.payload,
            resources: STALibertyResources())
        #expect(wireMessage.utf8.count <= 4_100)
        let evidence = try #require(result.payload.sourceEvidence)
        #expect(evidence.samples.count > 1)
        altered = result.payload
        altered.sourceEvidence = .init(executionInputIdentity: evidence.executionInputIdentity,
            configurationDigest: evidence.configurationDigest, roles: evidence.roles, coverage: evidence.coverage,
            samples: Array(evidence.samples.dropFirst()), pulseWidthSamples: evidence.pulseWidthSamples,
            staticStateSamples: evidence.staticStateSamples, normalPowerSamples: evidence.normalPowerSamples)
        let sourceMessage = try NativeSTAEngine.boundedReplayMismatch(observed: altered, actual: result.payload,
            resources: STALibertyResources())
        #expect(sourceMessage.contains("sourceEvidence.samples[0;"))
        #expect(!sourceMessage.contains("conservativeWireObservations"))
        #expect(sourceMessage.utf8.count <= 4_100)
        #expect(throws: STAPreparationError.self) {
            _ = try NativeSTAEngine.boundedReplayMismatch(observed: altered, actual: result.payload,
                resources: STALibertyResources(maximumWork: 0))
        }
    }

    @Test func algorithmIdentityRejectsLegitimateHistoricalConfigurationAndRelabeling() async throws {
        // Exact configurations and digests from successful checkpoint-6, sparse-8, local-basis-13, residual-26, receiver-batch-30 and source-history-38 public CLI executions.
        let historical = [
            Data("""
            {"algorithmIdentity":"timing.sta.3.10.0","analysisKinds":["setup","hold"],"characterizationBindings":[],"characterizationPolicy":"declaredCornerSelection","clockReceiverScope":[],"clockSources":{"functional":[{"isPropagated":false,"name":"clk","period":2e-08,"source":"clk","uncertainty":0,"waveform":[]}]},"conservativeCoupledRC":{"maximumBasisSweeps":32,"maximumCertificateAttempts":16,"maximumNodes":64,"operatingHistory":"boundedOperatingHistory"},"controlPulseSources":[],"cornerIDs":["typical"],"defaultOutputLoads":{"functional":0},"digest":{"algorithm":"sha256","hexadecimalValue":"baf91e7e7e74bb58c5f541f913237781e0d3d4454488cd684156403c1ac0e725"},"encodingVersion":10,"inputSlews":{"functional":2.0000000000000003e-10},"inputTransitions":{"functional":{"allInputsBothEdges":{"slew":2.0000000000000003e-10}}},"maxPaths":20,"maximumPathStates":100000,"maximumPathWorkUnits":100000000,"modeIDs":["functional"],"operatingSupplyAssumptions":[],"reductionIdentity":"nldm-prescribed-boundary.retained-load.bounded-history.coupled-rc.v1","requireStrictSourceEvidence":true,"requiresPostLayoutInputs":false,"variation":{"earlyCellDelayScale":1,"earlyInterconnectDelayScale":1,"lateCellDelayScale":1,"lateInterconnectDelayScale":1}}
            """.utf8),
            Data("""
            {"algorithmIdentity":"timing.sta.3.11.0","analysisKinds":["setup","hold"],"characterizationBindings":[],"characterizationPolicy":"declaredCornerSelection","clockReceiverScope":[],"clockSources":{"functional":[{"isPropagated":false,"name":"clk","period":2e-08,"source":"clk","uncertainty":0,"waveform":[]}]},"conservativeCoupledRC":{"maximumBasisSweeps":32,"maximumCertificateAttempts":16,"maximumNodes":64,"operatingHistory":"boundedOperatingHistory"},"controlPulseSources":[],"cornerIDs":["typical"],"defaultOutputLoads":{"functional":0},"digest":{"algorithm":"sha256","hexadecimalValue":"177cd2bbe5ceb700760aeb667726930ddb16a2665b8ed73083e1d4fb7a241293"},"encodingVersion":10,"inputSlews":{"functional":2.0000000000000003e-10},"inputTransitions":{"functional":{"allInputsBothEdges":{"slew":2.0000000000000003e-10}}},"maxPaths":20,"maximumPathStates":100000,"maximumPathWorkUnits":100000000,"modeIDs":["functional"],"operatingSupplyAssumptions":[],"reductionIdentity":"nldm-prescribed-boundary.retained-load.bounded-history.coupled-rc.v1","requireStrictSourceEvidence":true,"requiresPostLayoutInputs":false,"variation":{"earlyCellDelayScale":1,"earlyInterconnectDelayScale":1,"lateCellDelayScale":1,"lateInterconnectDelayScale":1}}
            """.utf8),
            Data("""
            {"algorithmIdentity":"timing.sta.3.12.0","analysisKinds":["setup","hold"],"characterizationBindings":[],"characterizationPolicy":"declaredCornerSelection","clockReceiverScope":[],"clockSources":{"functional":[{"isPropagated":false,"name":"clk","period":2e-08,"source":"clk","uncertainty":0,"waveform":[]}]},"conservativeCoupledRC":{"maximumBasisSweeps":32,"maximumCertificateAttempts":16,"maximumNodes":64,"operatingHistory":"boundedOperatingHistory"},"controlPulseSources":[],"cornerIDs":["typical"],"defaultOutputLoads":{"functional":0},"digest":{"algorithm":"sha256","hexadecimalValue":"5eccf84bf887ea328bcd76f104487207b15850d0651d1693ed046d2d9b35b54f"},"encodingVersion":10,"inputSlews":{"functional":2.0000000000000003e-10},"inputTransitions":{"functional":{"allInputsBothEdges":{"slew":2.0000000000000003e-10}}},"maxPaths":20,"maximumPathStates":100000,"maximumPathWorkUnits":100000000,"modeIDs":["functional"],"operatingSupplyAssumptions":[],"reductionIdentity":"nldm-prescribed-boundary.retained-load.bounded-history.coupled-rc.v1","requireStrictSourceEvidence":true,"requiresPostLayoutInputs":false,"variation":{"earlyCellDelayScale":1,"earlyInterconnectDelayScale":1,"lateCellDelayScale":1,"lateInterconnectDelayScale":1}}
            """.utf8),
            Data("""
            {"algorithmIdentity":"timing.sta.3.13.0","analysisKinds":["setup","hold"],"characterizationBindings":[],"characterizationPolicy":"declaredCornerSelection","clockReceiverScope":[],"clockSources":{"functional":[{"isPropagated":false,"name":"clk","period":2e-08,"source":"clk","uncertainty":0,"waveform":[]}]},"conservativeCoupledRC":{"maximumBasisSweeps":32,"maximumCertificateAttempts":16,"maximumNodes":64,"operatingHistory":"boundedOperatingHistory"},"controlPulseSources":[],"cornerIDs":["typical"],"defaultOutputLoads":{"functional":0},"digest":{"algorithm":"sha256","hexadecimalValue":"d7aecb39b6098df50722a66cf6125f73e0a1efa5bc7f0fba5024a9aa33e425fc"},"encodingVersion":10,"inputSlews":{"functional":2.0000000000000003e-10},"inputTransitions":{"functional":{"allInputsBothEdges":{"slew":2.0000000000000003e-10}}},"maxPaths":20,"maximumPathStates":100000,"maximumPathWorkUnits":100000000,"modeIDs":["functional"],"operatingSupplyAssumptions":[],"reductionIdentity":"nldm-prescribed-boundary.retained-load.bounded-history.coupled-rc.v1","requireStrictSourceEvidence":true,"requiresPostLayoutInputs":false,"variation":{"earlyCellDelayScale":1,"earlyInterconnectDelayScale":1,"lateCellDelayScale":1,"lateInterconnectDelayScale":1}}
            """.utf8),
            Data("""
            {"algorithmIdentity":"timing.sta.3.13.1","analysisKinds":["setup","hold"],"characterizationBindings":[],"characterizationPolicy":"declaredCornerSelection","clockReceiverScope":[],"clockSources":{"functional":[{"isPropagated":false,"name":"clk","period":2e-08,"source":"clk","uncertainty":0,"waveform":[]}]},"conservativeCoupledRC":{"maximumBasisSweeps":32,"maximumCertificateAttempts":16,"maximumNodes":64,"operatingHistory":"boundedOperatingHistory"},"controlPulseSources":[],"cornerIDs":["typical"],"defaultOutputLoads":{"functional":0},"digest":{"algorithm":"sha256","hexadecimalValue":"31cadd99db64ecbd287695fc3d7f6b934a0f4b602277633e3ffc6cc52cecb074"},"encodingVersion":10,"inputSlews":{"functional":2.0000000000000003e-10},"inputTransitions":{"functional":{"allInputsBothEdges":{"slew":2.0000000000000003e-10}}},"maxPaths":20,"maximumPathStates":100000,"maximumPathWorkUnits":100000000,"modeIDs":["functional"],"operatingSupplyAssumptions":[],"reductionIdentity":"nldm-prescribed-boundary.retained-load.bounded-history.coupled-rc.v1","requireStrictSourceEvidence":true,"requiresPostLayoutInputs":false,"variation":{"earlyCellDelayScale":1,"earlyInterconnectDelayScale":1,"lateCellDelayScale":1,"lateInterconnectDelayScale":1}}
            """.utf8),
            Data("""
            {"algorithmIdentity":"timing.sta.3.14.0","analysisKinds":["setup","hold"],"characterizationBindings":[],"characterizationPolicy":"declaredCornerSelection","clockReceiverScope":[],"clockSources":{"functional":[{"isPropagated":false,"name":"clk","period":2e-08,"source":"clk","uncertainty":0,"waveform":[]}]},"conservativeCoupledRC":{"maximumBasisSweeps":32,"maximumCertificateAttempts":16,"maximumNodes":64,"operatingHistory":"boundedOperatingHistory"},"controlPulseSources":[],"cornerIDs":["typical"],"defaultOutputLoads":{"functional":0},"digest":{"algorithm":"sha256","hexadecimalValue":"a848ad36990564db6b3eb6969ee902dd6e8e2a4618b95419f3dd26ce85dfc1f0"},"encodingVersion":10,"inputSlews":{"functional":2.0000000000000003e-10},"inputTransitions":{"functional":{"allInputsBothEdges":{"slew":2.0000000000000003e-10}}},"maxPaths":20,"maximumPathStates":100000,"maximumPathWorkUnits":100000000,"modeIDs":["functional"],"operatingSupplyAssumptions":[],"reductionIdentity":"nldm-prescribed-boundary.retained-load.bounded-history.coupled-rc.v1","requireStrictSourceEvidence":true,"requiresPostLayoutInputs":false,"variation":{"earlyCellDelayScale":1,"earlyInterconnectDelayScale":1,"lateCellDelayScale":1,"lateInterconnectDelayScale":1}}
            """.utf8)
        ]
        let oldHashes = ["baf91e7e7e74bb58c5f541f913237781e0d3d4454488cd684156403c1ac0e725",
            "177cd2bbe5ceb700760aeb667726930ddb16a2665b8ed73083e1d4fb7a241293",
            "5eccf84bf887ea328bcd76f104487207b15850d0651d1693ed046d2d9b35b54f",
            "d7aecb39b6098df50722a66cf6125f73e0a1efa5bc7f0fba5024a9aa33e425fc",
            "31cadd99db64ecbd287695fc3d7f6b934a0f4b602277633e3ffc6cc52cecb074",
            "a848ad36990564db6b3eb6969ee902dd6e8e2a4618b95419f3dd26ce85dfc1f0"]
        for (capture, expectedHash) in zip(historical, oldHashes) {
            #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(STAEffectiveConfiguration.self, from: capture) }
            var relabeled = try #require(JSONSerialization.jsonObject(with: capture) as? [String: Any])
            let oldDigest = try #require(relabeled["digest"] as? [String: Any])
            #expect(oldDigest["hexadecimalValue"] as? String == expectedHash)
            relabeled["algorithmIdentity"] = "timing.sta.3.15.0"
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(STAEffectiveConfiguration.self, from: JSONSerialization.data(withJSONObject: relabeled))
            }
        }
        let (request, reader) = try nonmonotoneFixture()
        let (_, owner) = try await prepared(request, reader: reader)
        #expect(owner.effectiveConfiguration.encodingVersion == 10)
        #expect(owner.effectiveConfiguration.algorithmIdentity == "timing.sta.3.15.0")
        #expect(!oldHashes.contains(owner.effectiveConfiguration.digest.hexadecimalValue))
        #expect(try JSONDecoder().decode(STAEffectiveConfiguration.self,
            from: JSONEncoder().encode(owner.effectiveConfiguration)) == owner.effectiveConfiguration)
        for capture in historical {
            let saved = try #require(JSONSerialization.jsonObject(with: capture) as? [String: Any])
            var boundRequest = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            boundRequest["configurationDigest"] = saved["digest"]
            let retained = try JSONDecoder().decode(STARequest.self,
                from: JSONSerialization.data(withJSONObject: boundRequest))
            #expect(retained.configurationDigest != nil)
            do {
                _ = try await prepared(retained, reader: reader)
                Issue.record("A historical explicit configuration digest was rebound to the current algorithm")
            } catch STAPreparationError.configurationMismatch {
                // The caller's explicit historical identity must remain a preparation failure.
            }
        }
    }

}

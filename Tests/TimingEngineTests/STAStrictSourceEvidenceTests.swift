import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import Testing
@testable import STAEngine
import TimingCore

@Suite("Complete strict source execution", .timeLimit(.minutes(1)))
struct STAStrictSourceEvidenceTests {
    private func propagation(_ pin: String, type: String = "combinational", delay: String = "1") -> String {
        """
        timing(){related_pin:\(pin);timing_type:\(type);timing_sense:positive_unate;
          cell_rise(t){values("\(delay),\(delay)","\(delay),\(delay)");}
          cell_fall(t){values("\(delay),\(delay)","\(delay),\(delay)");}
          rise_transition(t){values("0.2,0.2","0.2,0.2");}
          fall_transition(t){values("0.2,0.2","0.2,0.2");}}
        """
    }
    private func checks(_ type: String, related: String, value: String = "0.1") -> String {
        """
        timing(){related_pin:\(related);timing_type:\(type);
          rise_constraint(c){values("\(value),\(value)","\(value),\(value)");}
          fall_constraint(c){values("\(value),\(value)","\(value),\(value)");}}
        """
    }
    private var library: String {
        """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;index_1("0,10");index_2("0,10");}
          lu_table_template(c){variable_1:constrained_pin_transition;variable_2:related_pin_transition;index_1("0,10");index_2("0,10");}
          cell(BUF){pg_pin(VPWR){pg_type:primary_power;}pg_pin(VGND){pg_type:primary_ground;}
            pin(A){direction:input;capacitance:0.1;}pin(Y){direction:output;function:A;\(propagation("A"))}}
          cell(FF){ff(S,SN){next_state:D;clocked_on:C;clear:"!RN";}
            pin(C){direction:input;capacitance:0.1;}
            pin(D){direction:input;capacitance:0.1;\(checks("setup_rising",related:"C"))\(checks("hold_rising",related:"C"))}
            pin(RN){direction:input;capacitance:0.1;\(checks("recovery_rising",related:"C",value:"0.2"))\(checks("removal_rising",related:"C",value:"0.3"))}
            pin(Q){direction:output;function:S;\(propagation("C",type:"rising_edge",delay:"0.5"))}
            pin(QN){direction:output;function:SN;\(propagation("C",type:"rising_edge",delay:"0.6"))}}
          cell(LATCH){latch(S,SN){data_in:D;enable:G;}
            pin(G){direction:input;capacitance:0.1;}
            pin(D){direction:input;capacitance:0.1;\(checks("setup_falling",related:"G",value:"-0.1"))\(checks("hold_falling",related:"G",value:"0.2"))}
            pin(Q){direction:output;function:S;\(propagation("D"))\(propagation("G",type:"rising_edge",delay:"3"))}}
        }
        """
    }
    private func prepare(_ design: TimingDesign, sdc: String, maximumPaths: Int = 10,
                         strict: Bool = true, text: String? = nil, supplies: Bool = true,
                         limits: STAExecutionLimits? = nil) async throws -> (NativeSTAEngine, PreparedSTAExecution) {
        let libraryData = Data((text ?? library).utf8)
        let contents = [try JSONEncoder().encode(design), libraryData, Data(sdc.utf8), try STATestProcessFactory.data(library: libraryData)]
        let formats: [ArtifactFormat] = [.json,.liberty,.sdc,.json]
        let bindings = try contents.enumerated().map { index, data in
            let reference = try ArtifactReference(digest: SHA256ContentDigester().digest(data: data),
                byteCount: UInt64(data.count), descriptor: .init(role: .input, kind: .netlist, format: formats[index]))
            return try TimingArtifactBinding(reference: reference, availability: .local(artifactID: reference.id,
                rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier), relativePath: .init(segments: ["source-\(index)"])))
        }
        var assumptions: [STAOperatingSupplyAssumption] = []
        if supplies {
            for instance in design.instances where instance.cell == "BUF" {
                for (pin, kind, value) in [("VPWR","primary_power",TimingDesign.Constant.one),("VGND","primary_ground",.zero)] {
                    assumptions.append(try .init(instance: instance.name, cell: instance.cell, cornerID: "typical",
                        library: bindings[1].reference, pin: pin, sourcePGType: kind, value: value))
                }
            }
        }
        let request = try STARequest(runID: "strict-source", design: bindings[0], topDesignName: "top",
            libraries: [.init(artifact: bindings[1], cornerIDs: ["typical"])], constraints: bindings[2],
            requestedModeIDs: ["functional"], requestedCornerIDs: ["typical"], pdkManifest: bindings[3],
            processID: "test", pdkVersion: "1", analysisKinds: design.instances.contains(where: { $0.cell == "FF" })
                ? [.setup,.hold,.recovery,.removal] : [.setup,.hold], maxPaths: maximumPaths,
            requireStrictSourceEvidence: strict, operatingSupplyAssumptions: assumptions)
        let reader = InMemoryTimingArtifactReader(artifacts: Dictionary(uniqueKeysWithValues: zip(bindings.map(\.id),contents)))
        let engine = NativeSTAEngine(reader: reader)
        let prepared = try await engine.prepare(request, resources: .init(reader: reader,
            sourceLimits: try .init(maximumNestingDepth: 64), sourceResources: STALibertyResources(), limits: limits ?? .init()))
        return (engine,prepared)
    }
    private var bufferDesign: TimingDesign {
        .init(topDesignName: "top", ports: [.init(name: "a", direction: .input), .init(name: "y", direction: .output),
            .init(name: "z", direction: .output)], instances: [.init(name: "critical", cell: "BUF", connections: ["A":"a","Y":"y"]),
                .init(name: "other", cell: "BUF", connections: ["A":"a","Y":"z"])])
    }
    private let bufferSDC = """
    create_clock -name clk -period 10ns [get_ports a]
    set_input_delay 1ns -clock clk [get_ports a]
    set_input_transition 0.2ns [all_inputs]
    set_output_delay 2ns -clock clk [get_ports y]
    set_output_delay 1ns -clock clk [get_ports z]
    """
    @Test func maxPathsNeverTruncatesNoncriticalSourceReceiptsAndReloadReplayRejectsOmissions() async throws {
        let (engine,prepared) = try await prepare(bufferDesign,sdc:bufferSDC,maximumPaths:1)
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        let (otherEngine,otherPrepared) = try await prepare(bufferDesign,sdc:bufferSDC,maximumPaths:10)
        let other = try await otherEngine.execute(otherPrepared)
        #expect(result.payload.criticalPaths.count == 1)
        #expect(evidence.roles == other.payload.sourceEvidence?.roles && evidence.samples == other.payload.sourceEvidence?.samples)
        #expect(Set(evidence.samples.map { evidence.roles[$0.role].instance }) == ["critical","other"])
        let encoded = try JSONEncoder().encode(result)
        let reloaded = try JSONDecoder().decode(STAExecutionResult.self,from:encoded)
        #expect(reloaded.payload.setupApplicability == .measured && reloaded.payload == result.payload)
        try await engine.validateSourceEvidence(reloaded,against:prepared)
        for field in ["worstSetupSlack", "worstHoldSlack", "criticalPaths", "violations"] {
            var forgedJSON = try #require(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
            var forgedPayload = try #require(forgedJSON["payload"] as? [String:Any])
            if field == "criticalPaths" { forgedPayload[field] = [] as [Any] }
            else if field == "violations" {
                let violation = STAViolation(kind: .setup, modeID: "functional", cornerID: "typical", endpoint: "y", slack: -1e-9)
                forgedPayload[field] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([violation]))
            } else { forgedPayload[field] = 100e-9 }
            forgedJSON["payload"] = forgedPayload
            do {
                let forged = try JSONDecoder().decode(STAExecutionResult.self,from:JSONSerialization.data(withJSONObject:forgedJSON))
                await #expect(throws: STAExecutionError.self) { try await engine.validateSourceEvidence(forged,against:prepared) }
            } catch let error as STASetupApplicabilityError {
                #expect(field == "worstSetupSlack" && error == .invalidStructure)
            }
        }
        var json = try #require(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        var payload = try #require(json["payload"] as? [String:Any])
        var source = try #require(payload["sourceEvidence"] as? [String:Any])
        var samples = try #require(source["samples"] as? [[String:Any]])
        let untouchedSamples = samples
        samples.removeLast(); source["samples"] = samples; payload["sourceEvidence"] = source; json["payload"] = payload
        let omitted = try JSONDecoder().decode(STAExecutionResult.self,from:JSONSerialization.data(withJSONObject:json))
        await #expect(throws: STAExecutionError.self) { try await engine.validateSourceEvidence(omitted,against:prepared) }
        samples = untouchedSamples
        var sample = samples[0], query = try #require(sample["observation"] as? [String:Any])
        query["firstInput"] = 0.4e-9; sample["observation"] = query; samples[0] = sample
        source["samples"] = samples; payload["sourceEvidence"] = source; json["payload"] = payload
        let changed = try JSONDecoder().decode(STAExecutionResult.self,from:JSONSerialization.data(withJSONObject:json))
        await #expect(throws: STAExecutionError.self) { try await engine.validateSourceEvidence(changed,against:prepared) }
        let (staleEngine,stalePrepared) = try await prepare(bufferDesign,
            sdc:bufferSDC.replacingOccurrences(of:"set_input_delay 1ns",with:"set_input_delay 2ns"),maximumPaths:1)
        await #expect(throws: STAExecutionError.self) { try await staleEngine.validateSourceEvidence(reloaded,against:stalePrepared) }
    }
    @Test func strictInputDomainRefusesWhileOrdinaryExtrapolationRemainsAvailable() async throws {
        let sdc = bufferSDC.replacingOccurrences(of:"0.2ns",with:"11ns")
        let (engine,prepared) = try await prepare(bufferDesign,sdc:sdc)
        await #expect(throws: STAExecutionError.self) { try await engine.execute(prepared) }
        let (ordinary,ordinaryPrepared) = try await prepare(bufferDesign,sdc:sdc,strict:false)
        #expect(try await ordinary.execute(ordinaryPrepared).status == .completed)
    }
    @Test func ordinarySplitControlPinsKeepTheirPerKindDataEndpointSummary() async throws {
        var design = STANumericalModelTests.design
        design.ports.append(contentsOf: [.init(name: "rn", direction: .input), .init(name: "sn", direction: .input)])
        design.instances[0].connections["RN"] = "rn"
        design.instances[0].connections["SN"] = "sn"
        let controls = """
        pin(RN){direction:input;timing(){related_pin:CLK;timing_type:recovery_falling;rise_constraint(t){values("0.2");}}}
        pin(SN){direction:input;timing(){related_pin:CLK;timing_type:removal_falling;rise_constraint(t){values("0.3");}}}
        """
        let source = STANumericalModelTests.completeLibrary.replacingOccurrences(of: "pin (CLK) {", with: controls + "\npin (CLK) {")
        let sdc = STANumericalModelTests.sdc + """

        set_input_delay -max 9ns -clock clk [get_ports rn]
        set_input_delay -min 5.1ns -clock clk [get_ports sn]
        """
        let result = try await STANumericalModelTests.execute(source, design: design, sdc: sdc,
            kinds: [.setup,.hold,.recovery,.removal])
        #expect(result.status == .completed)
        let endpoint = try #require(result.payload.endpoints.first { $0.endpoint == "FF/D" })
        #expect(abs(try #require(endpoint.recoverySlack) - 5.8e-9) < 1e-20)
        #expect(abs(try #require(endpoint.removalSlack) + 0.2e-9) < 1e-20)
    }
    @Test func ffLaunchEveryConnectedOutputAndStaticControlApplicabilityHaveExactReceipts() async throws {
        let design = TimingDesign(topDesignName:"top",ports:[.init(name:"clk",direction:.input),.init(name:"d",direction:.input),
            .init(name:"q",direction:.output),.init(name:"qn",direction:.output)],
            instances:[.init(name:"state",cell:"FF",connections:["C":"clk","D":"d","RN":"rn","Q":"q","QN":"qn"])],
            nets:[.init(name:"rn",constant:.one)])
        let sdc = """
        create_clock -name clk -period 10ns [get_ports clk]
        set_input_transition 0.2ns [all_inputs]
        set_input_delay 1ns -clock clk [get_ports d]
        set_output_delay 1ns -clock clk [get_ports q]
        set_output_delay 1ns -clock clk [get_ports qn]
        """
        let (engine,prepared) = try await prepare(design,sdc:sdc,maximumPaths:1)
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        let launches = evidence.samples.filter { $0.sequentialCoordinate?.branch == .clock }
        #expect(Set(launches.map { evidence.roles[$0.role].pin }) == ["Q","QN"])
        #expect(launches.allSatisfy { $0.inputPoint == nil })
        #expect(evidence.roles.filter { $0.checkKind == .recovery || $0.checkKind == .removal }
            .allSatisfy { evidence.checkStatus(for:$0) == .staticControlNotApplicable })
        #expect(result.payload.endpoints.first { $0.endpoint == "state/RN" }?.notApplicableChecks == [.recovery,.removal])
        #expect(result.payload.endpoints.first { $0.endpoint == "state/D" }?.recoverySlack == nil)
        try await engine.validateSourceEvidence(result,against:prepared)
        var disconnected = design
        disconnected.instances[0].connections.removeValue(forKey:"QN")
        disconnected.ports.removeAll { $0.name == "qn" }
        let (single,singlePrepared) = try await prepare(disconnected,sdc:sdc.replacingOccurrences(of:"set_output_delay 1ns -clock clk [get_ports qn]",with:""))
        let singleResult = try await single.execute(singlePrepared), singleEvidence = try #require(singleResult.payload.sourceEvidence)
        #expect(singleEvidence.coverage.contains { singleEvidence.roles[$0.role].pin == "QN" && $0.disposition == .unconnected })
    }
    @Test func absentStrictMeasurementCannotBecomeExcludedAndExactExclusionStillWorks() async throws {
        let design = TimingDesign(topDesignName:"top",ports:[.init(name:"clk",direction:.input),.init(name:"d",direction:.input),
            .init(name:"q",direction:.output)],
            instances:[.init(name:"state",cell:"FF",connections:["C":"clk","D":"d","RN":"rn","Q":"q"])],
            nets:[.init(name:"rn",constant:.one)])
        let sdc = """
        create_clock -name clk -period 10ns [get_ports clk]
        set_input_transition 0.2ns [all_inputs]
        set_output_delay 1ns -clock clk [get_ports q]
        """
        let (engine,prepared) = try await prepare(design,sdc:sdc)
        await #expect(throws: STAExecutionError.self) { try await engine.execute(prepared) }
        let (excluded,excludedPrepared) = try await prepare(design,sdc:sdc + "\nset_false_path -from [get_ports d] -to [get_pins state/D]")
        let result = try await excluded.execute(excludedPrepared)
        #expect(result.payload.endpoints.first { $0.endpoint == "state/D" }?.excludedChecks == [.setup,.hold])
    }
    @Test func everyUsedCombinationalPinPowerFunctionRequiresExactExplicitConditions() async throws {
        let powered = library.replacingOccurrences(of:"pin(Y){direction:output;function:A;",with:"pin(Y){direction:output;function:A;power_down_function:\"!VPWR + VGND\";")
        let (missing,missingPrepared) = try await prepare(bufferDesign,sdc:bufferSDC,text:powered,supplies:false)
        await #expect(throws: STAExecutionError.self) { try await missing.execute(missingPrepared) }
        let (engine,prepared) = try await prepare(bufferDesign,sdc:bufferSDC,text:powered,supplies:true)
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        #expect(evidence.coverage.filter { evidence.roles[$0.role].kind == .powerPin }.allSatisfy { $0.disposition == .staticZero || $0.disposition == .staticOne })
        try await engine.validateSourceEvidence(result,against:prepared)
    }
    @Test func stateBudgetAndCancellationRefuseWithoutPartialStrictResults() async throws {
        await #expect(throws: STAPreparationError.self) {
            try await prepare(bufferDesign,sdc:bufferSDC,limits:.init(maximumPathStates:1))
        }
        let (engine,prepared) = try await prepare(bufferDesign,sdc:bufferSDC)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: STAExecutionError.self) { try await engine.execute(prepared) }
        }
        await cancelled.value
    }
    @Test func latchTransfersRetainActualBranchesSignedWindowsAndInteriorEnvelope() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "clk", direction: .input),
            .init(name: "d", direction: .input), .init(name: "q", direction: .output)],
            instances: [.init(name: "storage", cell: "LATCH", connections: ["G":"clk","D":"d","Q":"q"])])
        for (early, late, expectedEarly, expectedLate) in [(-1.0,-1.0,3.0,3.0),(1,1,2,2),(6,6,13,13),(-1,4,1,5)] {
            let sdc = """
            create_clock -name clk -period 10ns [get_ports clk]
            set_input_transition 0.2ns [all_inputs]
            set_input_delay -min \(early)ns -clock clk [get_ports d]
            set_input_delay -max \(late)ns -clock clk [get_ports d]
            set_output_delay 0ns -clock clk [get_ports q]
            """
            let (engine,prepared) = try await prepare(design,sdc:sdc)
            let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
            let q = try #require(result.payload.endpoints.first { $0.endpoint == "q" })
            #expect(abs(try #require(q.dataArrival) - expectedLate * 1e-9) < 1e-22)
            #expect(abs(try #require(q.holdSlack) - expectedEarly * 1e-9) < 1e-22)
            let coordinates = evidence.samples.compactMap(\.sequentialCoordinate)
            #expect(!coordinates.isEmpty && coordinates.allSatisfy { $0.causalEarly <= $0.selectedInputCoordinate && $0.selectedInputCoordinate <= $0.causalLate })
            if early == -1 && late == 4 {
                #expect(coordinates.contains { $0.branch == .data && $0.meaning == .infimum })
                #expect(coordinates.contains { $0.branch == .gate })
            }
            if early == 6 { #expect(coordinates.contains { $0.cycle == 1 && $0.waiting > 0 }) }
            try await engine.validateSourceEvidence(result,against:prepared)
        }
    }
    @Test func acyclicLatchChainExecutesAndTransparentFeedbackCycleRefuses() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "clk", direction: .input),
            .init(name: "d", direction: .input), .init(name: "q", direction: .output)],
            instances: [.init(name: "first", cell: "LATCH", connections: ["G":"clk","D":"d","Q":"middle"]),
                .init(name: "second", cell: "LATCH", connections: ["G":"clk","D":"middle","Q":"q"])],
            nets: [.init(name: "middle")])
        let sdc = """
        create_clock -name clk -period 10ns [get_ports clk]
        set_input_transition 0.2ns [all_inputs]
        set_input_delay 1ns -clock clk [get_ports d]
        set_output_delay 0ns -clock clk [get_ports q]
        """
        let (engine,prepared) = try await prepare(design,sdc:sdc)
        let result = try await engine.execute(prepared)
        #expect(abs(try #require(result.payload.endpoints.first { $0.endpoint == "q" }?.dataArrival) - 3e-9) < 1e-22)
        #expect(result.payload.criticalPaths.contains { $0.endpoint == "q" && $0.stages.count == 2 })
        try await engine.validateSourceEvidence(result,against:prepared)
        var cycle = design
        cycle.instances[0].connections["D"] = "q"
        let (cyclic,cyclicPrepared) = try await prepare(cycle,sdc:sdc)
        await #expect(throws: STAExecutionError.self) { try await cyclic.execute(cyclicPrepared) }
    }
    @Test func propagatedClockBufferAndStepLessFFReceiptsCoverBothExactCorners() async throws {
        let fixture = try STAPropagatedClockFixture(sdc: STAPropagatedClockFixture.sdc
            + "\nset_output_delay 0ns -clock clk [get_ports out]")
        let base = fixture.request
        let request = try STARequest(runID: base.runID, design: base.design, topDesignName: base.topDesignName,
            libraries: base.libraries, constraints: base.constraints, requestedModeIDs: base.requestedModeIDs,
            requestedCornerIDs: base.requestedCornerIDs, pdkManifest: base.pdkManifest, processID: base.processID,
            pdkVersion: base.pdkVersion, parasitics: base.parasitics, analysisKinds: base.analysisKinds, maxPaths: 1,
            requiresPostLayoutInputs: base.requiresPostLayoutInputs, variation: base.variation,
            distributedRC: base.distributedRC, requireStrictSourceEvidence: true)
        let engine = NativeSTAEngine(reader: fixture.reader)
        let prepared = try await engine.prepare(request,resources:.init(reader:fixture.reader,
            sourceLimits:try .init(maximumNestingDepth:64),sourceResources:STALibertyResources(),limits:try .init()))
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        #expect(Set(evidence.samples.filter { evidence.roles[$0.role].instance == "B" }.map { evidence.roles[$0.role].cornerID }) == ["typical","slow"])
        #expect(evidence.samples.contains { evidence.roles[$0.role].instance == "L" && $0.sequentialCoordinate?.branch == .clock })
        #expect(result.payload.clockObservations.count == 8)
        try StrictSTADistributedCoverageValidator().validate(result,request:request,
            requiredNetNames:["root","leaf","data"],requiredCornerIDs:["typical","slow"])
        try await engine.validateSourceEvidence(result,against:prepared)
    }

    @Test func totalDeclaredPGIsRequiredEvenWithoutPowerDownLawAndReceiptsReplayExactly() async throws {
        let (missing,missingPrepared) = try await prepare(bufferDesign,sdc:bufferSDC,supplies:false)
        await #expect(throws:STAExecutionError.self) { try await missing.execute(missingPrepared) }
        let (engine,prepared) = try await prepare(bufferDesign,sdc:bufferSDC)
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        #expect(evidence.version == 3 && result.payload.effectiveConfiguration?.encodingVersion == 9)
        #expect(evidence.normalPowerSamples.count == 2)
        let reloaded = try JSONDecoder().decode(STAExecutionResult.self,from:JSONEncoder().encode(result))
        #expect(reloaded.payload.sourceEvidence == evidence)
        try await engine.validateSourceEvidence(reloaded,against:prepared)
        #expect(evidence.normalPowerSamples.allSatisfy { $0.observation.pgValues.count == 2 && $0.observation.functions.isEmpty })
        #expect(evidence.coverage.filter { evidence.roles[$0.role].kind == .normalPower }.allSatisfy { $0.disposition == .evaluated })
        try await engine.validateSourceEvidence(result,against:prepared)
        var object = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(result)) as? [String:Any])
        var payload = try #require(object["payload"] as? [String:Any]), source = try #require(payload["sourceEvidence"] as? [String:Any])
        var observations = try #require(source["normalPowerSamples"] as? [[String:Any]])
        var observation = try #require(observations[0]["observation"] as? [String:Any])
        var values = try #require(observation["pgValues"] as? [[String:Any]])
        values.removeLast(); observation["pgValues"] = values; observations[0]["observation"] = observation
        source["normalPowerSamples"] = observations; payload["sourceEvidence"] = source; object["payload"] = payload
        let forged = try JSONDecoder().decode(STAExecutionResult.self,from:JSONSerialization.data(withJSONObject:object))
        await #expect(throws:STAExecutionError.self) { try await engine.validateSourceEvidence(forged,against:prepared) }
        source["version"] = 2; payload["sourceEvidence"] = source; object["payload"] = payload
        #expect(throws:(any Error).self) { try JSONDecoder().decode(STAExecutionResult.self,from:JSONSerialization.data(withJSONObject:object)) }
    }

    @Test func preparedDesignBindingUsesSemanticNamedIdentityAndPreservesMetadata() async throws {
        var design = bufferDesign
        design.nets = [.init(name:"a"),.init(name:"y"),.init(name:"z")]
        let (_,prepared) = try await prepare(design,sdc:bufferSDC)
        var equivalent = design
        equivalent.ports.reverse(); equivalent.instances.reverse(); equivalent.nets.reverse()
        for index in equivalent.ports.indices { equivalent.ports[index].net = equivalent.ports[index].name }
        try prepared.requireDesignBinding(to:equivalent)
        for field in ["top","port","clock","master","connection","capacitance","constant","missing","extra","duplicate"] {
            var changed = design
            switch field {
            case "top": changed.topDesignName = "different"
            case "port": changed.ports[0].direction = .output
            case "clock": changed.ports[0].clock = "other"
            case "master": changed.instances[0].cell = "FF"
            case "connection": changed.instances[0].connections["A"] = "z"
            case "capacitance": changed.nets[0].capacitance = 1e-15
            case "constant": changed.nets[0].constant = .zero
            case "missing": changed.instances.removeLast()
            case "extra": changed.instances.append(.init(name:"extra",cell:"BUF",connections:["A":"a","Y":"y"]))
            default: changed.ports[1].name = changed.ports[0].name
            }
            #expect(throws:STADesignBindingError.self) { try prepared.requireDesignBinding(to:changed) }
        }
        let (_,bounded) = try await prepare(design,sdc:bufferSDC,limits:.init(maximumPathWorkUnits:20_000))
        var refused = false
        for _ in 0..<1000 {
            do { try bounded.requireDesignBinding(to:equivalent) }
            catch STADesignBindingError.capacity { refused = true; break }
        }
        #expect(refused)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws:STADesignBindingError.self) { try prepared.requireDesignBinding(to:equivalent) }
        }
        await cancelled.value
    }

}

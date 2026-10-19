import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import Testing
import TimingCore
@testable import STAEngine

@Suite("Source pulse applicability and held asynchronous state", .timeLimit(.minutes(1)))
struct STAPulseApplicabilityTests {
    private func arc(_ input: String, type: String = "rising_edge", sense: String = "positive_unate") -> String {
        """
        timing(){related_pin:\(input);timing_type:\(type);timing_sense:\(sense);
          cell_rise(t){values("0.2,0.2","0.2,0.2");}cell_fall(t){values("0.2,0.2","0.2,0.2");}
          rise_transition(t){values("0.2,0.2","0.2,0.2");}fall_transition(t){values("0.3,0.3","0.3,0.3");}}
        """
    }
    private func check(_ type: String) -> String {
        """
        timing(){related_pin:C;timing_type:\(type);
          rise_constraint(c){values("0.1,0.1","0.1,0.1");}fall_constraint(c){values("0.1,0.1","0.1,0.1");}}
        """
    }
    private func library(pulses: Bool = true, reset: Bool = true, preset: Bool = false) -> String {
        let clockPulse = pulses ? """
        timing(){related_pin:C;related_output_pin:Q;timing_type:min_pulse_width;
          rise_constraint(p){values("0.5,1.5");}fall_constraint(p){values("0.6,1.6");}}
        """ : ""
        let resetPulse = pulses && reset ? """
        timing(){related_pin:RN;related_output_pin:Q;timing_type:min_pulse_width;fall_constraint(p){values("0.4,1.4");}}
        """ : ""
        let controls = reset ? "clear:\"!RN\";" : ""
        let presetControl = preset ? "preset:PN;" : ""
        let resetPin = reset ? "pin(RN){direction:input;capacitance:0.02;\(check("recovery_rising"))\(check("removal_rising"))\(resetPulse)}" : ""
        let presetPin = preset ? "pin(PN){direction:input;capacitance:0.02;}" : ""
        let clearArc = reset ? """
        timing(){related_pin:RN;timing_type:clear;timing_sense:positive_unate;
          cell_fall(t){values("0.2,0.2","0.2,0.2");}fall_transition(t){values("0.3,0.3","0.3,0.3");}}
        """ : ""
        return """
        library(L){time_unit:"1ns";capacitive_load_unit(1,pf);
          lu_table_template(t){variable_1:input_net_transition;variable_2:total_output_net_capacitance;index_1("0,10");index_2("0,10");}
          lu_table_template(c){variable_1:constrained_pin_transition;variable_2:related_pin_transition;index_1("0,10");index_2("0,10");}
          lu_table_template(p){variable_1:related_pin_transition;index_1("0,10");}
          cell(TIE0){pin(Y){direction:output;function:0;}}
          cell(TIE1){pin(Y){direction:output;function:1;}}
          cell(INV){pin(A){direction:input;capacitance:0.02;}pin(Y){direction:output;function:"!A";\(arc("A",type:"combinational",sense:"negative_unate"))}}
          cell(FF){ff(S,SN){next_state:D;clocked_on:C;\(controls)\(presetControl)}
            pin(C){direction:input;capacitance:0.02;\(clockPulse)}
            pin(D){direction:input;capacitance:0.02;\(check("setup_rising"))\(check("hold_rising"))}
            \(resetPin)\(presetPin)
            pin(Q){direction:output;function:S;\(arc("C"))\(clearArc)}
            pin(QN){direction:output;function:SN;\(arc("C"))}}
        }
        """
    }
    private func design(reset: TimingDesign.Constant? = .one, sourceTie: Bool = false, invert: Bool = false,
                        preset: TimingDesign.Constant? = nil, resetPresent: Bool = true) -> TimingDesign {
        var ports: [TimingDesign.Port] = [.init(name:"clockIn",direction:.input,net:"clockNet"),
            .init(name:"d",direction:.input,net:"dataNet"),.init(name:"q",direction:.output,net:"qNet"),
            .init(name:"qn",direction:.output,net:"qnNet")]
        var connections = ["C":"clockNet","D":"dataNet","Q":"qNet","QN":"qnNet"]
        var instances: [TimingDesign.Instance] = []
        var nets: [TimingDesign.Net] = [.init(name:"clockNet"),.init(name:"dataNet"),.init(name:"qNet"),.init(name:"qnNet")]
        if resetPresent {
            connections["RN"] = "resetNet"
            if let reset {
                if sourceTie { instances.append(.init(name:"tie",cell:reset == .one ? "TIE1" : "TIE0",connections:["Y":"resetNet"])); nets.append(.init(name:"resetNet")) }
                else { nets.append(.init(name:"resetNet",constant:reset)) }
            } else {
                ports.append(.init(name:"resetIn",direction:.input,net:invert ? "resetRoot" : "resetNet"))
                nets.append(.init(name:"resetNet"))
                if invert {
                    nets.append(.init(name:"resetRoot"))
                    instances.append(.init(name:"resetBuffer",cell:"INV",connections:["A":"resetRoot","Y":"resetNet"]))
                }
            }
        }
        if let preset { connections["PN"] = "presetNet"; nets.append(.init(name:"presetNet",constant:preset)) }
        instances.append(.init(name:"state",cell:"FF",connections:connections))
        return .init(topDesignName:"top",ports:ports,instances:instances,nets:nets)
    }
    private func spef(_ design: TimingDesign, ideal: Bool = false) -> String {
        var result = "*SPEF \"IEEE 1481-1998\"\n*C_UNIT 1 PF\n*R_UNIT 1 OHM\n"
        for net in design.nets where net.constant == nil {
            var endpoints: [(String,String)] = []
            for port in design.ports where port.netName == net.name { endpoints.append(("*P " + port.name,port.direction == .input ? "I" : "O")) }
            for instance in design.instances {
                for pin in instance.connections.keys.sorted() where instance.connections[pin] == net.name {
                    endpoints.append(("*I " + instance.name + ":" + pin,["Q","QN","Y"].contains(pin) ? "O" : "I"))
                }
            }
            guard let driver = endpoints.first(where: { $0.0.hasPrefix("*P ") && $0.1 == "I" || $0.0.hasPrefix("*I ") && $0.1 == "O" }) else { continue }
            result += "*D_NET \(net.name) 0.05\n*CONN\n"
            for endpoint in endpoints { result += "\(endpoint.0) \(endpoint.1)\n" }
            let receiver = endpoints.first(where: { $0.0 != driver.0 }) ?? driver
            result += "*CAP\n1 \(receiver.0.dropFirst(3)) 0.05\n*RES\n"
            for (index,endpoint) in endpoints.filter({ $0.0 != driver.0 }).enumerated() {
                result += "\(index+1) \(driver.0.dropFirst(3)) \(endpoint.0.dropFirst(3)) \(ideal ? 0 : 100)\n"
            }
            result += "*END\n"
        }
        return result
    }
    private func prepared(_ design: TimingDesign, text: String, kinds: [STAAnalysisKind] = [.setup,.hold,.recovery,.removal,.pulseWidth],
                          waveform: Bool = false, extraSDC: String = "", period: String = "10ns", fall: String = "6ns", ideal: Bool = false) async throws -> (NativeSTAEngine,PreparedSTAExecution) {
        let sdc = """
        create_clock -name clk -period \(period) -waveform {1ns \(fall)} [get_ports clockIn]
        set_clock_transition -rise 0.2ns [get_clocks clk]
        set_clock_transition -fall 0.3ns [get_clocks clk]
        set_propagated_clock [get_clocks clk]
        set_input_transition 0.2ns [all_inputs]
        set_input_delay 2ns -clock clk [get_ports d]
        set_output_delay 1ns -clock clk [get_ports q]
        set_output_delay 1ns -clock clk [get_ports qn]
        \(extraSDC)
        """
        let liberty = Data(text.utf8)
        let contents = [try JSONEncoder().encode(design),liberty,Data(sdc.utf8),try STATestProcessFactory.data(library:liberty),Data(spef(design,ideal:ideal).utf8)]
        let formats: [ArtifactFormat] = [.json,.liberty,.sdc,.json,.spef]
        let bindings = try contents.enumerated().map { index,data in
            let reference = try ArtifactReference(digest:SHA256ContentDigester().digest(data:data),byteCount:UInt64(data.count),
                descriptor:.init(role:.input,kind:.netlist,format:formats[index]))
            return try TimingArtifactBinding(reference:reference,availability:.local(artifactID:reference.id,
                rootID:.init(rawValue:TimingArtifactBinding.workspaceRootIdentifier),relativePath:.init(segments:["pulse-\(index)"])))
        }
        let pulse = waveform ? [try STAControlPulseSource(modeID:"functional",sourcePort:"resetIn",referenceClock:"clk",
            period:10e-9,risePhase:2e-9,fallPhase:7e-9,riseTransition:0.2e-9,fallTransition:0.3e-9)] : []
        let request = try STARequest(runID:"pulse",design:bindings[0],topDesignName:"top",
            libraries:[.init(artifact:bindings[1],cornerIDs:["typical"])],constraints:bindings[2],requestedModeIDs:["functional"],
            requestedCornerIDs:["typical"],pdkManifest:bindings[3],processID:"test",pdkVersion:"1",parasitics:bindings[4],
            analysisKinds:kinds,distributedRC:try .init(maximumTimeStep:1e-11,stopTime:80e-9,crossingTolerance:1e-12,
                maximumRefinements:8,maximumNodes:16,maximumSteps:2_000_000),requireStrictSourceEvidence:true,controlPulseSources:pulse)
        let reader = InMemoryTimingArtifactReader(artifacts:Dictionary(uniqueKeysWithValues:zip(bindings.map(\.id),contents)))
        let engine = NativeSTAEngine(reader:reader)
        return (engine,try await engine.prepare(request,resources:.init(reader:reader,sourceLimits:try .init(maximumNestingDepth:64),
            sourceResources:STALibertyResources(),limits:try .init())))
    }

    @Test func absentSourceLawsAreExplicitlyNotApplicableWithAllKindsRequested() async throws {
        let (engine,prepared) = try await prepared(design(resetPresent:false),text:library(pulses:false,reset:false))
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        let absent = evidence.roles.filter { $0.kind == .checkApplicability }
        #expect(Set(absent.compactMap(\.analysisKind)) == [.recovery,.removal,.pulseWidth])
        #expect(absent.allSatisfy { evidence.checkStatus(for:$0) == .sourceNotApplicable })
        #expect(evidence.pulseWidthSamples.isEmpty && result.payload.setupApplicability == .measured)
        try result.payload.validateSetupApplicabilityStructure()
        var forged = result.payload
        forged.setupApplicability = .sourceNotApplicable; forged.worstSetupSlack = nil
        #expect(throws:STASetupApplicabilityError.invalidStructure) { try forged.validateSetupApplicabilityStructure() }
        #expect(throws:STASetupApplicabilityError.invalidStructure) {
            try JSONDecoder().decode(STAPayload.self,from:JSONEncoder().encode(forged))
        }
        for field in ["static", "notApplicable"] {
            for count in [2,6] {
                var nested = result.payload
                if field == "static" { nested.endpoints[0].staticChecks = Array(repeating:.hold,count:count) }
                else { nested.endpoints[0].notApplicableChecks = Array(repeating:.hold,count:count) }
                let expected: STASetupApplicabilityError = count == 6 ? .capacity : .invalidStructure
                #expect(throws:expected) { try nested.validateSetupApplicabilityStructure() }
            }
        }
        try await engine.validateSourceEvidence(result,against:prepared)
    }
    @Test func highAndLowUseExactReceivedEdgesActualSourceSlewAndReplayRejectsTampering() async throws {
        let (engine,prepared) = try await prepared(design(),text:library())
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        let measured = evidence.pulseWidthSamples
        #expect(measured.count == 4 && Set(measured.map { $0.observation.openingEdge }) == [.rise,.fall])
        #expect(measured.allSatisfy { $0.observation.inputSlew == $0.openingSlew && !$0.openingSegments.isEmpty && !$0.closingSegments.isEmpty })
        for sample in measured {
            let pin = evidence.roles[sample.role].pin
            #expect(pin == "C" && sample.rootSource == "clk")
            #expect(abs(sample.minimumWidth - ((sample.observation.openingEdge == .rise ? 0.5e-9 : 0.6e-9) + 0.1 * sample.openingSlew)) < 1e-22)
        }
        #expect(evidence.roles.filter { $0.pin == "RN" && $0.analysisKind != nil }.allSatisfy { evidence.checkStatus(for:$0) == .staticControlNotApplicable })
        try await engine.validateSourceEvidence(result,against:prepared)
        var object = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(result)) as? [String:Any])
        var payload = try #require(object["payload"] as? [String:Any]), source = try #require(payload["sourceEvidence"] as? [String:Any])
        var pulses = try #require(source["pulseWidthSamples"] as? [[String:Any]])
        pulses[0]["openingArrival"] = measured[0].openingArrival + 1e-10
        source["pulseWidthSamples"] = pulses; payload["sourceEvidence"] = source; object["payload"] = payload
        let forged = try JSONDecoder().decode(STAExecutionResult.self,from:JSONSerialization.data(withJSONObject:object))
        await #expect(throws:STAExecutionError.self) { try await engine.validateSourceEvidence(forged,against:prepared) }
    }
    @Test func sourceTieInactiveAndAssertedResetPreserveActualStateAndDistinctCost() async throws {
        for value in [TimingDesign.Constant.one,.zero] {
            let (engine,prepared) = try await prepared(design(reset:value,sourceTie:true),text:library())
            let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
            let state = try #require(evidence.staticStateSamples.first { evidence.roles[$0.role].instance == "state" })
            if value == .one {
                #expect(state.effect == .inactive && state.outputConstants.isEmpty)
                #expect(evidence.samples.contains { $0.sequentialCoordinate?.branch == .clock })
                #expect(result.payload.setupApplicability == .measured)
            } else {
                #expect(state.effect == .clear && state.outputConstants == ["Q":.zero,"QN":.one])
                #expect(!evidence.samples.contains { $0.sequentialCoordinate?.branch == .clock })
                #expect(result.payload.endpoints.first { $0.endpoint == "q" }?.staticValue == .zero)
                #expect(result.payload.endpoints.first { $0.endpoint == "qn" }?.staticValue == .one)
                #expect(result.payload.worstSetupSlack == nil && result.payload.setupApplicability == .sourceNotApplicable)
                try result.payload.validateSetupApplicabilityStructure()
                #expect(evidence.roles.filter { $0.checkKind == .setup || $0.checkKind == .hold }.allSatisfy { evidence.checkStatus(for:$0) == .staticStateNotApplicable })
            }
            #expect(evidence.pulseWidthSamples.count == 4)
            #expect(evidence.coverage.contains { evidence.roles[$0.role].kind == .directionalControlPropagation && ($0.disposition == .staticZero || $0.disposition == .staticOne) })
            try await engine.validateSourceEvidence(result,against:prepared)
        }
    }
    @Test func presetUsesOriginalComplementedStateAndSimultaneousActionsRefuse() async throws {
        let (engine,prepared) = try await prepared(design(reset:.one,preset:.one),text:library(preset:true))
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        #expect(evidence.staticStateSamples.first?.effect == .preset)
        #expect(evidence.staticStateSamples.first?.outputConstants == ["Q":.one,"QN":.zero])
        try await engine.validateSourceEvidence(result,against:prepared)
        let (conflict,conflictPrepared) = try await self.prepared(design(reset:.zero,preset:.one),text:library(preset:true))
        await #expect(throws:STAExecutionError.self) { try await conflict.execute(conflictPrepared) }
    }
    @Test func explicitPrimaryControlWaveformTraversesPeriodicRCAndSourceInverterWithoutGrantingAsyncQTiming() async throws {
        let graph = design(reset:nil,invert:true)
        let inputPulse = library().replacingOccurrences(of:"cell(INV){pin(A){direction:input;capacitance:0.02;}",
            with:"cell(INV){pin(A){direction:input;capacitance:0.02;min_pulse_width_high:0.5;}")
        let (engine,prepared) = try await prepared(graph,text:inputPulse,kinds:[.recovery,.removal,.pulseWidth],waveform:true)
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        let reset = evidence.pulseWidthSamples.filter { evidence.roles[$0.role].pin == "RN" }
        #expect(reset.count == 2 && reset.allSatisfy { $0.rootSource == "resetIn" && $0.openingRootEdge == .rise && $0.closingRootEdge == .fall })
        #expect(reset.allSatisfy { $0.openingSegments.count == 3 && $0.closingSegments.count == 3 })
        #expect(evidence.samples.contains { evidence.roles[$0.role].instance == "resetBuffer" })
        let inputSamples = evidence.pulseWidthSamples.filter { evidence.roles[$0.role].instance == "resetBuffer" }
        #expect(inputSamples.count == 2 && inputSamples.allSatisfy { evidence.roles[$0.role].pin == "A" && $0.observation.openingEdge == .rise })
        #expect(inputSamples.allSatisfy { $0.observation.inputSlew == nil && abs($0.minimumWidth - 0.5e-9) < 1e-24 })
        #expect(result.payload.endpoints.first { $0.endpoint == "resetBuffer/A" }?.pulseWidthSlack != nil)
        #expect(evidence.samples.contains { evidence.roles[$0.role].checkKind == .recovery })
        #expect(evidence.samples.contains { evidence.roles[$0.role].checkKind == .removal })
        #expect(result.payload.wireObservations.contains { $0.net == "resetRoot" && $0.period != nil })
        #expect(result.payload.wireObservations.contains { $0.net == "resetNet" && $0.period != nil })
        try await engine.validateSourceEvidence(result,against:prepared)
        let (data,dataPrepared) = try await self.prepared(graph,text:library(),waveform:true)
        await #expect(throws:STAExecutionError.self) { try await data.execute(dataPrepared) }
        let (unknown,unknownPrepared) = try await self.prepared(graph,text:library(),kinds:[.recovery,.removal,.pulseWidth])
        await #expect(throws:STAExecutionError.self) { try await unknown.execute(unknownPrepared) }
        await #expect(throws:STAPreparationError.self) {
            try await self.prepared(graph,text:library(),kinds:[.recovery,.removal,.pulseWidth],waveform:true,
                extraSDC:"set_input_delay -max 0ns -clock clk [get_ports resetIn]")
        }
    }
    @Test func idealShortThresholdOffsetsRemainSignedAndReplayValidatesActualPulse() async throws {
        let thresholds = library().replacingOccurrences(of:"library(L){",with:"""
        library(L){input_threshold_pct_rise:40;input_threshold_pct_fall:60;
          output_threshold_pct_rise:50;output_threshold_pct_fall:50;
        """)
        let (engine,prepared) = try await prepared(design(reset:nil,invert:true),text:thresholds,
            kinds:[.recovery,.removal,.pulseWidth],waveform:true,ideal:true)
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        #expect(evidence.pulseWidthSamples.contains { sample in
            sample.openingSegments.contains { $0.earlyDelay < 0 && $0.lateDelay < 0 }
        })
        #expect(evidence.pulseWidthSamples.allSatisfy { $0.actualWidth.isFinite && $0.actualWidth > 0 })
        #expect(result.payload.wireObservations.contains { $0.method == .idealConstraint && $0.wireDelay < 0 && $0.period != nil })
        try await engine.validateSourceEvidence(result,against:prepared)
    }
    @Test func narrowHighPulseProducesActualViolationAndDoesNotWrapReceivedEdges() async throws {
        let (engine,prepared) = try await prepared(design(),text:library(),fall:"1.5ns")
        let result = try await engine.execute(prepared), evidence = try #require(result.payload.sourceEvidence)
        #expect(evidence.pulseWidthSamples.filter { $0.observation.openingEdge == .rise }.allSatisfy { $0.slack < 0 && $0.closingCycleOffset == 0 })
        #expect(result.payload.violations.contains { $0.kind == .pulseWidth && $0.endpoint == "state/C" })
        try await engine.validateSourceEvidence(result,against:prepared)
    }
}

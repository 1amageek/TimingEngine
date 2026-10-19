import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import STAEngine
import Testing
import TimingCore
import TimingEngine

@Suite(.timeLimit(.minutes(1)))
struct STAConnectivityTests {
    func execute(_ design: Data, constraints: String, kinds: [STAAnalysisKind] = [.setup, .hold], libraryText: String = TimingCoreTests.liberty, limits: STAExecutionLimits? = nil, maximumPaths: Int = 10, modes: [String] = ["functional"], variation: STAVariation = .init()) async throws -> STAExecutionResult {
        let library = Data(libraryText.utf8)
        let pdk = try STATestProcessFactory.data(library: library)
        let contents = [design, library, Data(constraints.utf8), pdk]
        let formats: [ArtifactFormat] = [.json, .liberty, .sdc, .json]
        let references = try contents.enumerated().map { index, bytes in
            let reference = try ArtifactReference(digest: SHA256ContentDigester().digest(data: bytes),
                byteCount: UInt64(bytes.count), descriptor: .init(role: .input, kind: .netlist, format: formats[index]))
            return try TimingArtifactBinding(reference: reference, availability: .local(artifactID: reference.id,
                rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier), relativePath: .init(segments: ["input-\(index)"])))
        }
        let request = try STARequest(runID: "connectivity", design: references[0], topDesignName: "top",
            libraries: [.init(artifact: references[1], cornerIDs: ["typical"])], constraints: references[2],
            requestedModeIDs: modes, requestedCornerIDs: ["typical"], pdkManifest: references[3], processID: "test", pdkVersion: "1", analysisKinds: kinds, maxPaths: maximumPaths, variation: variation)
        let reader = InMemoryTimingArtifactReader(artifacts: Dictionary(uniqueKeysWithValues: zip(references.map(\.id), contents)))
        let engine = NativeSTAEngine(reader: reader)
        if let limits {
            let prepared = try await engine.prepare(request, resources: .init(reader: reader,
                sourceLimits: try .init(maximumNestingDepth: 64), sourceResources: STALibertyResources(), limits: limits))
            return try await engine.execute(prepared)
        }
        return try await engine.execute(request)
    }
    @Test func aliasedAndConstantOutputsAreConstrainedWithoutInventedTransitions() async throws {
        let design = Data("""
        {"schemaVersion":2,"topDesignName":"top",
         "ports":[{"name":"a","direction":"input","net":"source"},
                  {"name":"y","direction":"output","net":"source"},
                  {"name":"z","direction":"output","net":"tie"}],
         "instances":[],"nets":[{"name":"source","capacitance":0},
                                  {"name":"tie","capacitance":0,"constant":"one"}]}
        """.utf8)
        let result = try await execute(design, constraints: """
        create_clock -name clk -period 10ns [get_ports a]
        set_input_delay 1ns -clock clk [get_ports a]
        set_output_delay 2ns -clock clk [get_ports y]
        set_output_delay -max 2ns -clock clk [get_ports z]
        """)
        #expect(result.status == .completed, "\(result.diagnostics)")
        #expect(abs(try #require(result.payload.worstSetupSlack) - 7e-9) < 1e-20)
        #expect(result.payload.endpoints.first { $0.endpoint == "z" }?.setupSlack == nil)
        #expect(!result.payload.criticalPaths.contains { $0.endpoint == "z" })
        #expect(result.payload.endpoints.first { $0.endpoint == "z" }?.staticValue == .one)
        #expect(result.payload.endpoints.first { $0.endpoint == "z" }?.staticChecks == [.setup])
        #expect(result.payload.criticalPaths.first?.startpoint == "a")
        #expect(try JSONDecoder().decode(STAPayload.self, from: JSONEncoder().encode(result.payload)) == result.payload)
    }

    @Test func outputAliasesKeepIndependentRequirements() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "a", direction: .input, net: "n0"),
            .init(name: "y", direction: .output, net: "n1"), .init(name: "z", direction: .output, net: "n1")],
            instances: [.init(name: "U", cell: "INV", connections: ["A": "n0", "Y": "n1"])],
            nets: [.init(name: "n0"), .init(name: "n1")])
        let result = try await execute(JSONEncoder().encode(design), constraints: """
        create_clock -name clk -period 10ns [get_ports a]
        set_input_delay 1ns -clock clk [get_ports a]
        set_output_delay 2ns -clock clk [get_ports y]
        set_output_delay 4ns -clock clk [get_ports z]
        """)
        #expect(result.status == .completed)
        #expect(abs(try #require(result.payload.endpoints.first { $0.endpoint == "y" }?.setupSlack) - 6e-9) < 1e-20)
        #expect(abs(try #require(result.payload.endpoints.first { $0.endpoint == "z" }?.setupSlack) - 4e-9) < 1e-20)
        #expect(result.payload.criticalPaths.allSatisfy { $0.stages.count == 1 && $0.startpoint == "a" })
    }
    @Test func aliasPathExceptionsApplyIndependentNumericChecks() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "a", direction: .input),
            .init(name: "y", direction: .output, net: "a"), .init(name: "z", direction: .output, net: "a")], instances: [])
        for (exception, setup, hold) in [("set_multicycle_path 2 -setup -from [get_ports a] -to [get_ports z]", 15e-9, -5e-9),
                                         ("set_max_delay 5ns -from [get_ports a] -to [get_ports z]", 0.0, 5e-9),
                                         ("set_min_delay 2ns -from [get_ports a] -to [get_ports z]", 5e-9, 3e-9)] {
            let result = try await execute(JSONEncoder().encode(design), constraints: """
            create_clock -name clk -period 10ns [get_ports a]
            set_input_delay 1ns -clock clk [get_ports a]
            set_output_delay 2ns -clock clk [get_ports y]
            set_output_delay 4ns -clock clk [get_ports z]
            \(exception)
            """)
            #expect(result.status == .completed, "\(result.diagnostics)")
            let z = try #require(result.payload.endpoints.first { $0.endpoint == "z" })
            #expect(abs(try #require(z.setupSlack) - setup) < 1e-20)
            #expect(abs(try #require(z.holdSlack) - hold) < 1e-20)
            #expect(abs(try #require(result.payload.endpoints.first { $0.endpoint == "y" }?.setupSlack) - 7e-9) < 1e-20)
        }
    }
    @Test func staticSequentialDataAndAliasedClockDoNotFabricateSetupOrHold() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "clk", direction: .input, net: "clock"),
            .init(name: "q", direction: .output)], instances: [.init(name: "FF", cell: "DFF",
                connections: ["D": "tie", "CLK": "clock", "Q": "q"])],
            nets: [.init(name: "clock"), .init(name: "tie", constant: .zero)])
        let result = try await execute(JSONEncoder().encode(design), constraints: """
        create_clock -name clk -period 10ns [get_ports clk]
        set_output_delay -max 2ns -clock clk [get_ports q]
        """)
        #expect(result.status == .completed, "\(result.diagnostics)")
        let endpoint = try #require(result.payload.endpoints.first { $0.endpoint == "FF/D" })
        #expect(endpoint.staticValue == .zero && endpoint.staticChecks == [.setup, .hold])
        #expect(endpoint.setupSlack == nil && endpoint.holdSlack == nil && endpoint.dataArrival == nil)
        #expect(result.payload.worstHoldSlack == nil)
        #expect(abs(try #require(result.payload.worstSetupSlack) - 7.5e-9) < 1e-20)
        let unsupported = try await execute(JSONEncoder().encode(design),
            constraints: "create_clock -name clk -period 10ns [get_ports clk]", kinds: [.pulseWidth])
        #expect(unsupported.status == .blocked)
    }
    @Test func staticAndUnconstrainedOutputsRemainDistinct() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [.init(name: "a", direction: .input),
            .init(name: "y", direction: .output, net: "tie"), .init(name: "z", direction: .output, net: "a")],
            instances: [], nets: [.init(name: "tie", constant: .zero)])
        let result = try await execute(JSONEncoder().encode(design), constraints: """
        create_clock -name clk -period 10ns [get_ports a]
        set_output_delay 2ns -clock clk [get_ports y]
        """)
        #expect(result.status == .completed)
        #expect(result.payload.worstSetupSlack == nil)
        #expect(result.payload.endpoints.count == 1 && result.payload.endpoints[0].staticValue == .zero)
        #expect(result.payload.unconstrainedEndpoints.map(\.endpoint) == ["z"])
    }
    @Test func canonicalConnectivityRejectsConflictingDriversClocksAndAbsentNets() async throws {
        let base = TimingDesign(topDesignName: "top", ports: [.init(name: "a", direction: .input),
            .init(name: "y", direction: .output, net: "a")], instances: [])
        for mutation in 0..<5 {
            var design = base
            var constraints = "create_clock -name clk -period 10ns [get_ports a]\nset_output_delay 2ns -clock clk [get_ports y]"
            if mutation == 0 { design.ports.append(.init(name: "b", direction: .input, net: "a")) }
            if mutation == 1 { design.nets = [.init(name: "a", constant: .one)] }
            if mutation == 2 { design.ports[1].net = "absent" }
            if mutation == 3 { design.instances = [.init(name: "U", cell: "INV", connections: ["A": "a", "Y": "a"])] }
            if mutation == 4 { constraints += "\ncreate_clock -name other -period 20ns [get_ports y]" }
            let result = try await execute(JSONEncoder().encode(design), constraints: constraints)
            #expect(result.status == .blocked)
            #expect(result.artifactBindings.isEmpty)
        }
    }
    @Test func legacySchemaImportCannotCarryNewSemantics() throws {
        let legacy = Data("{\"schemaVersion\":1,\"topDesignName\":\"top\",\"ports\":[{\"name\":\"a\",\"direction\":\"input\"}],\"instances\":[],\"nets\":[]}".utf8)
        let imported = try TimingDesignParser().parse(legacy, topDesignName: "top")
        #expect(imported.schemaVersion == 2 && imported.ports[0].netName == "a")
        let roundTrip = try JSONDecoder().decode(TimingDesign.self, from: JSONEncoder().encode(imported))
        #expect(roundTrip == imported)
        var added = imported; added.nets = [.init(name: "tie", constant: .one)]
        #expect(throws: TimingError.self) {
            _ = try TimingReferenceAnalyzer().analyze(design: added, library: .init(name: "L"), constraints: .init(modeID: "functional"))
        }
        let contradictory = Data(String(decoding: legacy, as: UTF8.self).replacingOccurrences(of: "\"direction\":\"input\"", with: "\"direction\":\"input\",\"net\":\"other\"").utf8)
        #expect(throws: TimingError.self) { _ = try TimingDesignParser().parse(contradictory, topDesignName: "top") }
    }
}

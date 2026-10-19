import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import Foundation
import LogicIR
import PDKCore
import STAEngine
import SignalIntegrityEngine
import Testing
import TimingCore
import TimingEngine

@Suite("Native STA")
struct NativeEngineTests {
    @Test("runs canonical MMMC setup and hold")
    func runsSTA() async throws {
        let design = TimingDesign(
            topDesignName: "top",
            ports: [
                TimingDesign.Port(name: "clk", direction: .input),
                TimingDesign.Port(name: "in", direction: .input),
                TimingDesign.Port(name: "q", direction: .output)
            ],
            instances: [
                TimingDesign.Instance(name: "U1", cell: "INV", connections: ["A": "in", "Y": "n1"]),
                TimingDesign.Instance(name: "FF1", cell: "DFF", connections: ["D": "n1", "CLK": "clk", "Q": "q"])
            ],
            nets: [TimingDesign.Net(name: "n1")]
        )
        let designData = try JSONEncoder().encode(design)
        let libraryData = Data(TimingCoreTests.liberty.utf8)
        let constraintsData = Data("""
        create_clock -name clk -period 10ns [get_ports clk]
        set_input_delay 1ns -clock clk [get_ports in]
        set_output_delay 2ns -clock clk [get_ports q]
        """.utf8)
        let pdkData = try STATestProcessFactory.data(library: libraryData)
        let references = [
            try artifact(path: "design.json", data: designData, kind: .netlist, format: .json),
            try artifact(path: "library.lib", data: libraryData, kind: .timingLibrary, format: .liberty),
            try artifact(path: "constraints.sdc", data: constraintsData, kind: .constraints, format: .sdc),
            try artifact(path: "pdk.json", data: pdkData, kind: .technology, format: .json)
        ]
        let request = try STARequest(
            runID: "run-001",
            design: references[0],
            topDesignName: "top",
            libraries: [TimingLibraryReference(artifact: references[1], cornerIDs: ["typical"])] ,
            constraints: references[2],
            requestedModeIDs: ["functional"],
            requestedCornerIDs: ["typical"],
            pdkManifest: references[3],
            processID: "test",
            pdkVersion: "1"
        )
        let reader = InMemoryTimingArtifactReader(artifacts: [
            references[0].id: designData,
            references[1].id: libraryData,
            references[2].id: constraintsData,
            references[3].id: pdkData
        ])
        let result = try await NativeSTAEngine(reader: reader).execute(request)
                #expect(result.status == .completed)
        #expect(result.payload.analyzedModes == ["functional"])
        #expect(result.payload.analyzedCorners == ["typical"])
        #expect(result.payload.worstSetupSlack != nil)
        #expect(result.payload.worstHoldSlack != nil)
        #expect(result.diagnostics.contains { $0.code.rawValue == "timing.sta.post_layout_inputs_missing" })
    }

    @Test("blocks a post-layout request without required timing inputs")
    func blocksMissingParasitics() async throws {
        let reference = try artifact(path: "missing.json", data: Data("{}".utf8), kind: .netlist, format: .json)
        let request = try STARequest(
            runID: "blocked-run",
            design: reference,
            topDesignName: "top",
            libraries: [],
            constraints: reference,
            pdkManifest: reference,
            processID: "test",
            pdkVersion: "1",
            requiresPostLayoutInputs: true
        )
        let result = try await NativeSTAEngine(reader: InMemoryTimingArtifactReader(artifacts: [:])).execute(request)
        #expect(result.status == .blocked)
        #expect(result.diagnostics.first?.code.rawValue == "timing.sta.missing_artifact")
    }

    @Test("native STA and SI consume reduced operators and publish explicit dynamic loss")
    func consumesParasiticReduction() async throws {
        let design = TimingDesign(topDesignName: "top", ports: [
            .init(name: "clk", direction: .input), .init(name: "in", direction: .input),
            .init(name: "external", direction: .input), .init(name: "out", direction: .output)
        ], instances: [.init(name: "U1", cell: "INV", connections: ["A": "in", "Y": "out"])])
        let designData = try JSONEncoder().encode(design)
        let library = TimingCoreTests.liberty.replacingOccurrences(of:
            "index_2 (\"0.0\"); values (\"1.0\")", with: "index_2 (\"0.0, 4.0\"); values (\"1.0, 5.0\")")
        let libraryData = Data(library.utf8)
        let constraintsData = Data("create_clock -name clk -period 10ns [get_ports clk]\nset_output_delay 0ns -clock clk [get_ports out]\n".utf8)
        let pdkData = try STATestProcessFactory.data(library: libraryData)
        let parasiticData = Data("*C_UNIT 1 PF\n*D_NET external 999\n*CAP\n1 external:1 3\n2 external:1 external:2 7\n3 external:1 out 2\n*RES\n1 external:1 external:2 100\n*END\n".utf8)
        let references = [
            try artifact(path: "design.json", data: designData, kind: .netlist, format: .json),
            try artifact(path: "library.lib", data: libraryData, kind: .timingLibrary, format: .liberty),
            try artifact(path: "constraints.sdc", data: constraintsData, kind: .constraints, format: .sdc),
            try artifact(path: "pdk.json", data: pdkData, kind: .technology, format: .json),
            try artifact(path: "parasitics.spef", data: parasiticData, kind: .parasitics, format: .spef)
        ]
        let reader = InMemoryTimingArtifactReader(artifacts: Dictionary(uniqueKeysWithValues:
            zip(references, [designData, libraryData, constraintsData, pdkData, parasiticData]).map { ($0.0.id, $0.1) }))
        let staRequest = try STARequest(runID: "reduction-sta", design: references[0], topDesignName: "top",
            libraries: [.init(artifact: references[1], cornerIDs: ["typical"])], constraints: references[2],
            requestedModeIDs: ["functional"], requestedCornerIDs: ["typical"], pdkManifest: references[3],
            processID: "test", pdkVersion: "1", parasitics: references[4])
        let sta = try await NativeSTAEngine(reader: reader).execute(staRequest)
        #expect(sta.status == .completed)
        let slack = try #require(sta.payload.worstSetupSlack)
        #expect(abs(slack - 7e-9) < 1e-20)
        #expect(sta.payload.parasiticReduction?.effectiveLoads["out"] == 2e-12)
        #expect(abs((sta.payload.parasiticReduction?.effectiveLoads["external"] ?? 0) - 5e-12) < 1e-25)
        #expect(sta.payload.parasiticReduction?.collapsedIntraNetCapacitances.count == 1)
        #expect(sta.diagnostics.contains { $0.code.rawValue == "timing.sta.intra_net_dynamic_capacitance_not_evaluated" })
        #expect(try JSONDecoder().decode(STAExecutionResult.self, from: JSONEncoder().encode(sta)).payload.parasiticReduction == sta.payload.parasiticReduction)
        let siRequest = try SignalIntegrityRequest(runID: "reduction-si", design: references[0], topDesignName: "top",
            constraints: references[2], pdkManifest: references[3], processID: "test", pdkVersion: "1", parasitics: references[4])
        let si = try await NativeSignalIntegrityEngine(reader: reader).execute(siRequest)
        #expect(si.status == .completed)
        #expect(si.payload.analyzedNets.count == 1)
        let summary = try #require(si.payload.analyzedNets.first)
        #expect(abs(summary.noiseRatio - 0.4) < 1e-15)
        #expect(abs(summary.deltaDelay - 138e-12) < 1e-25)
        #expect(si.payload.parasiticReduction == sta.payload.parasiticReduction)
        #expect(si.diagnostics.contains { $0.code.rawValue == "timing.signal_integrity.intra_net_dynamic_capacitance_not_evaluated" })
        #expect(try JSONDecoder().decode(SignalIntegrityExecutionResult.self, from: JSONEncoder().encode(si)).payload.parasiticReduction == si.payload.parasiticReduction)
    }

    @Test("Default Native STA seeds both global port edges and propagates internal slew")
    func inputTransitionSeedsAndPropagatesSlew() async throws {
        let libraryText = """
        library (slew_test) {
          time_unit : "1ns";
          capacitive_load_unit (1, pf);
          cell (INV) {
            pin (A) { direction : input; capacitance : 0; }
            pin (Y) { direction : output; function : "!A";
              timing () { related_pin : "A"; timing_sense : negative_unate;
                cell_rise (t) { index_1 ("0.1, 0.9"); index_2 ("0"); values ("1", "5"); }
                cell_fall (t) { index_1 ("0.1, 0.9"); index_2 ("0"); values ("0.5", "4.5"); }
                rise_transition (t) { index_1 ("0.1, 0.9"); index_2 ("0"); values ("0.2", "0.6"); }
                fall_transition (t) { index_1 ("0.1, 0.9"); index_2 ("0"); values ("0.1", "0.5"); }
              }
            }
          }
          cell (BUF) {
            pin (A) { direction : input; capacitance : 0; }
            pin (Y) { direction : output; function : "A";
              timing () { related_pin : "A"; timing_sense : positive_unate;
                cell_rise (t) { index_1 ("0.1, 0.9"); index_2 ("0"); values ("1", "5"); }
                cell_fall (t) { index_1 ("0.1, 0.9"); index_2 ("0"); values ("0.5", "4.5"); }
                rise_transition (t) { index_1 ("0.1, 0.9"); index_2 ("0"); values ("0.2", "0.6"); }
                fall_transition (t) { index_1 ("0.1, 0.9"); index_2 ("0"); values ("0.1", "0.5"); }
              }
            }
          }
        }
        """
        let design = TimingDesign(topDesignName: "top", ports: [
            .init(name: "clk", direction: .input), .init(name: "in", direction: .input),
            .init(name: "io", direction: .bidirectional), .init(name: "out", direction: .output),
            .init(name: "io_inv", direction: .output), .init(name: "io_buf", direction: .output)
        ], instances: [
            .init(name: "U1", cell: "INV", connections: ["A": "in", "Y": "mid"]),
            .init(name: "U2", cell: "INV", connections: ["A": "mid", "Y": "out"]),
            .init(name: "U3", cell: "INV", connections: ["A": "io", "Y": "io_inv"]),
            .init(name: "U4", cell: "BUF", connections: ["A": "io", "Y": "io_buf"])
        ], nets: [.init(name: "mid")])
        let baseSDC = "create_clock -name clk -period 10ns [get_ports clk]\n"
            + "set_output_delay 0ns -clock clk [get_ports out]\n"
            + "set_output_delay 0ns -clock clk [get_ports io_inv]\n"
            + "set_output_delay 0ns -clock clk [get_ports io_buf]\n"
        let designData = try JSONEncoder().encode(design)
        let libraryData = Data(libraryText.utf8)
        let pdkData = try STATestProcessFactory.data(library: libraryData)
        func execute(_ sdc: String, runID: String) async throws -> STAExecutionResult {
            let constraintsData = Data(sdc.utf8)
            let refs = [
                try artifact(path: "design.json", data: designData, kind: .netlist, format: .json),
                try artifact(path: "library.lib", data: libraryData, kind: .timingLibrary, format: .liberty),
                try artifact(path: "constraints.sdc", data: constraintsData, kind: .constraints, format: .sdc),
                try artifact(path: "pdk.json", data: pdkData, kind: .technology, format: .json)
            ]
            let request = try STARequest(runID: runID, design: refs[0], topDesignName: "top",
                libraries: [.init(artifact: refs[1], cornerIDs: ["typical"])], constraints: refs[2],
                requestedCornerIDs: ["typical"], pdkManifest: refs[3], processID: "test", pdkVersion: "1")
            let reader = InMemoryTimingArtifactReader(artifacts: Dictionary(uniqueKeysWithValues:
                zip(refs, [designData, libraryData, constraintsData, pdkData]).map { ($0.0.id, $0.1) }))
            return try await NativeSTAEngine(reader: reader).execute(request)
        }
        let baseline = try await execute(baseSDC, runID: "default-slew")
        let configured = try await execute(baseSDC + "set_input_transition 0.45 [all_inputs]\n", runID: "global-slew")
        #expect(baseline.status == .completed)
        #expect(configured.status == .completed)
        let defaultPath = try #require(baseline.payload.criticalPaths.first { $0.endpoint == "out" && $0.analysisKind == .setup })
        let path = try #require(configured.payload.criticalPaths.first { $0.endpoint == "out" && $0.analysisKind == .setup })
        #expect(abs(defaultPath.arrival - 2e-9) < 1e-20)
        #expect(abs(path.arrival - 4.625e-9) < 1e-20)
        #expect(path.stages.map(\.instance) == ["U1", "U2"])
        #expect(abs(path.stages[0].outputSlew - 0.375e-9) < 1e-20)
        #expect(abs(path.stages[1].outputSlew - 0.2375e-9) < 1e-20)
        #expect(abs(path.stages[1].delay - 1.875e-9) < 1e-20)
        let inverse = try #require(configured.payload.criticalPaths.first { $0.endpoint == "io_inv" && $0.analysisKind == .setup })
        let buffer = try #require(configured.payload.criticalPaths.first { $0.endpoint == "io_buf" && $0.analysisKind == .setup })
        #expect(inverse.stages.first?.inputEdge == .fall)
        #expect(buffer.stages.first?.inputEdge == .rise)
        #expect(abs(inverse.arrival - 2.75e-9) < 1e-20)
        #expect(abs(buffer.arrival - 2.75e-9) < 1e-20)
        #expect(abs((inverse.stages.first?.outputSlew ?? 0) - 0.375e-9) < 1e-20)
        #expect(abs((buffer.stages.first?.outputSlew ?? 0) - 0.375e-9) < 1e-20)
        let single = TimingDesign(topDesignName: "single", ports: [
            .init(name: "clk", direction: .input), .init(name: "io", direction: .bidirectional),
            .init(name: "io_inv", direction: .output)
        ], instances: [.init(name: "U3", cell: "INV", connections: ["A": "io", "Y": "io_inv"])])
        let constraints = try SDCParser().parse(Data(("create_clock -name clk -period 10ns [get_ports clk]\n"
            + "set_output_delay 0ns -clock clk [get_ports io_inv]\nset_input_transition 0.45 [all_inputs]\n").utf8))
        let oracle = try TimingReferenceAnalyzer().analyze(design: single,
            library: LibertyParser().parse(libraryData), constraints: constraints)
        #expect(abs((oracle.worstSetupSlack ?? 0) - inverse.slack) < 1e-20)
    }

    private func artifact(
        path: String,
        data: Data,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> TimingArtifactBinding {
        let descriptor = ArtifactDescriptor(role: .input, kind: kind, format: format)
        let reference = try ArtifactReference(
            digest: SHA256ContentDigester().digest(data: data, using: .sha256),
            byteCount: UInt64(data.count),
            descriptor: descriptor
        )
        return try TimingArtifactBinding(
            reference: reference,
            availability: .local(
                artifactID: reference.id,
                rootID: ArtifactRootID(rawValue: TimingArtifactBinding.workspaceRootIdentifier),
                relativePath: ArtifactRelativePath(
                    segments: path.split(separator: "/").map(String.init)
                )
            )
        )
    }
}

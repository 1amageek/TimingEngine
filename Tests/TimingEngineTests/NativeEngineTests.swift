import CircuiteFoundation
import Foundation
import LogicIR
import PDKCore
import STAEngine
import Testing
import TimingCore

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
        let pdkData = Data("{}".utf8)
        let references = [
            try artifact(path: "design.json", data: designData, kind: .netlist, format: .json),
            try artifact(path: "library.lib", data: libraryData, kind: .timingLibrary, format: .liberty),
            try artifact(path: "constraints.sdc", data: constraintsData, kind: .constraints, format: .sdc),
            try artifact(path: "pdk.json", data: pdkData, kind: .technology, format: .json)
        ]
        let request = STARequest(
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
            "design.json": designData,
            "library.lib": libraryData,
            "constraints.sdc": constraintsData,
            "pdk.json": pdkData
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
        let request = STARequest(
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

    private func artifact(
        path: String,
        data: Data,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> ArtifactReference {
        ArtifactReference(
            locator: ArtifactLocator(
                location: try ArtifactLocation(workspaceRelativePath: path),
                role: .input,
                kind: kind,
                format: format
            ),
            digest: try SHA256ContentDigester().digest(data: data, using: .sha256),
            byteCount: UInt64(data.count)
        )
    }
}

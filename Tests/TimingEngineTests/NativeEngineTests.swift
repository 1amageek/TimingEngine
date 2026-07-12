import Foundation
import LogicIR
import PDKCore
import Testing
@testable import STAEngine
@testable import TimingCore
import XcircuitePackage

@Suite("Native STA")
struct NativeEngineTests {
    @Test("runs MMMC setup and hold with deterministic JSON artifacts")
    func runsSTA() async throws {
        let design = TimingDesign(
            topDesignName: "top",
            ports: [
                TimingDesign.Port(name: "clk", direction: .input),
                TimingDesign.Port(name: "in", direction: .input),
                TimingDesign.Port(name: "q", direction: .output),
            ],
            instances: [
                TimingDesign.Instance(name: "U1", cell: "INV", connections: ["A": "in", "Y": "n1"]),
                TimingDesign.Instance(name: "FF1", cell: "DFF", connections: ["D": "n1", "CLK": "clk", "Q": "q"]),
            ],
            nets: [TimingDesign.Net(name: "n1")]
        )
        let libraryData = Data(TimingCoreTests.liberty.utf8)
        let designData = try JSONEncoder().encode(design)
        let constraintsData = Data("""
        create_clock -name clk -period 10ns [get_ports clk]
        set_input_delay 1ns -clock clk [get_ports in]
        set_output_delay 2ns -clock clk [get_ports q]
        """.utf8)
        let pdkData = Data("{}".utf8)
        let reader = InMemoryTimingArtifactReader(artifacts: [
            "design.json": designData,
            "library.lib": libraryData,
            "constraints.sdc": constraintsData,
            "pdk.json": pdkData,
        ])
        let designReference = XcircuiteFileReference(path: "design.json", kind: .netlist, format: .json)
        let libraryReference = XcircuiteFileReference(path: "library.lib", kind: .timingLibrary, format: .liberty)
        let constraintReference = XcircuiteFileReference(path: "constraints.sdc", kind: .constraint, format: .sdc)
        let pdkReference = PDKReference(
            manifest: XcircuiteFileReference(path: "pdk.json", kind: .technology, format: .json),
            processID: "test",
            version: "1",
            digest: "test"
        )
        let request = STARequest(
            runID: "run-001",
            inputs: [designReference, libraryReference, constraintReference, pdkReference.manifest],
            design: LogicDesignReference(artifact: designReference, topDesignName: "top", designDigest: "design"),
            libraries: [TimingLibraryReference(artifact: libraryReference, cornerIDs: ["typical"])],
            constraints: TimingConstraintReference(artifact: constraintReference, modeIDs: ["functional"]),
            pdk: pdkReference,
            requestedModeIDs: ["functional"],
            requestedCornerIDs: ["typical"]
        )
        let envelope = try await NativeSTAEngine(reader: reader).execute(request)
        #expect(envelope.status == .completed)
        #expect(envelope.payload.analyzedModes == ["functional"])
        #expect(envelope.payload.analyzedCorners == ["typical"])
        #expect(envelope.payload.worstSetupSlack != nil)
        #expect(envelope.payload.worstHoldSlack != nil)
        #expect(envelope.payload.signoffEligible == false)
        #expect(envelope.diagnostics.contains { $0.code == "IDEAL_INTERCONNECT_NOT_SIGNOFF_ELIGIBLE" })
        #expect(envelope.payload.criticalPaths.contains { $0.endpoint == "q" && $0.required == 8e-9 })
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(XcircuiteEngineResultEnvelope<STAPayload>.self, from: encoded)
        #expect(decoded.runID == envelope.runID)
        #expect(decoded.payload.criticalPaths == envelope.payload.criticalPaths)
    }

    @Test("blocks a signoff request without parasitics")
    func blocksMissingParasitics() async throws {
        let request = STARequest(
            runID: "blocked-run",
            inputs: [],
            design: LogicDesignReference(
                artifact: XcircuiteFileReference(path: "missing", kind: .netlist, format: .json),
                topDesignName: "top",
                designDigest: "unknown"
            ),
            libraries: [],
            constraints: TimingConstraintReference(
                artifact: XcircuiteFileReference(path: "missing", kind: .constraint, format: .sdc),
                modeIDs: []
            ),
            pdk: PDKReference(
                manifest: XcircuiteFileReference(path: "missing", kind: .technology, format: .json),
                processID: "test",
                version: "1",
                digest: "unknown"
            ),
            requiresSignoff: true
        )
        let envelope = try await NativeSTAEngine(reader: InMemoryTimingArtifactReader(artifacts: [:])).execute(request)
        #expect(envelope.status == .blocked)
        #expect(envelope.diagnostics.first?.code == "STA_MISSING_ARTIFACT")
    }

    @Test("blocks signoff when design provenance does not match the input digest")
    func blocksMismatchedDesignProvenance() async throws {
        let design = TimingDesign(
            topDesignName: "top",
            ports: [TimingDesign.Port(name: "in", direction: .input)],
            instances: [],
            nets: []
        )
        let designData = try JSONEncoder().encode(design)
        let reader = InMemoryTimingArtifactReader(artifacts: [
            "design.json": designData,
            "library.lib": Data(TimingCoreTests.liberty.utf8),
            "constraints.sdc": Data("create_clock -name clk -period 10ns [get_ports in]".utf8),
            "pdk.json": Data("{}".utf8),
            "parasitics.spef": Data("""
            *SPEF "IEEE 1481-1998"
            *CAP_UNIT 1 PF
            *RES_UNIT 1 OHM
            *D_NET n1 0.03
            *CAP
            1 n1 0.02
            2 n1 n2 0.01
            *RES
            1 n1 n2 10
            *END
            """.utf8)
        ])
        let designReference = LogicDesignReference(
            artifact: XcircuiteFileReference(path: "design.json", kind: .netlist, format: .json),
            topDesignName: "top",
            designDigest: "current",
            provenance: LogicDesignProvenance(
                sourceDesignDigest: "source",
                inputDesignDigest: "different",
                transformationID: "mapped",
                producerID: "producer",
                producerVersion: "1.0.0"
            )
        )
        let request = STARequest(
            runID: "provenance-run",
            inputs: [],
            design: designReference,
            libraries: [TimingLibraryReference(
                artifact: XcircuiteFileReference(path: "library.lib", kind: .timingLibrary, format: .liberty),
                cornerIDs: ["typical"]
            )],
            constraints: TimingConstraintReference(
                artifact: XcircuiteFileReference(path: "constraints.sdc", kind: .constraint, format: .sdc),
                modeIDs: ["default"]
            ),
            pdk: PDKReference(
                manifest: XcircuiteFileReference(path: "pdk.json", kind: .technology, format: .json),
                processID: "test",
                version: "1",
                digest: "pdk"
            ),
            parasitics: XcircuiteFileReference(path: "parasitics.spef", kind: .parasitic, format: .spef),
            requiresSignoff: true
        )

        let envelope = try await NativeSTAEngine(reader: reader).execute(request)

        #expect(envelope.status == .blocked)
        #expect(envelope.diagnostics.contains { $0.code == "DESIGN_PROVENANCE_INPUT_DIGEST_MISMATCH" })
    }
}

import CircuiteFoundation
import Foundation
import PDKCore
import SignalIntegrityEngine
@testable import STAEngine
import Testing
import TimingCore
import DesignFlowKernel

@Suite("CircuiteFoundation timing boundary")
struct FoundationBoundaryTests {
    @Test("STA Foundation engine emits evidence and structured diagnostics")
    func staFoundationEngineEmitsEvidence() async throws {
        try await withTemporaryDirectory { root in
            let design = TimingDesign(
                topDesignName: "top",
                ports: [
                    TimingDesign.Port(name: "clk", direction: .input),
                    TimingDesign.Port(name: "in", direction: .input),
                    TimingDesign.Port(name: "q", direction: .output),
                ],
                instances: [
                    TimingDesign.Instance(
                        name: "U1",
                        cell: "INV",
                        connections: ["A": "in", "Y": "n1"]
                    ),
                    TimingDesign.Instance(
                        name: "FF1",
                        cell: "DFF",
                        connections: ["D": "n1", "CLK": "clk", "Q": "q"]
                    ),
                ],
                nets: [TimingDesign.Net(name: "n1")]
            )
            try write(
                try JSONEncoder().encode(design),
                to: root.appending(path: "design.json")
            )
            try write(
                Data(TimingCoreTests.liberty.utf8),
                to: root.appending(path: "library.lib")
            )
            try write(
                Data("""
                create_clock -name clk -period 10ns [get_ports clk]
                set_input_delay 1ns -clock clk [get_ports in]
                set_output_delay 2ns -clock clk [get_ports q]
                """.utf8),
                to: root.appending(path: "constraints.sdc")
            )
            try write(Data("{}".utf8), to: root.appending(path: "pdk.json"))

            let request = STAFoundationRequest(
                runID: "foundation-sta",
                design: try reference(
                    root: root,
                    path: "design.json",
                    kind: .netlist,
                    format: .json
                ),
                topDesignName: "top",
                libraries: [STAFoundationLibraryReference(
                    artifact: try reference(
                        root: root,
                        path: "library.lib",
                        kind: try ArtifactKind(rawValue: "timing.library"),
                        format: .liberty
                    ),
                    cornerIDs: ["typical"]
                )],
                constraints: try reference(
                    root: root,
                    path: "constraints.sdc",
                    kind: .constraints,
                    format: try ArtifactFormat(rawValue: "sdc")
                ),
                requestedModeIDs: ["functional"],
                requestedCornerIDs: ["typical"],
                pdkManifest: try reference(
                    root: root,
                    path: "pdk.json",
                    kind: .technology,
                    format: .json
                ),
                processID: "test",
                pdkVersion: "1"
            )

            let engine: any STAFoundationEngine = NativeSTAEngine(
                workspaceRoot: root
            )
            let result = try await engine.execute(request)

            #expect(result.status == .completed)
            #expect(result.payload.analyzedModes == ["functional"])
            #expect(result.payload.analyzedCorners == ["typical"])
            #expect(result.evidence.provenance.inputs == request.inputs)
            #expect(result.evidence.artifacts == result.artifacts)
            #expect(result.diagnostics.contains {
                $0.code.rawValue == "timing.sta.ideal_interconnect_not_signoff_eligible"
            })
            #expect(result.diagnostics.contains {
                $0.suggestedActions.contains { $0.code == "provide_spef_artifact" }
            })

            let encoded = try JSONEncoder().encode(result)
            let decoded = try JSONDecoder().decode(STAExecutionResult.self, from: encoded)
            #expect(decoded == result)
        }
    }

    @Test("STA Foundation boundary promotes a persisted report artifact")
    func staFoundationEnginePromotesOutputArtifact() async throws {
        try await withTemporaryDirectory { root in
            let design = TimingDesign(
                topDesignName: "top",
                ports: [
                    TimingDesign.Port(name: "clk", direction: .input),
                    TimingDesign.Port(name: "d", direction: .input),
                    TimingDesign.Port(name: "q", direction: .output),
                ],
                instances: [TimingDesign.Instance(
                    name: "FF1",
                    cell: "DFF",
                    connections: ["D": "d", "CLK": "clk", "Q": "q"]
                )],
                nets: []
            )
            try write(
                try JSONEncoder().encode(design),
                to: root.appending(path: "design.json")
            )
            try write(Data(TimingCoreTests.liberty.utf8), to: root.appending(path: "library.lib"))
            try write(Data("create_clock -name clk -period 10ns [get_ports clk]".utf8), to: root.appending(path: "constraints.sdc"))
            try write(Data("{}".utf8), to: root.appending(path: "pdk.json"))

            let request = STAFoundationRequest(
                runID: "foundation-sta-artifact",
                design: try reference(root: root, path: "design.json", kind: .netlist, format: .json),
                topDesignName: "top",
                libraries: [STAFoundationLibraryReference(
                    artifact: try reference(
                        root: root,
                        path: "library.lib",
                        kind: try ArtifactKind(rawValue: "timing.library"),
                        format: .liberty
                    )
                )],
                constraints: try reference(
                    root: root,
                    path: "constraints.sdc",
                    kind: .constraints,
                    format: try ArtifactFormat(rawValue: "sdc")
                ),
                pdkManifest: try reference(root: root, path: "pdk.json", kind: .technology, format: .json),
                processID: "test",
                pdkVersion: "1"
            )
            let store = FileSystemTimingArtifactStore(
                outputDirectory: root.appending(path: "artifacts", directoryHint: .isDirectory)
            )
            let engine = NativeSTAEngine(
                artifactStore: store,
                workspaceRoot: root
            )

            let result = try await engine.execute(request)

            let artifact = try #require(result.artifacts.first)
            #expect(artifact.locator.kind == .report)
            #expect(artifact.locator.format == .json)
            #expect(artifact.byteCount > 0)
            #expect(LocalArtifactVerifier().verify(artifact, relativeTo: root).isVerified)
        }
    }

    @Test("SI Foundation engine preserves net subjects in diagnostics")
    func signalIntegrityFoundationEnginePreservesNetSubjects() async throws {
        try await withTemporaryDirectory { root in
            try write(Data("{}".utf8), to: root.appending(path: "design.json"))
            try write(Data("create_clock -name clk -period 10ns [get_ports clk]".utf8), to: root.appending(path: "constraints.sdc"))
            try write(Data("{}".utf8), to: root.appending(path: "pdk.json"))
            try write(Data("""
            *SPEF "IEEE 1481-1998"
            *CAP_UNIT 1 PF
            *RES_UNIT 1 OHM
            *D_NET victim 0.03
            *CAP
            1 victim 0.01
            2 victim aggressor 0.02
            *RES
            1 victim aggressor 100
            *END
            """.utf8), to: root.appending(path: "parasitics.spef"))

            let request = SignalIntegrityFoundationRequest(
                runID: "foundation-si",
                design: try reference(root: root, path: "design.json", kind: .netlist, format: .json),
                topDesignName: "top",
                constraints: try reference(
                    root: root,
                    path: "constraints.sdc",
                    kind: .constraints,
                    format: try ArtifactFormat(rawValue: "sdc")
                ),
                requestedModeIDs: ["functional"],
                pdkManifest: try reference(root: root, path: "pdk.json", kind: .technology, format: .json),
                processID: "test",
                pdkVersion: "1",
                parasitics: try reference(root: root, path: "parasitics.spef", kind: .parasitics, format: .spef),
                maxDeltaDelay: 1e-12,
                maxNoiseRatio: 0.5
            )

            let engine: any SignalIntegrityFoundationEngine = NativeSignalIntegrityEngine(
                workspaceRoot: root
            )
            let result = try await engine.execute(request)

            #expect(result.status == .completed)
            #expect(result.payload.violationCount == 1)
            #expect(result.diagnostics.contains {
                $0.code.rawValue == "timing.signal_integrity.si_crosstalk_violation"
            })
            #expect(result.diagnostics.contains {
                $0.subject?.kind == .net && $0.subject?.identifier == "victim"
            })
        }
    }

    @Test("Foundation boundary rejects relative artifacts without a workspace root")
    func relativeArtifactRequiresWorkspaceRoot() async throws {
        try await withTemporaryDirectory { root in
            try write(Data("{}".utf8), to: root.appending(path: "design.json"))
            let design = try reference(root: root, path: "design.json", kind: .netlist, format: .json)
            let request = STAFoundationRequest(
                runID: "missing-root",
                design: design,
                topDesignName: "top",
                libraries: [],
                constraints: design,
                pdkManifest: design,
                processID: "test",
                pdkVersion: "1"
            )

            let result = try await NativeSTAEngine().execute(request)
            #expect(result.status == .blocked)
            #expect(result.diagnostics.first?.code.rawValue == "timing.sta.missing_artifact")
        }
    }

    @Test("Foundation promotion rejects a result from another run")
    func resultIdentityMustMatchRequest() throws {
        let digest = try ContentDigest(
            algorithm: .sha256,
            hexadecimalValue: String(repeating: "0", count: 64)
        )
        let locator = ArtifactLocator(
            location: try ArtifactLocation(workspaceRelativePath: "design.json"),
            role: .input,
            kind: .netlist,
            format: .json
        )
        let artifact = ArtifactReference(
            locator: locator,
            digest: digest,
            byteCount: 0
        )
        let request = STAFoundationRequest(
            runID: "expected-run",
            design: artifact,
            topDesignName: "top",
            libraries: [STAFoundationLibraryReference(artifact: artifact)],
            constraints: artifact,
            pdkManifest: artifact,
            processID: "test",
            pdkVersion: "1"
        )
        #expect(request.runID == "expected-run")
        #expect(request.inputs.count == 4)
    }
}

private func reference(
    root: URL,
    path: String,
    kind: ArtifactKind,
    format: ArtifactFormat
) throws -> ArtifactReference {
    let location = try ArtifactLocation(workspaceRelativePath: path)
    return try LocalArtifactReferencer().reference(
        ArtifactLocator(location: location, role: .input, kind: kind, format: format),
        relativeTo: root
    )
}

private func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
}

private func withTemporaryDirectory<Result>(
    _ operation: (URL) async throws -> Result
) async throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "timing-foundation-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    do {
        let result = try await operation(directory)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Temporary directory cleanup failed: \(error.localizedDescription)")
        }
        return result
    } catch {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Temporary directory cleanup failed: \(error.localizedDescription)")
        }
        throw error
    }
}

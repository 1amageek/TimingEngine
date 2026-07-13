import CircuiteFoundation
import Foundation
import SignalIntegrityEngine
import Testing
import TimingCore

@Suite("Native signal integrity")
struct SignalIntegrityTests {
    @Test("reports coupling violations from SPEF")
    func reportsCrosstalk() async throws {
        let designData = Data("{}".utf8)
        let constraintsData = Data("create_clock -name clk -period 10ns [get_ports clk]".utf8)
        let pdkData = Data("{}".utf8)
        let spefData = Data("""
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
        """.utf8)
        let design = try artifact(path: "design.json", data: designData, kind: .netlist, format: .json)
        let constraints = try artifact(path: "constraints.sdc", data: constraintsData, kind: .constraints, format: .sdc)
        let pdk = try artifact(path: "pdk.json", data: pdkData, kind: .technology, format: .json)
        let parasitics = try artifact(path: "parasitics.spef", data: spefData, kind: .parasitics, format: .spef)
        let reader = InMemoryTimingArtifactReader(artifacts: [
            "design.json": designData,
            "constraints.sdc": constraintsData,
            "pdk.json": pdkData,
            "parasitics.spef": spefData
        ])
        let request = SignalIntegrityFoundationRequest(
            runID: "si-run",
            design: design,
            topDesignName: "top",
            constraints: constraints,
            requestedModeIDs: ["functional"],
            pdkManifest: pdk,
            processID: "test",
            pdkVersion: "1",
            parasitics: parasitics,
            maxDeltaDelay: 1e-12,
            maxNoiseRatio: 0.5
        )
        let result = try await NativeSignalIntegrityEngine(reader: reader).execute(request)
        #expect(result.status == .completed)
        #expect(result.payload.violationCount == 1)
        #expect(result.payload.worstDeltaDelay != nil)
        #expect(result.diagnostics.contains { $0.code.rawValue == "timing.signal_integrity.si_crosstalk_violation" })
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

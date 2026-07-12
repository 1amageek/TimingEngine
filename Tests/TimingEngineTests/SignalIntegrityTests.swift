import Foundation
import LogicIR
import PDKCore
import SignalIntegrityEngine
import Testing
import TimingCore
import XcircuitePackage

@Suite("Native signal integrity")
struct SignalIntegrityTests {
    @Test("reports coupling violations from SPEF")
    func reportsCrosstalk() async throws {
        let spef = Data("""
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
        let reader = InMemoryTimingArtifactReader(artifacts: [
            "pdk.json": Data("{}".utf8),
            "constraints.sdc": Data("create_clock -name clk -period 10ns [get_ports clk]".utf8),
            "design.json": Data("{}".utf8),
            "parasitics.spef": spef,
        ])
        let request = SignalIntegrityRequest(
            runID: "si-run",
            inputs: [],
            design: LogicDesignReference(
                artifact: XcircuiteFileReference(path: "design.json", kind: .netlist, format: .json),
                topDesignName: "top",
                designDigest: "design"
            ),
            constraints: TimingConstraintReference(
                artifact: XcircuiteFileReference(path: "constraints.sdc", kind: .constraint, format: .sdc),
                modeIDs: ["functional"]
            ),
            pdk: PDKReference(
                manifest: XcircuiteFileReference(path: "pdk.json", kind: .technology, format: .json),
                processID: "test",
                version: "1",
                digest: "pdk"
            ),
            parasitics: XcircuiteFileReference(path: "parasitics.spef", kind: .parasitic, format: .spef),
            maxDeltaDelay: 1e-12,
            maxNoiseRatio: 0.5
        )
        let envelope = try await NativeSignalIntegrityEngine(reader: reader).execute(request)
        #expect(envelope.status == .completed)
        #expect(envelope.payload.violationCount == 1)
        #expect(envelope.payload.worstDeltaDelay != nil)
        #expect(envelope.diagnostics.first?.code == "SI_CROSSTALK_VIOLATION")
    }
}

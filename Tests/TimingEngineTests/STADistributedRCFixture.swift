import CircuiteFoundation
import Foundation
import STAEngine
import TimingCore

/// Exact same design/library/manifest bytes feed direct API and actual CLI execution.
struct STADistributedRCFixture {
    let request: STARequest
    let reader: InMemoryTimingArtifactReader
    static let spef = """
    *SPEF "IEEE 1481-1998"
    *C_UNIT 1 PF
    *R_UNIT 1 OHM
    *D_NET out 1
    *CONN
    *I U1:Y O
    *P out O
    *CAP
    1 out 1
    *RES
    1 U1:Y out 1000
    *END
    """
    static var options: STADistributedRCOptions {
        get throws { try .init(maximumTimeStep: 1e-11, stopTime: 2e-8, crossingTolerance: 1e-12,
            maximumRefinements: 10, maximumNodes: 16, maximumSteps: 1_000_000) }
    }
    init(spef: String = Self.spef, selected: STADistributedRCOptions? = nil, expected: ContentDigest? = nil,
         variation: STAVariation = .init(), failure: String? = nil) throws {
        let base = try STAProcessTestFixture(failure: failure)
        let value = base.request, data = Data(spef.utf8)
        let parasitics = try STAProcessTestFixture.binding(data, path: "network.spef", kind: .parasitics, format: .spef)
        request = try STARequest(runID: "distributed-rc-exact", design: value.design, topDesignName: value.topDesignName,
            libraries: value.libraries, constraints: value.constraints, requestedModeIDs: value.requestedModeIDs,
            requestedCornerIDs: value.requestedCornerIDs, pdkManifest: value.pdkManifest, processID: value.processID,
            pdkVersion: value.pdkVersion, parasitics: parasitics, requiresPostLayoutInputs: true, variation: variation,
            configurationDigest: expected, distributedRC: selected ?? Self.options)
        var artifacts = base.reader.artifacts; artifacts[parasitics.id] = data
        reader = .init(artifacts: artifacts)
    }
}

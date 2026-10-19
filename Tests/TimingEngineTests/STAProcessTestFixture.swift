import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import PDKCore
import STAEngine
import TimingCore

struct STAProcessTestFixture {
    let request: STARequest
    let reader: InMemoryTimingArtifactReader

    init(failure: String? = nil, selectedCorners: [String] = ["typical", "slow"]) throws {
        let root = try TimingTestResources.corpusRoot.appending(path: "fixtures/simple")
        let designData = try Data(contentsOf: root.appending(path: "design.json"))
        let constraintsData = try Data(contentsOf: root.appending(path: "constraints.sdc"))
        let typicalData = try Data(contentsOf: root.appending(path: "library.lib"))
        let slowData = Data(String(decoding: typicalData, as: UTF8.self)
            .replacingOccurrences(of: "values (\"1.0\")", with: "values (\"3.0\")").utf8)
        var manifest = try STATestProcessFactory.manifest(libraries: ["typical": typicalData, "slow": slowData])
        var requestedCorners = selectedCorners
        var suppliedCorners = ["typical"]
        var processID = "test"
        var version = "1"
        switch failure {
        case "process": processID = "other"
        case "version": version = "2"
        case "missing-selection": requestedCorners = []
        case "unknown-selection": requestedCorners = ["absent"]
        case "unknown-source-corner": suppliedCorners = ["absent"]
        case "missing-source-corner": suppliedCorners = []
        case "duplicate-source-corner": suppliedCorners = ["typical", "typical"]
        case "missing-digest": manifest.assets[1].sha256 = nil
        case "wrong-digest": manifest.assets[1].sha256 = String(repeating: "0", count: 64)
        case "missing-size": manifest.assets[1].byteCount = nil
        case "wrong-size": manifest.assets[1].byteCount = 1
        case "missing-view": manifest.corners[1].viewMappings = [:]
        case "missing-cross-view": manifest.crossViewMappings[1].cornerIDs = []
        case "nonmember-view": manifest.corners[1].assetIDs = []
        case "wrong-format": manifest.assets[1].format = .json
        case "invalid-pvt": manifest.corners[1].pvt.voltage = 0
        case "duplicate-manifest-corner": manifest.corners.append(manifest.corners[1])
        default: break
        }
        let manifestData = failure == "malformed" ? Data("{}".utf8) : try PDKManifestCodec.encode(manifest)
        let design = try Self.binding(designData, path: "design.json", kind: .netlist, format: .json)
        let constraints = try Self.binding(constraintsData, path: "constraints.sdc", kind: .constraints, format: .sdc)
        let pdk = try Self.binding(manifestData, path: "pdk.json", kind: .technology, format: .json)
        let typical = try Self.binding(typicalData, path: "typical.lib", kind: .model, format: .liberty)
        let slow = try Self.binding(slowData, path: "slow.lib", kind: .model, format: .liberty)
        var libraries = [
            TimingLibraryReference(artifact: typical, cornerIDs: suppliedCorners),
            TimingLibraryReference(artifact: slow, cornerIDs: ["slow"])
        ]
        if failure == "ambiguous-source" { libraries.append(libraries[0]) }
        if failure == "missing-library" { libraries.removeLast() }
        request = try STARequest(
            runID: "process-corner-api", design: design, topDesignName: "top",
            libraries: libraries, constraints: constraints,
            requestedModeIDs: ["functional"], requestedCornerIDs: requestedCorners,
            pdkManifest: pdk, processID: processID, pdkVersion: version
        )
        reader = InMemoryTimingArtifactReader(artifacts: [
            design.id: designData, constraints.id: constraintsData, pdk.id: manifestData,
            typical.id: typicalData, slow.id: slowData
        ])
    }

    static func binding(_ data: Data, path: String, kind: ArtifactKind, format: ArtifactFormat) throws -> TimingArtifactBinding {
        let reference = try ArtifactReference(
            digest: SHA256ContentDigester().digest(data: data, using: .sha256),
            byteCount: UInt64(data.count),
            descriptor: ArtifactDescriptor(role: .input, kind: kind, format: format)
        )
        return try TimingArtifactBinding(
            reference: reference,
            availability: .local(
                artifactID: reference.id,
                rootID: ArtifactRootID(rawValue: TimingArtifactBinding.workspaceRootIdentifier),
                relativePath: ArtifactRelativePath(segments: [path])
            )
        )
    }
}

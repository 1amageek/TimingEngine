import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import PDKCore
import STAEngine
import TimingCore

struct PreparedFixture {
    let root: URL
    let design: TimingArtifactBinding
    let constraints: TimingArtifactBinding
    let manifest: TimingArtifactBinding
    let libraries: [TimingLibraryReference]
    let reader: FileSystemTimingArtifactReader
    init(conditions: String = "operating_conditions (named) { process : 1; voltage : 1; temperature : 25; }") throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sta-prepared-" + UUID().uuidString)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corpus = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Corpus/fixtures/simple")
        func bind(_ bytes: Data, _ name: String, _ kind: ArtifactKind, _ format: ArtifactFormat) throws -> TimingArtifactBinding {
            try bytes.write(to: root.appending(path: name))
            let reference = try ArtifactReference(digest: SHA256ContentDigester().digest(data: bytes, using: .sha256),
                byteCount: UInt64(bytes.count), descriptor: ArtifactDescriptor(role: .input, kind: kind, format: format))
            return try TimingArtifactBinding(reference: reference, availability: .local(artifactID: reference.id,
                rootID: ArtifactRootID(rawValue: TimingArtifactBinding.workspaceRootIdentifier),
                relativePath: ArtifactRelativePath(segments: [name])))
        }
        design = try bind(Data(contentsOf: corpus.appending(path: "design.json")), "design.json", .netlist, .json)
        constraints = try bind(Data(contentsOf: corpus.appending(path: "constraints.sdc")), "constraints.sdc", .constraints, .sdc)
        let text = try String(contentsOf: corpus.appending(path: "library.lib"), encoding: .utf8)
            .replacingOccurrences(of: "time_unit", with: conditions + "\n  time_unit")
        var pdk = try PDKManifestCodec.decode(data: Data(contentsOf: corpus.appending(path: "pdk.json")))
        let asset = pdk.assets[0], corner = pdk.corners[0], mapping = pdk.crossViewMappings[0]
        pdk.assets = []; pdk.corners = []; pdk.crossViewMappings = []
        var supplied: [TimingLibraryReference] = []
        for id in ["typical", "slow"] {
            let bytes = Data((id == "slow" ? text.replacingOccurrences(of: "values (\"1.0\")", with: "values (\"3.0\")") : text).utf8)
            let source = try bind(bytes, id + ".lib", .model, .liberty)
            supplied.append(.init(artifact: source, cornerIDs: [id]))
            var a = asset; a.assetID = id; a.path = id + ".lib"; a.cornerIDs = [id]
            a.sha256 = source.digest.hexadecimalValue; a.byteCount = Int64(bytes.count)
            var c = corner; c.cornerID = id; c.assetIDs = [id]; c.viewMappings = ["liberty": id]
            var m = mapping; m.mappingID = id; m.assetID = id; m.cornerIDs = [id]
            pdk.assets.append(a); pdk.corners.append(c); pdk.crossViewMappings.append(m)
        }
        libraries = supplied
        manifest = try bind(PDKManifestCodec.encode(pdk), "pdk.json", .technology, .json)
        reader = FileSystemTimingArtifactReader(workspaceRoot: root)
    }
    func request(constraintBinding: TimingArtifactBinding? = nil, maxPaths: Int = 20, variation: STAVariation = STAVariation(), modes: [String] = [],
        expectation: ContentDigest? = nil, seed: UInt64? = nil,
        policy: STACharacterizationPolicy = .declaredCornerSelection, bindings: [STACharacterizationBinding] = []) throws -> STARequest {
        try STARequest(runID: "prepared", design: design, topDesignName: "top", libraries: libraries,
            constraints: constraintBinding ?? constraints, requestedModeIDs: modes, requestedCornerIDs: ["typical", "slow"],
            pdkManifest: manifest, processID: "fixture-process", pdkVersion: "1", maxPaths: maxPaths,
            variation: variation, configurationDigest: expectation, randomSeed: seed,
            characterizationPolicy: policy, characterizationBindings: bindings)
    }
    func resources() throws -> STAExecutionResources {
        .init(reader: reader, sourceLimits: try .init(maximumNestingDepth: 64),
            sourceResources: STALibertyResources(), limits: try STAExecutionLimits())
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
}

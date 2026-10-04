import CircuiteFoundationCrypto
import Foundation
import PDKCore

enum STATestProcessFactory {
    static func manifest(
        libraries: [String: Data],
        processID: String = "test"
    ) throws -> PDKManifest {
        let source = try TimingTestResources.corpusRoot.appending(path: "fixtures/simple/pdk.json")
        var manifest = try PDKManifestCodec.decode(data: Data(contentsOf: source))
        let sourceAsset = manifest.assets[0]
        let sourceCorner = manifest.corners[0]
        let sourceMapping = manifest.crossViewMappings[0]
        manifest.processID = processID
        manifest.assets = []
        manifest.corners = []
        manifest.crossViewMappings = []
        for cornerID in libraries.keys.sorted() {
            guard let data = libraries[cornerID] else { continue }
            var asset = sourceAsset
            asset.assetID = "liberty-\(cornerID)"
            asset.path = "\(cornerID).lib"
            asset.cornerIDs = [cornerID]
            asset.sha256 = try SHA256ContentDigester().digest(data: data, using: .sha256).hexadecimalValue
            asset.byteCount = Int64(data.count)
            var corner = sourceCorner
            corner.cornerID = cornerID
            corner.assetIDs = [asset.assetID]
            corner.viewMappings = ["liberty": asset.assetID]
            var mapping = sourceMapping
            mapping.mappingID = "mapping-\(cornerID)"
            mapping.assetID = asset.assetID
            mapping.cornerIDs = [cornerID]
            manifest.assets.append(asset)
            manifest.corners.append(corner)
            manifest.crossViewMappings.append(mapping)
        }
        return manifest
    }

    static func data(library: Data) throws -> Data {
        try PDKManifestCodec.encode(manifest(libraries: ["typical": library]))
    }
}

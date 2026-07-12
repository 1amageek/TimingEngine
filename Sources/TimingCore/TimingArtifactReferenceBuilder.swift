import CryptoKit
import Foundation
import XcircuitePackage

public struct TimingArtifactReferenceBuilder: Sendable {
    public init() {}

    public func makeReference(
        path: String,
        kind: XcircuiteFileKind,
        format: XcircuiteFileFormat,
        artifactID: String? = nil
    ) throws -> XcircuiteFileReference {
        let url = URL(filePath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TimingError.artifactReadFailed(path: path, message: error.localizedDescription)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return XcircuiteFileReference(
            artifactID: artifactID,
            path: url.standardizedFileURL.path(percentEncoded: false),
            kind: kind,
            format: format,
            sha256: digest,
            byteCount: Int64(data.count)
        )
    }
}

import CircuiteFoundation
import Foundation
import TimingCore

/// Immutable PDK identity consumed by TimingEngine Foundation requests.
public struct TimingPDKReference: Sendable, Hashable, Codable {
    public let manifest: TimingArtifactBinding
    public let processID: String
    public let version: String
    public let digest: ContentDigest

    public init(
        manifest: TimingArtifactBinding,
        processID: String,
        version: String,
        digest: ContentDigest? = nil
    ) throws {
        guard !processID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimingError.invalidInput("PDK process ID must not be empty.")
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimingError.invalidInput("PDK version must not be empty.")
        }
        let exactDigest = digest ?? manifest.digest
        guard exactDigest == manifest.digest else {
            throw TimingError.invalidInput("PDK digest must match the manifest artifact digest.")
        }
        self.manifest = manifest
        self.processID = processID
        self.version = version
        self.digest = exactDigest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            manifest: container.decode(TimingArtifactBinding.self, forKey: .manifest),
            processID: container.decode(String.self, forKey: .processID),
            version: container.decode(String.self, forKey: .version),
            digest: container.decode(ContentDigest.self, forKey: .digest)
        )
    }

    public func validate() throws {
        guard manifest.digest == digest else {
            throw TimingError.invalidInput("PDK digest must match the manifest artifact digest.")
        }
    }
}

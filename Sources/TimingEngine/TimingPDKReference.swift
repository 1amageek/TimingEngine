import CircuiteFoundation
import Foundation
import TimingCore

/// Immutable PDK identity consumed by TimingEngine Foundation requests.
public struct TimingPDKReference: Sendable, Hashable, Codable {
    public let manifest: ArtifactReference
    public let processID: String
    public let version: String
    public let digest: ContentDigest

    public init(
        manifest: ArtifactReference,
        processID: String,
        version: String,
        digest: ContentDigest? = nil
    ) throws {
        self.manifest = manifest
        self.processID = processID
        self.version = version
        self.digest = digest ?? manifest.digest
        guard !processID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimingError.invalidInput("PDK process ID must not be empty.")
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimingError.invalidInput("PDK version must not be empty.")
        }
    }

    public func validate() throws {
        guard manifest.digest == digest else {
            throw TimingError.invalidInput("PDK digest must match the manifest artifact digest.")
        }
    }
}

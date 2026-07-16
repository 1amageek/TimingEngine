import Foundation
import CircuiteFoundation

/// Liberty timing library artifact together with its supported corners.
public struct TimingLibraryReference: Sendable, Hashable, Codable {
    public let artifact: ArtifactReference
    public let cornerIDs: [String]

    public init(artifact: ArtifactReference, cornerIDs: [String] = []) {
        self.artifact = artifact
        self.cornerIDs = cornerIDs
    }
}

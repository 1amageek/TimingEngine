import Foundation
import CircuiteFoundation

/// Liberty timing library artifact together with its supported corners.
public struct TimingLibraryReference: Sendable, Hashable, Codable {
    public let artifact: TimingArtifactBinding
    public let cornerIDs: [String]

    public init(artifact: TimingArtifactBinding, cornerIDs: [String] = []) {
        self.artifact = artifact
        self.cornerIDs = cornerIDs
    }
}

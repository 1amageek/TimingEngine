import Foundation
import CircuiteFoundation

/// Timing constraint artifact together with the analysis modes it defines.
public struct TimingConstraintReference: Sendable, Hashable, Codable {
    public var artifact: ArtifactReference
    public var modeIDs: [String]

    public init(artifact: ArtifactReference, modeIDs: [String]) {
        self.artifact = artifact
        self.modeIDs = modeIDs
    }
}

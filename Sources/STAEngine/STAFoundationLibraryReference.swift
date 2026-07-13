import CircuiteFoundation
import Foundation

public struct STAFoundationLibraryReference: Sendable, Hashable, Codable {
    public let artifact: ArtifactReference
    public let cornerIDs: [String]

    public init(
        artifact: ArtifactReference,
        cornerIDs: [String] = []
    ) {
        self.artifact = artifact
        self.cornerIDs = cornerIDs
    }
}

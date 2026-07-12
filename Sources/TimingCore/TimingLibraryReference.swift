import Foundation
import XcircuitePackage

public struct TimingLibraryReference: Sendable, Hashable, Codable {
    public var artifact: XcircuiteFileReference
    public var cornerIDs: [String]

    public init(
        artifact: XcircuiteFileReference,
        cornerIDs: [String]
    ) {
        self.artifact = artifact
        self.cornerIDs = cornerIDs
    }
}

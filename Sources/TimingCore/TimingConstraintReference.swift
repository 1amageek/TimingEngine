import Foundation
import XcircuitePackage

public struct TimingConstraintReference: Sendable, Hashable, Codable {
    public var artifact: XcircuiteFileReference
    public var modeIDs: [String]

    public init(
        artifact: XcircuiteFileReference,
        modeIDs: [String]
    ) {
        self.artifact = artifact
        self.modeIDs = modeIDs
    }
}

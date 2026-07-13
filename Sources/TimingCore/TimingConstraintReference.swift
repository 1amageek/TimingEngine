import Foundation
import XcircuitePackage

@available(*, deprecated, message: "Use ArtifactReference directly in Foundation requests.")
public struct LegacyTimingConstraintReference: Sendable, Hashable, Codable {
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

@available(*, deprecated, message: "Use ArtifactReference directly in Foundation requests.")
public typealias TimingConstraintReference = LegacyTimingConstraintReference

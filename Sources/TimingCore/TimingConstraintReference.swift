import Foundation
import CircuiteFoundation
import DesignFlowKernel

@available(*, deprecated, message: "Use ArtifactReference directly in Foundation requests.")
public struct LegacyTimingConstraintReference: Sendable, Hashable, Codable {
    public var artifact: ArtifactReference
    public var modeIDs: [String]

    public init(
        artifact: ArtifactReference,
        modeIDs: [String]
    ) {
        self.artifact = artifact
        self.modeIDs = modeIDs
    }
}

@available(*, deprecated, message: "Use ArtifactReference directly in Foundation requests.")
public typealias TimingConstraintReference = LegacyTimingConstraintReference

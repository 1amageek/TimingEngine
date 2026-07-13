import Foundation
import CircuiteFoundation
import DesignFlowKernel

@available(*, deprecated, message: "Use STAFoundationLibraryReference with ArtifactReference.")
public struct LegacyTimingLibraryReference: Sendable, Hashable, Codable {
    public var artifact: ArtifactReference
    public var cornerIDs: [String]

    public init(
        artifact: ArtifactReference,
        cornerIDs: [String]
    ) {
        self.artifact = artifact
        self.cornerIDs = cornerIDs
    }
}

@available(*, deprecated, message: "Use STAFoundationLibraryReference with ArtifactReference.")
public typealias TimingLibraryReference = LegacyTimingLibraryReference

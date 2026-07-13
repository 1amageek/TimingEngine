import Foundation
import XcircuitePackage

@available(*, deprecated, message: "Use STAFoundationLibraryReference with ArtifactReference.")
public struct LegacyTimingLibraryReference: Sendable, Hashable, Codable {
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

@available(*, deprecated, message: "Use STAFoundationLibraryReference with ArtifactReference.")
public typealias TimingLibraryReference = LegacyTimingLibraryReference

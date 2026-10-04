import CircuiteFoundation
import PDKCore

/// Exact process and declared PVT sources admitted for a native STA execution.
public struct STAProcessSelection: Sendable, Hashable, Codable {
    public let processID: String
    public let pdkVersion: String
    public let manifest: ArtifactReference
    public let corners: [PDKCornerDefinition]
    public let librariesByCorner: [String: ArtifactReference]

    public init(
        processID: String,
        pdkVersion: String,
        manifest: ArtifactReference,
        corners: [PDKCornerDefinition],
        librariesByCorner: [String: ArtifactReference]
    ) {
        self.processID = processID
        self.pdkVersion = pdkVersion
        self.manifest = manifest
        self.corners = corners
        self.librariesByCorner = librariesByCorner
    }
}

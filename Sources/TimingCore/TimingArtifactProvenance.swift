import Foundation

public struct TimingArtifactProvenance: Sendable, Hashable, Codable {
    public var designDigest: String?
    public var libraryDigests: [String]
    public var constraintDigest: String?
    public var pdkDigest: String?
    public var parasiticsDigest: String?

    public init(
        designDigest: String? = nil,
        libraryDigests: [String] = [],
        constraintDigest: String? = nil,
        pdkDigest: String? = nil,
        parasiticsDigest: String? = nil
    ) {
        self.designDigest = designDigest
        self.libraryDigests = libraryDigests
        self.constraintDigest = constraintDigest
        self.pdkDigest = pdkDigest
        self.parasiticsDigest = parasiticsDigest
    }

    public var hasCoreDigests: Bool {
        designDigest != nil && constraintDigest != nil && pdkDigest != nil
    }

    public var isCompleteForSTA: Bool {
        hasCoreDigests && !libraryDigests.isEmpty && parasiticsDigest != nil
    }

    public var isCompleteForSignalIntegrity: Bool {
        hasCoreDigests && parasiticsDigest != nil
    }
}

import Foundation

public struct TimingPDKAssetEvidence: Sendable, Hashable, Codable {
    public var assetID: String
    public var relativePath: String
    public var format: String
    public var required: Bool
    public var present: Bool
    public var declaredDigest: String?
    public var observedDigest: String?
    public var byteCount: Int64?

    public init(
        assetID: String,
        relativePath: String,
        format: String,
        required: Bool,
        present: Bool,
        declaredDigest: String? = nil,
        observedDigest: String? = nil,
        byteCount: Int64? = nil
    ) {
        self.assetID = assetID
        self.relativePath = relativePath
        self.format = format
        self.required = required
        self.present = present
        self.declaredDigest = declaredDigest
        self.observedDigest = observedDigest
        self.byteCount = byteCount
    }

    public var isVerified: Bool {
        guard present, let observedDigest else { return false }
        if let declaredDigest {
            return declaredDigest.caseInsensitiveCompare(observedDigest) == .orderedSame
        }
        return true
    }
}

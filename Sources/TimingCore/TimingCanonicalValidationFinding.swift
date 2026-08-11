import Foundation

public struct TimingCanonicalValidationFinding: Sendable, Hashable, Codable {
    public let code: String
    public let summary: String
    public let entity: String?

    public init(code: String, summary: String, entity: String? = nil) {
        self.code = code
        self.summary = summary
        self.entity = entity
    }
}

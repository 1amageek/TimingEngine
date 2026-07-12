import Foundation

public enum TimingCorpusExpectedOutcome: String, Sendable, Hashable, Codable, CaseIterable {
    case completed
    case blocked
    case failed
}

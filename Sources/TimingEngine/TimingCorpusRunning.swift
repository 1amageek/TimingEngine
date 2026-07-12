import Foundation

public protocol TimingCorpusRunning: Sendable {
    func execute(
        manifest: TimingCorpusManifest,
        rootURL: URL,
        runID: String
    ) async throws -> TimingCorpusReport
}

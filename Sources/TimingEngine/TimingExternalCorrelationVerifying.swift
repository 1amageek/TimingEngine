import Foundation

public protocol TimingExternalCorrelationVerifying: Sendable {
    func verify(
        _ report: TimingExternalCorrelationReport,
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        externalOracle: TimingExternalOracleEvidence,
        workspaceRoot: URL
    ) async throws
}

import Foundation

public protocol TimingEvidenceEvaluating: Sendable {
    func evaluate(
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        modeIDs: [String],
        cornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        pdkEvidence: TimingPDKEvidence?,
        workspaceRoot: URL
    ) async -> TimingEvidenceAssessment
}

import Foundation

public protocol TimingQualificationEvaluating: Sendable {
    func evaluate(
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        modeIDs: [String],
        cornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        pdkEvidence: TimingPDKQualificationEvidence?
    ) -> TimingQualificationReport
}

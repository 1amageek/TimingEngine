import Foundation
import PDKCore

public protocol TimingQualificationEvaluating: Sendable {
    func evaluate(
        corpus: TimingCorpusReport,
        pdk: PDKReference,
        modeIDs: [String],
        cornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        pdkEvidence: TimingPDKQualificationEvidence?
    ) -> TimingQualificationReport
}

import Foundation

public struct TimingQualificationEvaluator: TimingQualificationEvaluating {
    public init() {}

    public func evaluate(
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        modeIDs: [String],
        cornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        pdkEvidence: TimingPDKQualificationEvidence?
    ) -> TimingQualificationReport {
        evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: modeIDs,
            cornerIDs: cornerIDs,
            externalOracle: externalOracle,
            externalCorrelation: nil,
            pdkEvidence: pdkEvidence
        )
    }

    public func evaluate(
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        modeIDs: [String],
        cornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        externalCorrelation: TimingCorrelationResult?,
        pdkEvidence: TimingPDKQualificationEvidence?
    ) -> TimingQualificationReport {
        var findings: [String] = []
        let corpusEvidenceDigest: String?
        do {
            corpusEvidenceDigest = try TimingEvidenceHasher().hash(corpus)
        } catch {
            corpusEvidenceDigest = nil
            findings.append("corpus_evidence_digest_failed")
        }
        do {
            try pdk.validate()
        } catch {
            findings.append("pdk_reference_invalid")
        }
        guard pdk.processID == corpus.processID else {
            findings.append("process_id_mismatch")
            return report(
                decision: .failed,
                corpus: corpus,
                pdk: pdk,
                modeIDs: modeIDs,
                cornerIDs: cornerIDs,
                externalOracle: externalOracle,
                externalCorrelation: externalCorrelation,
                pdkEvidence: pdkEvidence,
                findings: findings,
                corpusEvidenceDigest: corpusEvidenceDigest
            )
        }
        if !corpus.isValid { findings.append("retained_corpus_failed") }
        if modeIDs.isEmpty { findings.append("mode_matrix_empty") }
        if cornerIDs.isEmpty { findings.append("corner_matrix_empty") }
        if let pdkEvidence {
            if !pdkEvidence.isComplete { findings.append(contentsOf: pdkEvidence.findings) }
            let missingCorners = Set(cornerIDs).subtracting(pdkEvidence.cornerIDs)
            findings.append(contentsOf: missingCorners.sorted().map { "pdk_corner_missing:\($0)" })
        } else {
            findings.append("pdk_evidence_missing")
        }
        if externalOracle.status != .available { findings.append("external_sta_oracle_unavailable") }
        if let externalCorrelation {
            if !externalCorrelation.passed { findings.append("external_oracle_correlation_failed") }
            if externalCorrelation.oracleID != externalOracle.oracleID { findings.append("external_oracle_identity_mismatch") }
        } else {
            findings.append("external_oracle_correlation_missing")
        }
        let decision: TimingQualificationReport.Decision
        if findings.contains("pdk_reference_invalid") || findings.contains("process_id_mismatch") {
            decision = .failed
        } else if !findings.isEmpty {
            decision = .blocked
        } else {
            decision = .qualified
        }
        return report(
            decision: decision,
            corpus: corpus,
            pdk: pdk,
            modeIDs: modeIDs,
            cornerIDs: cornerIDs,
            externalOracle: externalOracle,
            externalCorrelation: externalCorrelation,
            pdkEvidence: pdkEvidence,
            findings: findings,
            corpusEvidenceDigest: corpusEvidenceDigest
        )
    }

    private func report(
        decision: TimingQualificationReport.Decision,
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        modeIDs: [String],
        cornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        externalCorrelation: TimingCorrelationResult?,
        pdkEvidence: TimingPDKQualificationEvidence?,
        findings: [String],
        corpusEvidenceDigest: String?
    ) -> TimingQualificationReport {
        TimingQualificationReport(
            decision: decision,
            processID: pdk.processID,
            pdkVersion: pdk.version,
            pdkDigest: pdk.digest.hexadecimalValue,
            pdkManifestDigest: pdk.manifest.digest.hexadecimalValue,
            corpusSuiteID: corpus.suiteID,
            corpusEvidenceDigest: corpusEvidenceDigest,
            requiredModeIDs: modeIDs,
            requiredCornerIDs: cornerIDs,
            externalOracle: externalOracle,
            externalCorrelation: externalCorrelation,
            pdkEvidence: pdkEvidence,
            findings: findings
        )
    }
}

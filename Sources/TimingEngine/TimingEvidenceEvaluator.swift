import CircuiteFoundation
import Foundation

public struct TimingEvidenceEvaluator: TimingEvidenceEvaluating {
    private let externalCorrelationVerifier: any TimingExternalCorrelationVerifying

    public init(
        externalCorrelationVerifier: any TimingExternalCorrelationVerifying = LocalTimingExternalCorrelationVerifier()
    ) {
        self.externalCorrelationVerifier = externalCorrelationVerifier
    }

    public func evaluate(
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        modeIDs: [String],
        cornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        pdkEvidence: TimingPDKEvidence?,
        workspaceRoot: URL
    ) async -> TimingEvidenceAssessment {
        await evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: modeIDs,
            cornerIDs: cornerIDs,
            externalOracle: externalOracle,
            externalCorrelation: nil,
            pdkEvidence: pdkEvidence,
            workspaceRoot: workspaceRoot
        )
    }

    public func evaluate(
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        modeIDs: [String],
        cornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        externalCorrelation: TimingExternalCorrelationReport?,
        pdkEvidence: TimingPDKEvidence?,
        workspaceRoot: URL
    ) async -> TimingEvidenceAssessment {
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
            return assessment(
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
            if pdkEvidence.processID != pdk.processID { findings.append("pdk_evidence_process_mismatch") }
            if pdkEvidence.version != pdk.version { findings.append("pdk_evidence_version_mismatch") }
            if pdkEvidence.manifestDigest.caseInsensitiveCompare(pdk.manifest.digest.hexadecimalValue) != .orderedSame {
                findings.append("pdk_evidence_manifest_digest_mismatch")
            }
            let missingCorners = Set(cornerIDs).subtracting(pdkEvidence.cornerIDs)
            findings.append(contentsOf: missingCorners.sorted().map { "pdk_corner_missing:\($0)" })
        } else {
            findings.append("pdk_evidence_missing")
        }
        if externalOracle.status != .available { findings.append("external_sta_oracle_unavailable") }
        if let externalCorrelation {
            do {
                try await externalCorrelationVerifier.verify(
                    externalCorrelation,
                    corpus: corpus,
                    pdk: pdk,
                    externalOracle: externalOracle,
                    workspaceRoot: workspaceRoot
                )
            } catch {
                findings.append("external_oracle_correlation_invalid")
            }
            if !externalCorrelation.correlation.passed { findings.append("external_oracle_correlation_failed") }
            if externalCorrelation.correlation.oracleID != externalOracle.oracleID {
                findings.append("external_oracle_identity_mismatch")
            }
            if externalCorrelation.oracleTool.identifier != externalOracle.oracleID {
                findings.append("external_oracle_tool_identity_mismatch")
            }
            if externalCorrelation.oracleTool.version != externalOracle.version {
                findings.append("external_oracle_tool_version_mismatch")
            }
            if externalCorrelation.processID != pdk.processID {
                findings.append("external_correlation_process_mismatch")
            }
            if externalCorrelation.pdkVersion != pdk.version {
                findings.append("external_correlation_pdk_version_mismatch")
            }
            if externalCorrelation.pdkManifestDigest.caseInsensitiveCompare(pdk.manifest.digest.hexadecimalValue) != .orderedSame {
                findings.append("external_correlation_pdk_manifest_digest_mismatch")
            }
            if externalCorrelation.corpusEvidenceDigest.caseInsensitiveCompare(corpusEvidenceDigest ?? "") != .orderedSame {
                findings.append("external_correlation_corpus_digest_mismatch")
            }
        } else {
            findings.append("external_oracle_correlation_missing")
        }
        return assessment(
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

    private func assessment(
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        modeIDs: [String],
        cornerIDs: [String],
        externalOracle: TimingExternalOracleEvidence,
        externalCorrelation: TimingExternalCorrelationReport?,
        pdkEvidence: TimingPDKEvidence?,
        findings: [String],
        corpusEvidenceDigest: String?
    ) -> TimingEvidenceAssessment {
        TimingEvidenceAssessment(
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

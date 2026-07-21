import CircuiteFoundation
import Foundation
import STAEngine
import TimingCore

public struct LocalTimingExternalCorrelationVerifier: TimingExternalCorrelationVerifying {
    public init() {}

    public func verify(
        _ report: TimingExternalCorrelationReport,
        corpus: TimingCorpusReport,
        pdk: TimingPDKReference,
        externalOracle: TimingExternalOracleEvidence,
        workspaceRoot: URL
    ) async throws {
        let canonicalRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let reader = FileSystemTimingArtifactReader(workspaceRoot: canonicalRoot)
        try report.validateStructure()
        guard report.processID == pdk.processID,
              report.pdkVersion == pdk.version,
              report.pdkManifestArtifact == pdk.manifest,
              report.pdkManifestDigest.caseInsensitiveCompare(
                pdk.manifest.digest.hexadecimalValue
              ) == .orderedSame else {
            throw TimingError.invalidInput("External correlation does not match the selected PDK.")
        }
        let retainedCorpus: TimingCorpusReport = try await decode(
            report.corpusEvidenceArtifact,
            as: TimingCorpusReport.self,
            format: "timing corpus report",
            reader: reader
        )
        guard retainedCorpus == corpus else {
            throw TimingError.invalidInput("External correlation corpus artifact does not match the selected corpus report.")
        }
        let corpusDigest = try TimingEvidenceHasher().hash(retainedCorpus)
        guard report.corpusEvidenceDigest.caseInsensitiveCompare(corpusDigest) == .orderedSame else {
            throw TimingError.invalidInput("External correlation does not match the retained corpus evidence.")
        }
        guard externalOracle.status == .available,
              report.oracleTool.identifier == externalOracle.oracleID,
              report.oracleTool.version == externalOracle.version else {
            throw TimingError.invalidInput("External correlation does not match the selected oracle tool.")
        }

        let artifacts = [
            report.pdkManifestArtifact,
            report.corpusEvidenceArtifact,
            report.oracleExecutableArtifact,
            report.nativeOutputArtifact,
            report.oracleOutputArtifact
        ] + report.inputArtifacts
        for artifact in artifacts {
            _ = try await reader.read(artifact)
        }

        let retainedPDK = try LocalTimingPDKEvidenceBuilder(
            workspaceRoot: canonicalRoot
        ).build(for: pdk)
        guard retainedPDK.isComplete,
              retainedPDK.manifestDigest.caseInsensitiveCompare(report.pdkManifestDigest) == .orderedSame else {
            throw TimingError.invalidInput("External correlation PDK manifest artifact is incomplete or does not match its retained digest.")
        }

        let native: STAExecutionResult = try await decode(
            report.nativeOutputArtifact,
            as: STAExecutionResult.self,
            format: "native STA execution result",
            reader: reader
        )
        let oracle: STAExecutionResult = try await decode(
            report.oracleOutputArtifact,
            as: STAExecutionResult.self,
            format: "oracle STA execution result",
            reader: reader
        )
        guard native.evidence.provenance.producer == report.nativeEngine else {
            throw TimingError.invalidInput("Native output producer does not match the retained engine identity.")
        }
        guard oracle.evidence.provenance.supportingTools.filter({ $0 == report.oracleTool }).count == 1 else {
            throw TimingError.invalidInput("Oracle output does not retain exactly one selected oracle identity.")
        }
        guard oracle.evidence.provenance.producer != native.evidence.provenance.producer,
              report.oracleTool != native.evidence.provenance.producer else {
            throw TimingError.invalidInput("Native and oracle outputs do not come from independent implementations.")
        }
        guard native.evidence.provenance.inputs == report.inputArtifacts,
              oracle.evidence.provenance.inputs == report.inputArtifacts else {
            throw TimingError.invalidInput("Native and oracle outputs are not bound to the same retained inputs.")
        }
        guard report.inputArtifacts.contains(report.pdkManifestArtifact) else {
            throw TimingError.invalidInput("The selected PDK manifest is missing from correlated inputs.")
        }
        try verifyExecutableBinding(
            report: report,
            oracle: oracle,
            externalOracle: externalOracle,
            workspaceRoot: canonicalRoot
        )

        if native.status == .completed, oracle.status == .completed {
            let recomputed = TimingExternalOracleCorrelator(
                tolerance: report.correlation.tolerance
            ).compare(
                native: native.payload,
                external: oracle.payload,
                oracleID: report.oracleTool.identifier
            )
            guard recomputed == report.correlation else {
                throw TimingError.invalidInput("External correlation metrics do not match the retained STA outputs.")
            }
        } else {
            guard report.correlation.status == .blocked,
                  !report.correlation.passed,
                  !report.correlation.diagnostics.isEmpty else {
                throw TimingError.invalidInput("Incomplete timing execution must retain a blocked correlation.")
            }
        }
    }

    private func decode<Value: Decodable>(
        _ artifact: ArtifactReference,
        as type: Value.Type,
        format: String,
        reader: FileSystemTimingArtifactReader
    ) async throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: try await reader.read(artifact))
        } catch {
            throw TimingError.parseFailure(
                format: format,
                line: 1,
                message: error.localizedDescription
            )
        }
    }

    private func verifyExecutableBinding(
        report: TimingExternalCorrelationReport,
        oracle: STAExecutionResult,
        externalOracle: TimingExternalOracleEvidence,
        workspaceRoot: URL
    ) throws {
        guard let invocation = oracle.evidence.provenance.invocation,
              invocation.mode == .externalProcess,
              let invocationPath = invocation.executable,
              let evidencePath = externalOracle.executablePath else {
            throw TimingError.invalidInput("Oracle output does not retain its external executable invocation.")
        }
        let artifactURL = try report.oracleExecutableArtifact.locator.location
            .resolvedFileURL(relativeTo: workspaceRoot).resolvingSymlinksInPath().standardizedFileURL
        let invocationURL = URL(filePath: invocationPath)
            .resolvingSymlinksInPath().standardizedFileURL
        let evidenceURL = URL(filePath: evidencePath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard artifactURL == invocationURL, artifactURL == evidenceURL else {
            throw TimingError.invalidInput("Oracle executable artifact, invocation and selection do not match.")
        }
        guard let oracleBuild = report.oracleTool.build,
              oracleBuild.caseInsensitiveCompare(
                report.oracleExecutableArtifact.digest.hexadecimalValue
              ) == .orderedSame else {
            throw TimingError.invalidInput("Oracle producer build does not match the retained executable digest.")
        }
    }
}

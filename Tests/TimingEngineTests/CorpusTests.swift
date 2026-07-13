import Foundation
import CircuiteFoundation
import Testing
@testable import TimingEngine
import TimingCore
import STAEngine

@Suite("Timing corpus and correlation")
struct CorpusTests {
    @Test("replays retained positive, blocked, and SI cases")
    func replaysRetainedCorpus() async throws {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = packageRoot.appending(path: "Corpus/timing-corpus.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(TimingCorpusManifest.self, from: manifestData)
        let report = try await LocalTimingCorpusRunner().execute(
            manifest: manifest,
            rootURL: packageRoot.appending(path: "Corpus"),
            runID: "test-corpus"
        )
        #expect(report.isValid)
        #expect(report.caseResults.count == 3)
        #expect(report.caseResults.contains { $0.caseID == "sta-positive" && $0.correlation?.passed == true })
        #expect(report.caseResults.contains { $0.caseID == "sta-blocked" && $0.observedOutcome == .blocked })
        #expect(report.caseResults.contains { $0.caseID == "si-positive" && $0.provenance.isCompleteForSignalIntegrity })
    }

    @Test("artifact references retain deterministic digest and size")
    func buildsArtifactReference() throws {
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Corpus/fixtures/simple/library.lib")
        let reference = try TimingArtifactReferenceBuilder().makeReference(
            path: fixture.path(percentEncoded: false),
            kind: try ArtifactKind(rawValue: "timing.library"),
            format: .liberty
        )
        #expect(reference.digest.hexadecimalValue.count == 64)
        #expect(reference.byteCount > 0)
    }

    @Test("qualification blocks when an external oracle is unavailable")
    func qualificationRequiresExternalOracle() async throws {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestData = try Data(contentsOf: packageRoot.appending(path: "Corpus/timing-corpus.json"))
        let manifest = try JSONDecoder().decode(TimingCorpusManifest.self, from: manifestData)
        let corpus = try await LocalTimingCorpusRunner().execute(
            manifest: manifest,
            rootURL: packageRoot.appending(path: "Corpus"),
            runID: "qualification-test"
        )
        let corpusRoot = packageRoot.appending(path: "Corpus")
        let pdkReference = try LocalArtifactReferencer().reference(
            ArtifactLocator(
                location: try ArtifactLocation(workspaceRelativePath: "fixtures/simple/pdk.json"),
                kind: CircuiteFoundation.ArtifactKind.technology,
                format: .json
            ),
            relativeTo: corpusRoot
        )
        let pdk = try TimingPDKReference(
            manifest: pdkReference,
            processID: "fixture-process",
            version: "1",
            digest: pdkReference.digest
        )
        let pdkEvidence = try LocalTimingPDKQualificationEvidenceBuilder(
            workspaceRoot: corpusRoot
        ).build(for: pdk)
        let report = TimingQualificationEvaluator().evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: ["functional"],
            cornerIDs: ["typical"],
            externalOracle: TimingExternalOracleEvidence(
                oracleID: "missing",
                status: .unavailable,
                details: "test fixture"
            ),
            pdkEvidence: pdkEvidence
        )
        #expect(report.decision == .blocked)
        #expect(report.findings.contains("external_sta_oracle_unavailable"))
        #expect(report.corpusEvidenceDigest?.count == 64)
        #expect(report.pdkManifestDigest?.count == 64)
        #expect(report.pdkEvidence?.isComplete == true)

        let availableWithoutCorrelation = TimingQualificationEvaluator().evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: ["functional"],
            cornerIDs: ["typical"],
            externalOracle: TimingExternalOracleEvidence(
                oracleID: "available-oracle",
                status: .available,
                executablePath: "/usr/bin/true",
                details: "test fixture"
            ),
            externalCorrelation: nil,
            pdkEvidence: pdkEvidence
        )
        #expect(availableWithoutCorrelation.decision == .blocked)
        #expect(availableWithoutCorrelation.findings.contains("external_oracle_correlation_missing"))
    }

    @Test("external oracle correlation checks metrics and provenance")
    func externalOracleCorrelation() {
        let provenance = TimingArtifactProvenance(
            designDigest: "design",
            libraryDigests: ["library"],
            constraintDigest: "constraints",
            pdkDigest: "pdk",
            parasiticsDigest: "parasitics"
        )
        let native = STAPayload(
            worstSetupSlack: 1e-9,
            worstHoldSlack: 2e-9,
            analyzedCorners: ["typical"],
            analyzedModes: ["functional"],
            signoffEligible: true,
            provenance: provenance
        )
        let external = STAPayload(
            worstSetupSlack: 1e-9,
            worstHoldSlack: 2e-9,
            analyzedCorners: ["typical"],
            analyzedModes: ["functional"],
            signoffEligible: true,
            provenance: provenance
        )
        let matched = TimingExternalOracleCorrelator().compare(
            native: native,
            external: external,
            oracleID: "fixture-oracle"
        )
        #expect(matched.passed)

        var mismatched = external
        mismatched.analyzedModes = ["scan"]
        let rejected = TimingExternalOracleCorrelator().compare(
            native: native,
            external: mismatched,
            oracleID: "fixture-oracle"
        )
        #expect(!rejected.passed)
        #expect(rejected.diagnostics.contains("analyzed_modes_mismatch"))
    }

    @Test("unavailable external oracle produces a blocked result")
    func unavailableExternalOracle() async throws {
        let result = try await LocalTimingExternalOracleRunner().execute(
            TimingExternalOracleRequest(
                runID: "oracle-blocked",
                oracleID: "missing-oracle",
                executablePath: "/path/to/missing/oracle",
                workingDirectory: FileManager.default.temporaryDirectory.path(percentEncoded: false)
            )
        )
        #expect(result.status == .blocked)
        #expect(result.diagnostics == ["external_oracle_executable_unavailable"])
    }

    @Test("external oracle runner consumes a Foundation result")
    func externalOracleRunnerReadsResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "timing-oracle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = STAPayload(
            worstSetupSlack: 1e-9,
            worstHoldSlack: 2e-9,
            analyzedCorners: ["typical"],
            analyzedModes: ["functional"]
        )
        let now = Date()
        let producer = try ProducerIdentity(
            kind: .tool,
            identifier: "timing.external",
            version: "1"
        )
        let oracleResult = STAExecutionResult(
            runID: "oracle-envelope",
            status: .completed,
            payload: payload,
            provenance: try ExecutionProvenance(
                producer: producer,
                startedAt: now,
                completedAt: now
            )
        )
        let reportURL = directory.appending(path: "oracle.json")
        try JSONEncoder().encode(oracleResult).write(to: reportURL, options: .atomic)
        let observed = try await LocalTimingExternalOracleRunner().execute(
            TimingExternalOracleRequest(
                runID: "oracle-envelope",
                oracleID: "fixture-oracle",
                executablePath: "/bin/cat",
                arguments: [reportURL.path(percentEncoded: false)],
                workingDirectory: directory.path(percentEncoded: false)
            )
        )
        #expect(observed.status == .completed)
        #expect(observed.payload?.worstSetupSlack == 1e-9)
    }

    @Test("external oracle runner rejects a result from another run")
    func externalOracleRunnerRejectsMismatchedRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "timing-oracle-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let producer = try ProducerIdentity(
            kind: .tool,
            identifier: "timing.external",
            version: "1"
        )
        let oracleResult = STAExecutionResult(
            runID: "different-run",
            status: .completed,
            payload: STAPayload(
                worstSetupSlack: 1e-9,
                worstHoldSlack: 2e-9,
                analyzedCorners: ["typical"]
            ),
            provenance: try ExecutionProvenance(
                producer: producer,
                startedAt: now,
                completedAt: now
            )
        )
        let reportURL = directory.appending(path: "oracle.json")
        try JSONEncoder().encode(oracleResult).write(to: reportURL, options: .atomic)
        let observed = try await LocalTimingExternalOracleRunner().execute(
            TimingExternalOracleRequest(
                runID: "expected-run",
                oracleID: "fixture-oracle",
                executablePath: "/bin/cat",
                arguments: [reportURL.path(percentEncoded: false)],
                workingDirectory: directory.path(percentEncoded: false)
            )
        )
        #expect(observed.status == .failed)
        #expect(observed.diagnostics == ["external_oracle_run_id_mismatch"])
    }

    @Test("external oracle timeout returns a structured failure")
    func externalOracleTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "timing-oracle-timeout-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await LocalTimingExternalOracleRunner().execute(
            TimingExternalOracleRequest(
                runID: "oracle-timeout",
                oracleID: "fixture-oracle",
                executablePath: "/bin/sh",
                arguments: ["-c", "sleep 2"],
                workingDirectory: directory.path(percentEncoded: false),
                timeoutSeconds: 0.05
            )
        )
        #expect(result.status == .failed)
        #expect(result.diagnostics == ["external_oracle_timed_out"])
    }

    @Test("external oracle request preserves legacy decoding")
    func legacyExternalOracleRequestDecoding() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "runID": "legacy-oracle",
          "oracleID": "fixture-oracle",
          "executablePath": "/bin/cat",
          "arguments": [],
          "workingDirectory": "/tmp"
        }
        """.utf8)
        let request = try JSONDecoder().decode(TimingExternalOracleRequest.self, from: data)
        #expect(request.schemaVersion == 1)
        #expect(request.timeoutSeconds == TimingExternalOracleRequest.defaultTimeoutSeconds)
    }
}

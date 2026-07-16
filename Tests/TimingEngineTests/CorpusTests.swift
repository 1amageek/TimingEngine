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

    @Test("checked-in Sky130A profile remains blocked without the exact external Liberty artifact")
    func sky130ProfileRequiresRetainedLiberty() throws {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let profileRoot = packageRoot.appending(path: "Qualification/sky130A")
        let manifestURL = profileRoot.appending(path: "pdk.json")
        let manifestReference = try TimingArtifactReferenceBuilder().makeReference(
            at: manifestURL,
            relativeTo: profileRoot,
            kind: .technology,
            format: .json
        )
        let pdk = try TimingPDKReference(
            manifest: manifestReference,
            processID: "sky130A",
            version: "c6d73a35f524070e85faff4a6a9eef49553ebc2b",
            digest: manifestReference.digest
        )
        let evidence = try LocalTimingPDKEvidenceBuilder(
            workspaceRoot: profileRoot
        ).build(for: pdk)

        #expect(!evidence.isComplete)
        #expect(evidence.findings.contains("pdk_required_asset_missing:sky130_fd_sc_hd_tt_liberty"))
        #expect(evidence.assets.first?.present == false)
    }

    @Test("evidence assessment blocks when an external oracle is unavailable")
    func evidenceAssessmentRequiresExternalOracle() async throws {
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
                role: .input,
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
        let pdkEvidence = try LocalTimingPDKEvidenceBuilder(
            workspaceRoot: corpusRoot
        ).build(for: pdk)
        let report = await TimingEvidenceEvaluator().evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: ["functional"],
            cornerIDs: ["typical"],
            externalOracle: TimingExternalOracleEvidence(
                oracleID: "missing",
                status: .unavailable,
                details: "test fixture"
            ),
            pdkEvidence: pdkEvidence,
            workspaceRoot: corpusRoot
        )
        #expect(report.outcome == .blocked)
        #expect(report.findings.contains("external_sta_oracle_unavailable"))
        #expect(report.corpusEvidenceDigest?.count == 64)
        #expect(report.pdkManifestDigest?.count == 64)
        #expect(report.pdkEvidence?.isComplete == true)

        let availableWithoutCorrelation = await TimingEvidenceEvaluator().evaluate(
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
            pdkEvidence: pdkEvidence,
            workspaceRoot: corpusRoot
        )
        #expect(availableWithoutCorrelation.outcome == .blocked)
        #expect(availableWithoutCorrelation.findings.contains("external_oracle_correlation_missing"))

        let encoded = try JSONEncoder().encode(availableWithoutCorrelation)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["outcome"] = "passed"
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(TimingEvidenceAssessment.self, from: tampered)
        #expect(decoded.outcome == .blocked)

        object["schemaVersion"] = 1
        let obsolete = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimingEvidenceAssessment.self, from: obsolete)
        }

        let pdkData = try JSONEncoder().encode(pdkEvidence)
        var pdkObject = try #require(JSONSerialization.jsonObject(with: pdkData) as? [String: Any])
        pdkObject["isComplete"] = false
        let injectedPDK = try JSONSerialization.data(withJSONObject: pdkObject, options: [.sortedKeys])
        let decodedPDK = try JSONDecoder().decode(TimingPDKEvidence.self, from: injectedPDK)
        #expect(decodedPDK.isComplete)
    }

    @Test("workspace-relative artifact construction rejects a symlink escape")
    func workspaceArtifactRejectsSymlinkEscape() throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "timing-workspace-boundary-\(UUID().uuidString)"
        )
        let root = parent.appending(path: "workspace")
        let outside = parent.appending(path: "outside.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: parent)
            } catch {
                Issue.record("Failed to remove timing workspace boundary fixture: \(error)")
            }
        }
        try Data("outside".utf8).write(to: outside, options: .atomic)
        let link = root.appending(path: "escaped.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: TimingError.self) {
            try TimingArtifactReferenceBuilder().makeReference(
                at: link,
                relativeTo: root,
                kind: .evidence,
                format: .json
            )
        }
    }

    @Test("evidence assessment cross-binds external correlation to PDK, corpus, tool, and artifacts")
    func evidenceAssessmentBindsExternalCorrelationEvidence() async throws {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let corpusRoot = packageRoot.appending(path: "Corpus")
        let manifest = try JSONDecoder().decode(
            TimingCorpusManifest.self,
            from: Data(contentsOf: packageRoot.appending(path: "Corpus/timing-corpus.json"))
        )
        let corpus = try await LocalTimingCorpusRunner().execute(
            manifest: manifest,
            rootURL: corpusRoot,
            runID: "bound-correlation"
        )
        let workspaceRoot = FileManager.default.temporaryDirectory.appending(
            path: "timing-bound-correlation-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: workspaceRoot)
            } catch {
                Issue.record("Failed to remove timing correlation workspace: \(error)")
            }
        }
        let fixtureDirectory = workspaceRoot.appending(path: "fixtures/simple")
        try FileManager.default.createDirectory(
            at: fixtureDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: corpusRoot.appending(path: "fixtures/simple"),
            to: fixtureDirectory
        )
        let executableDirectory = workspaceRoot.appending(path: "tools")
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executableURL = executableDirectory.appending(path: "true")
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: executableURL)
        let executablePath = executableURL.path(percentEncoded: false)
        let pdkReference = try TimingArtifactReferenceBuilder().makeReference(
            at: fixtureDirectory.appending(path: "pdk.json"),
            relativeTo: workspaceRoot,
            kind: CircuiteFoundation.ArtifactKind.technology,
            format: .json
        )
        let pdk = try TimingPDKReference(
            manifest: pdkReference,
            processID: "fixture-process",
            version: "1",
            digest: pdkReference.digest
        )
        let pdkEvidence = try LocalTimingPDKEvidenceBuilder(
            workspaceRoot: workspaceRoot
        ).build(for: pdk)
        let oracleTool = try ProducerIdentity(
            kind: .tool,
            identifier: "fixture-oracle",
            version: "1"
        )
        let nativeEngine = try ProducerIdentity(
            kind: .engine,
            identifier: "timing.sta",
            version: "1"
        )
        let oracleAdapter = try ProducerIdentity(
            kind: .tool,
            identifier: "timing.sta.external",
            version: "1"
        )
        let executableArtifact = try TimingArtifactReferenceBuilder().makeReference(
            at: executableURL,
            relativeTo: workspaceRoot,
            kind: try ArtifactKind(rawValue: "tool.executable"),
            format: try ArtifactFormat(rawValue: "binary")
        )
        let evidenceDirectory = workspaceRoot.appending(path: "evidence")
        let outputDirectory = workspaceRoot.appending(path: "outputs")
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let corpusURL = evidenceDirectory.appending(path: "corpus.json")
        let corpusData = try JSONEncoder().encode(corpus)
        try corpusData.write(to: corpusURL, options: .atomic)
        let corpusArtifact = try TimingArtifactReferenceBuilder().makeReference(
            at: corpusURL,
            relativeTo: workspaceRoot,
            kind: .report,
            format: .json
        )
        let payload = STAPayload(
            worstSetupSlack: 1e-9,
            worstHoldSlack: 2e-9,
            analyzedCorners: ["typical"],
            analyzedModes: ["functional"],
            provenance: TimingArtifactProvenance(pdkDigest: pdkReference.digest.hexadecimalValue)
        )
        let now = Date(timeIntervalSince1970: 1)
        let native = STAExecutionResult(
            runID: "native-correlation",
            status: .completed,
            payload: payload,
            provenance: try ExecutionProvenance(
                producer: nativeEngine,
                inputs: [pdkReference],
                startedAt: now,
                completedAt: now
            )
        )
        let oracle = STAExecutionResult(
            runID: "oracle-correlation",
            status: .completed,
            payload: payload,
            provenance: try ExecutionProvenance(
                producer: oracleAdapter,
                supportingTools: [oracleTool],
                inputs: [pdkReference],
                invocation: try ExecutionInvocation.externalProcess(executable: executablePath),
                startedAt: now,
                completedAt: now
            )
        )
        let nativeURL = outputDirectory.appending(path: "native.json")
        let oracleURL = outputDirectory.appending(path: "oracle.json")
        try JSONEncoder().encode(native).write(to: nativeURL, options: .atomic)
        try JSONEncoder().encode(oracle).write(to: oracleURL, options: .atomic)
        let nativeOutput = try TimingArtifactReferenceBuilder().makeReference(
            at: nativeURL,
            relativeTo: workspaceRoot,
            role: .output,
            kind: .report,
            format: .json
        )
        let oracleOutput = try TimingArtifactReferenceBuilder().makeReference(
            at: oracleURL,
            relativeTo: workspaceRoot,
            role: .output,
            kind: .report,
            format: .json
        )
        let correlation = TimingExternalCorrelationReport(
            processID: pdk.processID,
            pdkVersion: pdk.version,
            pdkManifestDigest: pdkEvidence.manifestDigest,
            corpusEvidenceDigest: try TimingEvidenceHasher().hash(corpus),
            pdkManifestArtifact: pdkReference,
            corpusEvidenceArtifact: corpusArtifact,
            nativeEngine: nativeEngine,
            oracleTool: oracleTool,
            oracleExecutableArtifact: executableArtifact,
            inputArtifacts: [pdkReference],
            nativeOutputArtifact: nativeOutput,
            oracleOutputArtifact: oracleOutput,
            correlation: TimingExternalOracleCorrelator().compare(
                native: payload,
                external: payload,
                oracleID: oracleTool.identifier
            )
        )
        let evaluator = TimingEvidenceEvaluator()
        let passed = await evaluator.evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: ["functional"],
            cornerIDs: ["typical"],
            externalOracle: TimingExternalOracleEvidence(
                oracleID: oracleTool.identifier,
                status: .available,
                executablePath: executablePath,
                version: oracleTool.version,
                details: "retained fixture"
            ),
            externalCorrelation: correlation,
            pdkEvidence: pdkEvidence,
            workspaceRoot: workspaceRoot
        )
        #expect(passed.outcome == .passed)

        var unrelated = correlation
        unrelated.corpusEvidenceDigest = String(repeating: "0", count: 64)
        let blocked = await evaluator.evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: ["functional"],
            cornerIDs: ["typical"],
            externalOracle: TimingExternalOracleEvidence(
                oracleID: oracleTool.identifier,
                status: .available,
                executablePath: executablePath,
                version: oracleTool.version,
                details: "retained fixture"
            ),
            externalCorrelation: unrelated,
            pdkEvidence: pdkEvidence,
            workspaceRoot: workspaceRoot
        )
        #expect(blocked.outcome == .blocked)
        #expect(blocked.findings.contains("external_correlation_corpus_digest_mismatch"))

        try Data("tampered-corpus-output".utf8).write(to: corpusURL, options: .atomic)
        let tamperedCorpus = await evaluator.evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: ["functional"],
            cornerIDs: ["typical"],
            externalOracle: TimingExternalOracleEvidence(
                oracleID: oracleTool.identifier,
                status: .available,
                executablePath: executablePath,
                version: oracleTool.version,
                details: "retained fixture"
            ),
            externalCorrelation: correlation,
            pdkEvidence: pdkEvidence,
            workspaceRoot: workspaceRoot
        )
        #expect(tamperedCorpus.outcome == .blocked)
        #expect(tamperedCorpus.findings.contains("external_oracle_correlation_invalid"))
        try corpusData.write(to: corpusURL, options: .atomic)

        try Data("tampered-oracle-output".utf8).write(to: oracleURL, options: .atomic)
        let tampered = await evaluator.evaluate(
            corpus: corpus,
            pdk: pdk,
            modeIDs: ["functional"],
            cornerIDs: ["typical"],
            externalOracle: TimingExternalOracleEvidence(
                oracleID: oracleTool.identifier,
                status: .available,
                executablePath: executablePath,
                version: oracleTool.version,
                details: "retained fixture"
            ),
            externalCorrelation: correlation,
            pdkEvidence: pdkEvidence,
            workspaceRoot: workspaceRoot
        )
        #expect(tampered.outcome == .blocked)
        #expect(tampered.findings.contains("external_oracle_correlation_invalid"))
    }

    @Test("external correlation evidence rejects an unbound metric-only JSON")
    func externalCorrelationRejectsUnboundJSON() throws {
        let unbound = try JSONEncoder().encode(TimingCorrelationResult(
            oracleID: "fixture-oracle",
            status: .passed,
            tolerance: 1e-15
        ))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimingExternalCorrelationReport.self, from: unbound)
        }
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
            provenance: provenance
        )
        let external = STAPayload(
            worstSetupSlack: 1e-9,
            worstHoldSlack: 2e-9,
            analyzedCorners: ["typical"],
            analyzedModes: ["functional"],
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

    @Test("external oracle request rejects obsolete schema")
    func externalOracleRequestRejectsObsoleteSchema() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "runID": "obsolete-oracle",
          "oracleID": "fixture-oracle",
          "executablePath": "/bin/cat",
          "arguments": [],
          "workingDirectory": "/tmp"
        }
        """.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimingExternalOracleRequest.self, from: data)
        }
    }
}

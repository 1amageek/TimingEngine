import CircuiteFoundation
import Foundation
import STAEngine
import Testing
import TimingCore

@Suite("Strict STA request CLI", .timeLimit(.minutes(1)))
struct STAStrictRequestCLITests {
    @Test func exactRequestExecutesStrictRCAllPGAndSavedReportsReplayThroughFreshPreparation() async throws {
        let fixture = try await STAStrictRequestCLIFixture()
        defer { remove(fixture.root) }
        let process = try TimingCLIProcessTests().runExecutable(named:"timingengine",arguments:fixture.arguments)
        try retain(fixture:fixture,output:process.standardOutput,caseID:"strict-request-success")
        #expect(process.exitCode == 0, Comment(rawValue:process.standardOutput))
        let result = try JSONDecoder().decode(STAExecutionResult.self,from:Data(process.standardOutput.utf8))
        #expect(result.status == .completed && result.inputBindings == fixture.request.artifactBindings)
        #expect(result.payload.analyzedCorners == fixture.request.requestedCornerIDs)
        #expect(result.payload.effectiveConfiguration?.requireStrictSourceEvidence == true)
        let selected = result.payload.characterization.filter(\.selected)
        #expect(selected.count == 2 && selected.allSatisfy { $0.conditionName == "tt" })
        let evidence = try #require(result.payload.sourceEvidence)
        #expect(evidence.version == 3 && evidence.normalPowerSamples.count == 6)
        #expect(evidence.normalPowerSamples.allSatisfy { $0.observation.pgValues.count == 4 && !$0.observation.functions.isEmpty })
        #expect(!evidence.pulseWidthSamples.isEmpty && !result.payload.wireObservations.isEmpty)
        #expect(result.payload.clockObservations.count == 8 && result.payload.unconstrainedEndpoints.isEmpty)
        let (engine,prepared) = try await fixture.prepared()
        let direct = try await engine.execute(prepared)
        #expect(direct.payload == result.payload)
        try await engine.validateSourceEvidence(result,against:prepared)
        let saved = try #require(result.artifactBindings.first)
        let bytes = try await FileSystemTimingArtifactReader(workspaceRoot:fixture.root).read(saved)
        let payload = try JSONDecoder().decode(STAPayload.self,from:bytes)
        #expect(payload == result.payload)
        let reloaded = try JSONDecoder().decode(STAExecutionResult.self,from:JSONEncoder().encode(result))
        let (fresh,freshPrepared) = try await fixture.prepared()
        try await fresh.validateSourceEvidence(reloaded,against:freshPrepared)
        var object = try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        var source = try #require(object["sourceEvidence"] as? [String:Any])
        var samples = try #require(source["normalPowerSamples"] as? [[String:Any]])
        var observation = try #require(samples[0]["observation"] as? [String:Any])
        var pg = try #require(observation["pgValues"] as? [[String:Any]])
        pg.removeLast(); observation["pgValues"] = pg; samples[0]["observation"] = observation
        source["normalPowerSamples"] = samples; object["sourceEvidence"] = source
        let forged = try JSONDecoder().decode(STAPayload.self,from:JSONSerialization.data(withJSONObject:object))
        let forgedResult = try STAExecutionResult(runID:result.runID,status:result.status,payload:forged,
            inputBindings:result.inputBindings,artifactBindings:result.artifactBindings,diagnostics:result.diagnostics,
            provenance:result.evidence.provenance,schemaVersion:result.schemaVersion)
        await #expect(throws:STAExecutionError.self) { try await fresh.validateSourceEvidence(forgedResult,against:freshPrepared) }
    }

    @Test(arguments:["missing-limit","oversized","duplicate","unknown","mixed","non-strict","missing-pg","wrong-pg","source-drift","partial-source","zero-source","overflow-time","small-input","small-work","nonregular","symlink"])
    func invalidTransportSourceAndResourceConditionsNeverPublish(_ failure: String) async throws {
        let fixture = try await STAStrictRequestCLIFixture()
        defer { remove(fixture.root) }
        var arguments = fixture.arguments
        func replace(_ key: String, _ value: String?) throws {
            let index = try #require(arguments.firstIndex(of:key))
            if let value { arguments[index + 1] = value }
            else { arguments.removeSubrange(index...index+1) }
        }
        switch failure {
        case "missing-limit": try replace("--maximum-request-bytes",nil)
        case "oversized": try replace("--maximum-request-bytes","1")
        case "duplicate": arguments += ["--request",fixture.root.appending(path:"request.json").path]
        case "unknown": arguments += ["--unsupported","value"]
        case "mixed": arguments += ["--design",fixture.root.appending(path:"design.json").path]
        case "partial-source": try replace("--maximum-source-work",nil)
        case "zero-source": try replace("--maximum-source-work","0")
        case "overflow-time": try replace("--source-timeout-seconds","18446744073709551615")
        case "small-input": try replace("--maximum-input-bytes","1")
        case "small-work": arguments += ["--maximum-path-work-units","1"]
        case "source-drift":
            let path = fixture.root.appending(path:"typical.lib")
            var bytes = try Data(contentsOf:path); bytes.append(0x20); try bytes.write(to:path)
        case "nonregular": try replace("--request",fixture.root.path)
        case "symlink":
            let link = fixture.root.appending(path:"request-link.json")
            try FileManager.default.createSymbolicLink(at:link,withDestinationURL:fixture.root.appending(path:"request.json"))
            try replace("--request",link.path)
        default:
            let path = fixture.root.appending(path:"request.json")
            var object = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
            if failure == "non-strict" { object["requireStrictSourceEvidence"] = false }
            else {
                var supplies = try #require(object["operatingSupplyAssumptions"] as? [[String:Any]])
                if failure == "missing-pg" { supplies.removeLast() }
                else { supplies[0]["sourcePGType"] = "wrong-source-type" }
                object["operatingSupplyAssumptions"] = supplies
            }
            try JSONSerialization.data(withJSONObject:object).write(to:path)
        }
        let process = try TimingCLIProcessTests().runExecutable(named:"timingengine",arguments:arguments)
        try retain(fixture:fixture,output:process.standardOutput,caseID:"strict-request-" + failure)
        #expect(process.exitCode != 0 && process.standardOutput.contains("error"))
        if failure == "missing-pg" { #expect(process.standardOutput.contains("missingPGValue")) }
        if failure == "wrong-pg" { #expect(process.standardOutput.contains("invalidPGCondition")) }
        #expect(!FileManager.default.fileExists(atPath:fixture.root.appending(path:"out").path))
    }

    @Test func helpListsExplicitStrictRouteAndLegacyModeRejectsRequestOnlyResources() throws {
        let helper = TimingCLIProcessTests()
        let help = try helper.runExecutable(named:"timingengine",arguments:["run-sta","--help"])
        #expect(help.exitCode == 0 && help.standardOutput.contains("--maximum-source-work"))
        let ordinary = try STAProcessCLIFixture()
        defer { remove(ordinary.root) }
        let refused = try helper.runExecutable(named:"timingengine",arguments:ordinary.arguments + ["--maximum-input-bytes","10"])
        #expect(refused.exitCode != 0 && refused.standardOutput.contains("require --request"))
        #expect(!FileManager.default.fileExists(atPath:ordinary.root.appending(path:"out").path))
    }

    private func retain(fixture: STAStrictRequestCLIFixture, output: String, caseID: String) throws {
        guard let base = ProcessInfo.processInfo.environment["TIMING_CLI_EVIDENCE_ROOT"] else { return }
        let destination = URL(fileURLWithPath:base,isDirectory:true).appending(path:caseID)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:fixture.root,to:destination)
        try Data(output.utf8).write(to:destination.appending(path:"execution-result.json"),options:.withoutOverwriting)
    }

    private func remove(_ root: URL) {
        do { try FileManager.default.removeItem(at:root) }
        catch { Issue.record("Strict CLI fixture cleanup failed: \(error)") }
    }
}

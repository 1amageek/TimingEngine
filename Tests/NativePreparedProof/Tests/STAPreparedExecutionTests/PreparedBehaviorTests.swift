import CircuiteFoundation
import CircuiteFoundationCrypto
import TimingCore
import Foundation
import STAEngine
import Testing

struct PreparedBehaviorTests {
    @Test(.timeLimit(.minutes(1))) func immutableExecutionAfterSourceMutationAndDistinctCornerDelays() async throws {
        let fixture = try PreparedFixture(); defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let engine = NativeSTAEngine(reader: fixture.reader)
        let prepared = try await engine.prepare(fixture.request(), resources: fixture.resources())
        try Data("changed".utf8).write(to: fixture.root.appending(path: "typical.lib"))
        try Data("changed".utf8).write(to: fixture.root.appending(path: "design.json"))
        async let first = engine.execute(prepared)
        async let second = engine.execute(prepared)
        let (result, repeated) = try await (first, second)
        #expect(result.payload == repeated.payload)
        #expect(result.status == .completed)
        let typical = try #require(result.payload.endpoints.first { $0.cornerID == "typical" })
        let slow = try #require(result.payload.endpoints.first { $0.cornerID == "slow" })
        let slowArrival = try #require(slow.dataArrival)
        let typicalArrival = try #require(typical.dataArrival)
        #expect(abs(slowArrival - typicalArrival - 2e-9) < 1e-15)
        #expect(result.payload.effectiveConfiguration?.digest == prepared.configurationDigest)
        #expect(result.payload.characterization.allSatisfy { !$0.selected && $0.numericProcess == 1 })
        #expect(result.schemaVersion.major == 4)
    }
    @Test(.timeLimit(.minutes(1))) func effectiveConfigurationAndExpectation() async throws {
        let fixture = try PreparedFixture(); defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let engine = NativeSTAEngine(reader: fixture.reader)
        let base = try await engine.prepare(fixture.request(), resources: fixture.resources())
        for request in [try fixture.request(maxPaths: 1), try fixture.request(variation: STAVariation(lateCellDelayScale: 2)),
                        try fixture.request(modes: ["functional"])] {
            let changed = try await engine.prepare(request, resources: fixture.resources())
            #expect(base.configurationDigest != changed.configurationDigest)
        }
        let constraints = try Data(contentsOf: fixture.root.appending(path: "constraints.sdc")) + Data("\nset_input_transition 0.2ns [all_inputs]\n".utf8)
        try constraints.write(to: fixture.root.appending(path: "slew.sdc"))
        let reference = try ArtifactReference(digest: SHA256ContentDigester().digest(data: constraints, using: .sha256), byteCount: UInt64(constraints.count),
            descriptor: fixture.constraints.descriptor)
        let binding = try TimingArtifactBinding(reference: reference, availability: .local(artifactID: reference.id,
            rootID: ArtifactRootID(rawValue: TimingArtifactBinding.workspaceRootIdentifier), relativePath: ArtifactRelativePath(segments: ["slew.sdc"])))
        let slew = try await engine.prepare(fixture.request(constraintBinding: binding), resources: fixture.resources())
        #expect(slew.configurationDigest != base.configurationDigest)
        #expect(abs(try #require(slew.effectiveConfiguration.inputSlews["default"]) - 0.2e-9) < 1e-24)
        let same = try await engine.prepare(fixture.request(expectation: base.configurationDigest), resources: fixture.resources())
        #expect(same.configurationDigest == base.configurationDigest)
        await #expect(throws: STAPreparationError.self) {
            try await engine.prepare(fixture.request(maxPaths: 1, expectation: base.configurationDigest), resources: fixture.resources())
        }
        await #expect(throws: STAPreparationError.self) {
            try await engine.prepare(fixture.request(seed: 1), resources: fixture.resources())
        }
    }
    @Test(.timeLimit(.minutes(1))) func explicitConditionSelectionAndFailure() async throws {
        let fixture = try PreparedFixture(); defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let engine = NativeSTAEngine(reader: fixture.reader)
        let bindings = ["typical", "slow"].map { STACharacterizationBinding(cornerID: $0, conditionName: "named", requiredNumericProcess: 1) }
        let selected = try await engine.prepare(fixture.request(policy: .requireObservedConditions, bindings: bindings), resources: fixture.resources())
        #expect(selected.characterization.allSatisfy { $0.selected })
        for bindings in [[], [STACharacterizationBinding(cornerID: "typical", conditionName: "missing")],
            [STACharacterizationBinding(cornerID: "typical", conditionName: "named", requiredNumericProcess: 2)]] {
            await #expect(throws: STAPreparationError.self) {
                try await engine.prepare(fixture.request(policy: .requireObservedConditions, bindings: bindings), resources: fixture.resources())
            }
        }
    }
    @Test(.timeLimit(.minutes(1))) func incompleteAndWrongObservedConditionsRefused() async throws {
        for conditions in ["operating_conditions(named) { process:1; temperature:25; }",
                           "operating_conditions(named) { process:1; voltage:2; temperature:25; }",
                           "operating_conditions(named) { process:1; voltage:1; temperature:26; }"] {
            let fixture = try PreparedFixture(conditions: conditions)
            defer { do { try fixture.remove() } catch { Issue.record(error) } }
            let engine = NativeSTAEngine(reader: fixture.reader)
            let bindings = ["typical", "slow"].map { STACharacterizationBinding(cornerID: $0, conditionName: "named") }
            await #expect(throws: STAPreparationError.self) {
                try await engine.prepare(fixture.request(policy: .requireObservedConditions, bindings: bindings), resources: fixture.resources())
            }
        }
    }
    @Test(.timeLimit(.minutes(1))) func strictBudgetsCancellationAndSchemaReader() async throws {
        let fixture = try PreparedFixture(); defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let engine = NativeSTAEngine(reader: fixture.reader)
        for resources in [
            STAExecutionResources(reader: fixture.reader, sourceLimits: try .init(maximumNestingDepth: 64),
                sourceResources: STALibertyResources(), limits: try .init(maximumInputBytes: 1)),
            STAExecutionResources(reader: fixture.reader, sourceLimits: try .init(maximumNestingDepth: 64),
                sourceResources: STALibertyResources(maximumWork: 1), limits: try .init()),
            STAExecutionResources(reader: fixture.reader, sourceLimits: try .init(maximumNestingDepth: 64),
                sourceResources: STALibertyResources(), limits: try .init(), requiresStrictTransformAccounting: true)] {
            await #expect(throws: STAPreparationError.self) {
                try await engine.prepare(fixture.request(), resources: resources)
            }
        }
        let prepared = try await engine.prepare(fixture.request(), resources: fixture.resources())
        let result = try await engine.execute(prepared)
        let bytes = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(STAExecutionResult.self, from: bytes) == result)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var version = try #require(object["schemaVersion"] as? [String: Any]); version["major"] = 3; object["schemaVersion"] = version
        let obsolete = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(STAExecutionResult.self, from: obsolete) }
        let cancelled = Task { () throws -> STAExecutionResult in
            try Task.checkCancellation(); return try await engine.execute(prepared)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled prepared execution unexpectedly completed") }
        catch { #expect(error is CancellationError || error is STAExecutionError) }
    }

}

import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import PDKCore
import PDKProfileAdmission
import STAEngine
import Synchronization
import Testing
import TimingCore
import TimingPDKProfileInspection

private final class CountingSourceParser: LibertySourceParsing {
    private let counter = Mutex(0)
    var count: Int { counter.withLock { $0 } }
    func parseSource(_ bytes: borrowing Span<UInt8>, limits: LibertySourceParseLimits,
        resources: any LibertySourceResourceAccounting) throws(LibertySourceError) -> OwnedLibertySource {
        counter.withLock { $0 += 1 }
        return try LibertyParser().parseSource(bytes, limits: limits, resources: resources)
    }
}

struct PreparedAdmissionTests {
    @Test(.timeLimit(.minutes(1))) func actualAdmissionOwnerSharedThroughPreparationAndExecution() async throws {
        let fixture = try PreparedFixture(); defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let parser = CountingSourceParser()
        let session = TimingPDKProfileInspectionSession(parser: parser, limits: try .init(maximumNestingDepth: 64))
        let admitted = try await admit(fixture, session: session)
        let catalog = try await session.retainedSources(for: admitted)
        await session.shutdown()
        #expect(parser.count == 2)
        for name in ["typical.lib", "slow.lib"] { try Data("changed".utf8).write(to: fixture.root.appending(path: name)) }
        let resources = STAExecutionResources(reader: fixture.reader, inspectedSources: catalog,
            sourceLimits: try .init(maximumNestingDepth: 64), sourceResources: STALibertyResources(), limits: try .init())
        let engine = NativeSTAEngine(reader: fixture.reader, libraryParser: parser)
        let prepared = try await engine.prepare(fixture.request(), resources: resources)
        #expect(parser.count == 2)
        #expect(prepared.libraryConsumption.allSatisfy { $0.cellNames == ["INV"] && $0.pinNames == ["INV.A", "INV.Y"] && $0.conditionNames.isEmpty })
        #expect(prepared.inspectedSources?.sourceInputs.count == admitted.sourceInputs.count)
        let result = try await engine.execute(prepared)
        #expect(result.status == .completed)
        #expect(parser.count == 2)
        let slow = try #require(result.payload.endpoints.first { $0.cornerID == "slow" }?.dataArrival)
        let typical = try #require(result.payload.endpoints.first { $0.cornerID == "typical" }?.dataArrival)
        #expect(abs(slow - typical - 2e-9) < 1e-15)
    }
    private func admit(_ fixture: PreparedFixture, session: TimingPDKProfileInspectionSession) async throws -> AdmittedPDKProfile {
        let rootID = try ArtifactRootID(rawValue: TimingArtifactBinding.workspaceRootIdentifier)
        let access = try ArtifactAccessBudget(maximumPageByteCount: 4096, maximumTotalByteCount: 10_000_000,
            maximumPageCount: 10000, maximumWorkUnitCount: 100_000_000, maximumDurationNanoseconds: 30_000_000_000)
        let budget = try PDKAdmissionBudget(limits: Dictionary(uniqueKeysWithValues:
            PDKAdmissionResourceDimension.allCases.map { ($0, UInt64(100_000_000)) }), maximumElapsedNanoseconds: 30_000_000_000)
        let definition = try PDKProfileDefinition(profileID: "timing-fixture", manifestReference: fixture.manifest.reference,
            processID: "fixture-process", version: "1", requiredCornerIDs: ["typical", "slow"],
            requirements: try ["typical", "slow"].map { id in
                try PDKViewRequirement(requirementID: id, purposeID: "sta", view: .liberty, role: .model,
                    assetIDs: [id], cornerIDs: [id], selectedSection: nil, isShared: false, allowsMultipleSources: false,
                    demandedFactKinds: ["cells", "pins", "dependencyClosure"])
            }, sources: try fixture.libraries.map {
                try PDKProfileSource(sourceKey: $0.cornerIDs[0], assetID: $0.cornerIDs[0], reference: $0.artifact.reference,
                    logicalRoutes: [$0.cornerIDs[0] + ".lib"])
            }, orderedSearchRoutes: [], dependencies: [], inspectionPolicyIdentity: "test.policy.v1",
            initialPreprocessingIdentity: "environment.empty.v1")
        let bytes = try PDKProfileCodec().encodeDefinition(definition)
        try bytes.write(to: fixture.root.appending(path: "profile.json"))
        let reference = try ArtifactReference(digest: SHA256ContentDigester().digest(data: bytes, using: .sha256), byteCount: UInt64(bytes.count),
            descriptor: ArtifactDescriptor(role: .input, kind: .report, format: .json))
        let request = PDKProfileAdmissionRequest(
            definition: .init(reference: reference, rootID: rootID, relativePath: try .init(segments: ["profile.json"]), budget: access),
            manifest: .init(reference: fixture.manifest.reference, rootID: rootID, relativePath: try .init(segments: ["pdk.json"]), budget: access),
            roots: [try .init(rootID: rootID, rootURL: fixture.root)],
            sources: try ["typical", "slow"].map {
                .init(sourceKey: $0, logicalRoute: $0 + ".lib", rootID: rootID, relativePath: try .init(segments: [$0 + ".lib"]), budget: access)
            }, budget: budget, inspectionPolicyIdentity: "test.policy.v1")
        let registration = try PDKProfileInspectorRegistration(format: .liberty, parserIdentity: TimingInspectedLibertySources.parserIdentity,
            policyIdentity: "test.policy.v1", inspector: session)
        return try await LocalPDKProfileAdmitter(inspectors: [registration]).admit(request)
    }
}

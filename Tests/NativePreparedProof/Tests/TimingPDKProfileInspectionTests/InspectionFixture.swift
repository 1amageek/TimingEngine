import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import PDKCore
import PDKProfileAdmission
import PDKSourceCapture
import TimingCore
import TimingPDKProfileInspection

struct InspectionFixture {
    let root: URL
    let request: PDKProfileAdmissionRequest
    let sourceReference: ArtifactReference
    init(demandPVT: Bool = false, library: String = "library(l) { operating_conditions(partial) { process:1; temperature:25; } cell(INV) { pin(A) { direction:input; } pin(Y) { direction:output; } } }") throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "liberty-inspection-" + UUID().uuidString)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootID = try ArtifactRootID(rawValue: UUID().uuidString)
        let access = try ArtifactAccessBudget(maximumPageByteCount: 4096, maximumTotalByteCount: 10_000_000,
            maximumPageCount: 10000, maximumWorkUnitCount: 100_000_000, maximumDurationNanoseconds: 30_000_000_000)
        let budget = try PDKAdmissionBudget(limits: Dictionary(uniqueKeysWithValues:
            PDKAdmissionResourceDimension.allCases.map { ($0, UInt64(100_000_000)) }), maximumElapsedNanoseconds: 30_000_000_000)
        func write(_ bytes: Data, _ path: String, _ kind: ArtifactKind, _ format: ArtifactFormat) throws -> ArtifactReference {
            try bytes.write(to: root.appending(path: path))
            return try .init(digest: SHA256ContentDigester().digest(data: bytes, using: .sha256), byteCount: UInt64(bytes.count),
                descriptor: ArtifactDescriptor(role: .input, kind: kind, format: format))
        }
        let source = try write(Data(library.utf8), "library.lib", .model, .liberty)
        sourceReference = source
        let pdk = PDKManifest(processID: "p", version: "1", assets: [
            .init(assetID: "lib", role: .model, path: "library.lib", kind: .model, format: .liberty,
                  sha256: source.digest.hexadecimalValue, byteCount: Int64(source.byteCount))],
            crossViewMappings: [.init(mappingID: "lib", view: .liberty, assetID: "lib", logicalNames: ["INV"])])
        let manifest = try write(PDKManifestCodec.encode(pdk), "pdk.json", .technology, .json)
        let definition = try PDKProfileDefinition(profileID: "fixture", manifestReference: manifest, processID: "p", version: "1",
            requiredCornerIDs: [], requirements: [try .init(requirementID: "timing", purposeID: "sta", view: .liberty,
                role: .model, assetIDs: ["lib"], cornerIDs: [], selectedSection: nil, isShared: true,
                allowsMultipleSources: false, demandedFactKinds: demandPVT ? ["cells", "sourcePVT"] : ["cells", "pins", "dependencyClosure"])],
            sources: [try .init(sourceKey: "lib", assetID: "lib", reference: source, logicalRoutes: ["library.lib"])],
            orderedSearchRoutes: [], dependencies: [], inspectionPolicyIdentity: "test.policy.v1", initialPreprocessingIdentity: "environment.empty.v1")
        let profile = try write(PDKProfileCodec().encodeDefinition(definition), "profile.json", .report, .json)
        request = .init(definition: .init(reference: profile, rootID: rootID, relativePath: try .init(segments: ["profile.json"]), budget: access),
            manifest: .init(reference: manifest, rootID: rootID, relativePath: try .init(segments: ["pdk.json"]), budget: access),
            roots: [try .init(rootID: rootID, rootURL: root)],
            sources: [.init(sourceKey: "lib", logicalRoute: "library.lib", rootID: rootID,
                relativePath: try .init(segments: ["library.lib"]), budget: access)], budget: budget, inspectionPolicyIdentity: "test.policy.v1")
    }
    func admit(_ session: TimingPDKProfileInspectionSession, resources: (any PDKAdmissionResourceAccounting)? = nil) async throws -> AdmittedPDKProfile {
        let registration = try PDKProfileInspectorRegistration(format: .liberty,
            parserIdentity: TimingInspectedLibertySources.parserIdentity, policyIdentity: "test.policy.v1", inspector: session)
        let admitter = LocalPDKProfileAdmitter(inspectors: [registration])
        if let resources { return try await admitter.admit(request, resources: resources) }
        return try await admitter.admit(request)
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
}

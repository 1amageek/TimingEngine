import CircuiteFoundation
import Foundation
import PDKCore
import TimingCore
import TimingPDKProfileInspection

struct STATimingProcessInputs: Sendable {
    let librariesByCorner: [String: TimingLibrary]
    let selection: STAProcessSelection
    let sourcesByCorner: [String: OwnedLibertySource]

    static func load(
        _ request: STARequest,
        reader: any TimingArtifactReading,
        parser: any LibertySourceParsing,
        resources: STAExecutionResources
    ) async throws -> Self {
        guard request.pdkManifest.descriptor.role == .input,
              request.pdkManifest.descriptor.format == .json,
              request.pdkManifest.digest.algorithm == .sha256 else {
            throw TimingError.invalidInput("STA requires an input-role SHA-256 JSON process manifest.")
        }
        guard request.pdkManifest.byteCount <= resources.limits.maximumInputBytes else { throw STAPreparationError.capacity("Manifest input exceeds native transform byte ceiling") }
        let data = try await reader.read(request.pdkManifest)
        let manifest: PDKManifest
        do { manifest = try PDKManifestCodec.decode(data: data) }
        catch {
            throw TimingError.parseFailure(format: "PDK manifest", line: 1, message: error.localizedDescription)
        }
        guard manifest.validate().isValid else {
            throw TimingError.invalidInput("STA process manifest semantic validation failed.")
        }
        guard manifest.processID == request.processID, manifest.version == request.pdkVersion else {
            throw TimingError.invalidInput("STA process or PDK version does not match the retained manifest.")
        }
        guard !request.requestedCornerIDs.isEmpty else {
            throw TimingError.invalidInput("STA requires explicit requested corner identities.")
        }
        let corners = Dictionary(uniqueKeysWithValues: manifest.corners.map { ($0.cornerID, $0) })
        let assets = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.assetID, $0) })
        var libraries: [String: TimingLibrary] = [:]
        var references: [String: ArtifactReference] = [:]
        var sources: [String: OwnedLibertySource] = [:]
        for reference in request.libraries {
            try Task.checkCancellation()
            guard !reference.cornerIDs.isEmpty,
                  Set(reference.cornerIDs).count == reference.cornerIDs.count,
                  reference.artifact.descriptor.role == .input,
                  reference.artifact.descriptor.format == .liberty,
                  reference.artifact.digest.algorithm == .sha256 else {
                throw TimingError.invalidInput("STA Liberty inputs require explicit unique corners and input-role SHA-256 Liberty bindings.")
            }
            for cornerID in reference.cornerIDs {
                guard let corner = corners[cornerID],
                      !corner.cornerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !corner.pvt.process.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      corner.pvt.voltage.isFinite, corner.pvt.voltage > 0,
                      corner.pvt.temperatureCelsius.isFinite else {
                    throw TimingError.invalidInput("STA corner '\(cornerID)' is absent or has invalid PVT semantics.")
                }
                guard let assetID = corner.viewMappings["liberty"],
                      corner.assetIDs.contains(assetID), let asset = assets[assetID],
                      asset.format == .liberty, asset.cornerIDs.contains(cornerID),
                      manifest.crossViewMappings.contains(where: {
                          $0.view == .liberty && $0.assetID == assetID && $0.cornerIDs.contains(cornerID)
                      }) else {
                    throw TimingError.invalidInput("STA corner '\(cornerID)' requires an explicit manifest Liberty asset and cross-view mapping.")
                }
                guard asset.sha256?.lowercased() == reference.artifact.digest.hexadecimalValue,
                      asset.byteCount.flatMap(UInt64.init(exactly:)) == reference.artifact.byteCount else {
                    throw TimingError.invalidInput("STA corner '\(cornerID)' Liberty digest or byte count does not match the manifest asset.")
                }
                guard references[cornerID] == nil else {
                    throw TimingError.invalidInput("STA corner '\(cornerID)' has ambiguous supplied Liberty inputs.")
                }
                references[cornerID] = reference.artifact.reference
            }
            let source: OwnedLibertySource
            if let catalog = resources.inspectedSources {
                source = try catalog.source(for: reference.artifact.reference)
            } else {
                guard reference.artifact.byteCount <= resources.limits.maximumInputBytes else { throw STAPreparationError.capacity("Liberty input exceeds native byte ceiling") }
                let bytes = try await reader.read(reference.artifact)
                source = try bytes.withUnsafeBytes { raw in
                    let expected = raw.bindMemory(to: UInt8.self)
                    let parsed = try parser.parseSource(expected.span,
                        limits: resources.sourceLimits, resources: resources.sourceResources)
                    try resources.sourceResources.chargeWork(UInt64(expected.count))
                    guard parsed.byteCount == expected.count else { throw TimingError.invalidInput("Owned Liberty parse replaced source bytes") }
                    let matches = parsed.withBytes { actual in
                        for index in 0..<actual.count { if actual[index] != expected[index] { return false } }
                        return true
                    }
                    guard matches else { throw TimingError.invalidInput("Owned Liberty parse replaced source bytes") }
                    return parsed
                }
            }
            guard UInt64(source.byteCount) == reference.artifact.byteCount else {
                throw TimingError.invalidInput("Owned Liberty parse has a different source byte count")
            }
            for cornerID in reference.cornerIDs { libraries[cornerID] = source.library; sources[cornerID] = source }
        }
        var selectedCorners: [PDKCornerDefinition] = []
        var selectedLibraries: [String: TimingLibrary] = [:]
        var selectedReferences: [String: ArtifactReference] = [:]
        for cornerID in request.requestedCornerIDs {
            guard let corner = corners[cornerID], let library = libraries[cornerID],
                  let reference = references[cornerID] else {
                throw TimingError.invalidInput("Requested STA corner '\(cornerID)' has no exact supplied manifest-mapped Liberty input.")
            }
            selectedCorners.append(corner)
            selectedLibraries[cornerID] = library
            selectedReferences[cornerID] = reference
        }
        return Self(
            librariesByCorner: selectedLibraries,
            selection: STAProcessSelection(
                processID: manifest.processID,
                pdkVersion: manifest.version,
                manifest: request.pdkManifest.reference,
                corners: selectedCorners,
                librariesByCorner: selectedReferences
            ),
            sourcesByCorner: sources.filter { request.requestedCornerIDs.contains($0.key) }
        )
    }
}

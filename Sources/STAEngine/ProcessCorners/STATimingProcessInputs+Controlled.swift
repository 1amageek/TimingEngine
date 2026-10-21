import CircuiteFoundation
import Foundation
import PDKCore
import PDKDiscovery
import TimingCore

extension STATimingProcessInputs {
    static func loadControlled(_ request: STARequest, reader: any TimingArtifactReading,
        parser: any LibertySourceParsing, resources: STAExecutionResources) async throws -> Self {
        let sourceResources = try TimingCheckedSourceResources(resources.sourceResources)
        let budget = NativeSTAStateBudget(maximum: resources.limits.maximumPathStates, transformResources: sourceResources)
        let retained = NativeSTATransformStorage(budget: budget, kind: .liveOwnedBytes)
        let temporary = NativeSTATransformStorage(budget: budget, kind: .temporaryBytes)
        guard request.pdkManifest.descriptor.role == .input,
              request.pdkManifest.descriptor.format == .json,
              request.pdkManifest.digest.algorithm == .sha256 else {
            throw TimingError.invalidInput("STA requires an input-role SHA-256 JSON process manifest.")
        }
        guard request.pdkManifest.byteCount <= resources.limits.maximumInputBytes else {
            throw STAPreparationError.capacity("Manifest input exceeds native transform byte ceiling")
        }
        let read = try await reader.read(request.pdkManifest, resources: sourceResources)
        let accounting = try NativeSTAPDKAccounting(resources: sourceResources,
            maximumNesting: resources.sourceLimits.maximumNestingDepth)
        let document: PDKControlledManifest
        do {
            document = try read.data.withUnsafeBytes { raw in
                try NativePDKBoundedDocumentDecoder().decodeAndValidateManifest(
                    bytes: raw.bindMemory(to: UInt8.self).span, accounting: accounting)
            }
        } catch { throw accounting.preservingCause(error) }
        try sourceResources.check()
        try retained.hold(document)
        let manifest = document.manifest
        let diagnostics = try TimingControlledDiagnostics(resources: sourceResources, retaining: document)
        guard document.validation.isValid else { throw TimingError.invalidInput("STA process manifest semantic validation failed.") }
        guard manifest.processID == request.processID, manifest.version == request.pdkVersion else {
            throw TimingError.invalidInput("STA process or PDK version does not match the retained manifest.")
        }
        guard !request.requestedCornerIDs.isEmpty else { throw TimingError.invalidInput("STA requires explicit requested corner identities.") }
        try temporary.reserveDictionary(String.self, PDKCornerDefinition.self, capacity: manifest.corners.count)
        try temporary.reserveDictionary(String.self, PDKAssetReference.self, capacity: manifest.assets.count)
        var corners: [String:PDKCornerDefinition] = [:]; corners.reserveCapacity(manifest.corners.count)
        var assets: [String:PDKAssetReference] = [:]; assets.reserveCapacity(manifest.assets.count)
        for corner in manifest.corners { try budget.chargeScheduledWork(1); corners[corner.cornerID] = corner }
        for asset in manifest.assets { try budget.chargeScheduledWork(1); assets[asset.assetID] = asset }
        // Every supplied corner mapping originates in a concrete reference row.
        var suppliedCount = 0
        for reference in request.libraries {
            try budget.chargeScheduledWork(1)
            let sum = suppliedCount.addingReportingOverflow(reference.cornerIDs.count)
            guard !sum.overflow else { throw LibertySourceError.arithmeticOverflow }
            suppliedCount = sum.partialValue
        }
        try temporary.reserveDictionary(String.self, ArtifactReference.self, capacity: suppliedCount)
        try temporary.reserveDictionary(String.self, OwnedLibertySource.self, capacity: suppliedCount)
        var references: [String:ArtifactReference] = [:]; references.reserveCapacity(suppliedCount)
        var sources: [String:OwnedLibertySource] = [:]; sources.reserveCapacity(suppliedCount)
        for reference in request.libraries {
            try Task.checkCancellation(); try sourceResources.check()
            let uniqueLease = try sourceResources.reserveStorage(kind: .temporaryBytes,
                byteCount: TimingTransformCapacity.set(String.self, minimumCapacity: reference.cornerIDs.count))
            var unique: Set<String> = []; unique.reserveCapacity(reference.cornerIDs.count)
            for corner in reference.cornerIDs { try budget.chargeScheduledWork(1); unique.insert(corner) }
            guard !reference.cornerIDs.isEmpty, unique.count == reference.cornerIDs.count,
                  reference.artifact.descriptor.role == .input,
                  reference.artifact.descriptor.format == .liberty,
                  reference.artifact.digest.algorithm == .sha256 else {
                throw TimingError.invalidInput("STA Liberty inputs require explicit unique corners and input-role SHA-256 Liberty bindings.")
            }
            for cornerID in reference.cornerIDs {
                try budget.chargeScheduledWork(UInt64(cornerID.utf8.count))
                guard let corner = corners[cornerID] else {
                    throw try diagnostics.sourceFailure(utf8ByteCount: TimingDiagnosticTextCapacity.description(
                        literal: "STA corner '' is absent or has invalid PVT semantics.", ints: 0, doubles: 0, booleans: 0,
                        additionalUTF8: UInt64(cornerID.utf8.count))) {
                            TimingError.invalidInput("STA corner '\(cornerID)' is absent or has invalid PVT semantics.")
                        }
                }
                try budget.chargeScheduledWork(UInt64(corner.cornerID.utf8.count))
                try budget.chargeScheduledWork(UInt64(corner.pvt.process.name.utf8.count))
                guard corner.cornerID.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
                      corner.pvt.process.name.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
                      corner.pvt.voltage.isFinite, corner.pvt.voltage > 0, corner.pvt.temperatureCelsius.isFinite else {
                    throw try diagnostics.sourceFailure(utf8ByteCount: TimingDiagnosticTextCapacity.description(
                        literal: "STA corner '' is absent or has invalid PVT semantics.", ints: 0, doubles: 0, booleans: 0,
                        additionalUTF8: UInt64(cornerID.utf8.count))) {
                            TimingError.invalidInput("STA corner '\(cornerID)' is absent or has invalid PVT semantics.")
                        }
                }
                try budget.chargeScheduledWork(UInt64(corner.assetIDs.count))
                try budget.chargeScheduledWork(UInt64(manifest.crossViewMappings.count))
                guard let assetID = corner.viewMappings["liberty"], corner.assetIDs.contains(assetID),
                      let asset = assets[assetID], asset.format == .liberty,
                      asset.cornerIDs.contains(cornerID), manifest.crossViewMappings.contains(where: {
                          $0.view == .liberty && $0.assetID == assetID && $0.cornerIDs.contains(cornerID)
                      }) else {
                    throw try diagnostics.sourceFailure(utf8ByteCount: TimingDiagnosticTextCapacity.description(
                        literal: "STA corner '' requires an explicit manifest Liberty asset and cross-view mapping.", ints: 0, doubles: 0, booleans: 0,
                        additionalUTF8: UInt64(cornerID.utf8.count))) {
                            TimingError.invalidInput("STA corner '\(cornerID)' requires an explicit manifest Liberty asset and cross-view mapping.")
                        }
                }
                try budget.chargeScheduledWork(UInt64(asset.cornerIDs.count))
                if let digest = asset.sha256 { try budget.chargeScheduledWork(UInt64(digest.utf8.count)) }
                guard asset.sha256?.caseInsensitiveCompare(reference.artifact.digest.hexadecimalValue) == .orderedSame,
                      asset.byteCount.flatMap(UInt64.init(exactly:)) == reference.artifact.byteCount else {
                    throw try diagnostics.sourceFailure(utf8ByteCount: TimingDiagnosticTextCapacity.description(
                        literal: "STA corner '' Liberty digest or byte count does not match the manifest asset.", ints: 0, doubles: 0, booleans: 0,
                        additionalUTF8: UInt64(cornerID.utf8.count))) {
                            TimingError.invalidInput("STA corner '\(cornerID)' Liberty digest or byte count does not match the manifest asset.")
                        }
                }
                guard references[cornerID] == nil else { throw try diagnostics.sourceFailure(utf8ByteCount: TimingDiagnosticTextCapacity.description(
                        literal: "STA corner '' has ambiguous supplied Liberty inputs.", ints: 0, doubles: 0, booleans: 0,
                        additionalUTF8: UInt64(cornerID.utf8.count))) {
                            TimingError.invalidInput("STA corner '\(cornerID)' has ambiguous supplied Liberty inputs.")
                        } }
                references[cornerID] = reference.artifact.reference
            }
            let source: OwnedLibertySource
            if let catalog = resources.inspectedSources { source = try catalog.source(for: reference.artifact.reference) }
            else {
                guard reference.artifact.byteCount <= resources.limits.maximumInputBytes else {
                    throw STAPreparationError.capacity("Liberty input exceeds native byte ceiling")
                }
                let bytes = try await reader.read(reference.artifact, resources: sourceResources)
                source = try bytes.data.withUnsafeBytes { raw in
                    let expected = raw.bindMemory(to: UInt8.self)
                    let parsed = try parser.parseSource(expected.span, limits: resources.sourceLimits, resources: sourceResources)
                    try budget.chargeScheduledWork(UInt64(expected.count))
                    guard parsed.byteCount == expected.count else { throw TimingError.invalidInput("Owned Liberty parse replaced source bytes") }
                    let matches = parsed.withBytes { actual in
                        for index in 0..<actual.count { if actual[index] != expected[index] { return false } }
                        return true
                    }
                    guard matches else { throw TimingError.invalidInput("Owned Liberty parse replaced source bytes") }
                    return parsed
                }
                withExtendedLifetime(bytes) {}
            }
            guard UInt64(source.byteCount) == reference.artifact.byteCount else {
                throw TimingError.invalidInput("Owned Liberty parse has a different source byte count")
            }
            for cornerID in reference.cornerIDs { try budget.chargeScheduledWork(1); sources[cornerID] = source }
            withExtendedLifetime(uniqueLease) {}
        }
        try retained.reserve(PDKCornerDefinition.self, capacity: request.requestedCornerIDs.count)
        try retained.reserveDictionary(String.self, TimingLibrary.self, capacity: request.requestedCornerIDs.count)
        try retained.reserveDictionary(String.self, ArtifactReference.self, capacity: request.requestedCornerIDs.count)
        try retained.reserveDictionary(String.self, OwnedLibertySource.self, capacity: request.requestedCornerIDs.count)
        var selectedCorners: [PDKCornerDefinition] = []; selectedCorners.reserveCapacity(request.requestedCornerIDs.count)
        var libraries: [String:TimingLibrary] = [:]; libraries.reserveCapacity(request.requestedCornerIDs.count)
        var selectedReferences: [String:ArtifactReference] = [:]; selectedReferences.reserveCapacity(request.requestedCornerIDs.count)
        var selectedSources: [String:OwnedLibertySource] = [:]; selectedSources.reserveCapacity(request.requestedCornerIDs.count)
        for cornerID in request.requestedCornerIDs {
            try budget.chargeScheduledWork(1)
            guard let corner = corners[cornerID], let source = sources[cornerID], let reference = references[cornerID] else {
                throw try diagnostics.sourceFailure(utf8ByteCount: TimingDiagnosticTextCapacity.description(
                        literal: "Requested STA corner '' has no exact supplied manifest-mapped Liberty input.", ints: 0, doubles: 0, booleans: 0,
                        additionalUTF8: UInt64(cornerID.utf8.count))) {
                            TimingError.invalidInput("Requested STA corner '\(cornerID)' has no exact supplied manifest-mapped Liberty input.")
                        }
            }
            selectedCorners.append(corner); libraries[cornerID] = source.library
            selectedReferences[cornerID] = reference; selectedSources[cornerID] = source
        }
        var result = Self(librariesByCorner: libraries, selection: STAProcessSelection(processID: manifest.processID,
            pdkVersion: manifest.version, manifest: request.pdkManifest.reference, corners: selectedCorners,
            librariesByCorner: selectedReferences), sourcesByCorner: selectedSources)
        result.transformRetention = try retained.finish()
        withExtendedLifetime((temporary, read)) {}
        return result
    }
}

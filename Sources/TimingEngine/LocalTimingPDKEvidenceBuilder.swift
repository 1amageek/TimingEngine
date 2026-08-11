import CryptoKit
import CircuiteFoundation
import Foundation
import PDKCore
import TimingCore

public struct LocalTimingPDKEvidenceBuilder: TimingPDKEvidenceBuilding {
    public let workspaceRoot: URL?

    public init(workspaceRoot: URL? = nil) {
        self.workspaceRoot = workspaceRoot?.standardizedFileURL
    }

    public func build(for pdk: TimingPDKReference) async throws -> TimingPDKEvidence {
        let manifestURL: URL
        do {
            manifestURL = try pdk.manifest.localFileURL(relativeTo: workspaceRoot)
        } catch {
            throw TimingError.artifactReadFailed(
                path: pdk.manifest.materializationDescription,
                message: error.localizedDescription
            )
        }
        let manifestData: Data
        do {
            manifestData = try await FileSystemTimingArtifactReader(
                workspaceRoot: workspaceRoot
            ).read(pdk.manifest)
        } catch {
            throw TimingError.artifactReadFailed(path: manifestURL.path(percentEncoded: false), message: error.localizedDescription)
        }
        let manifest: PDKManifest
        do {
            manifest = try PDKManifestCodec.decode(data: manifestData)
        } catch {
            throw TimingError.parseFailure(format: "PDK manifest", line: 1, message: error.localizedDescription)
        }

        let manifestDigest = digest(manifestData)
        var findings: [String] = []
        if pdk.manifest.digest.hexadecimalValue.caseInsensitiveCompare(manifestDigest) != .orderedSame {
            findings.append("pdk_manifest_digest_mismatch")
        }
        if pdk.digest.hexadecimalValue.caseInsensitiveCompare(manifestDigest) != .orderedSame {
            findings.append("pdk_reference_digest_mismatch")
        }
        if pdk.processID != manifest.processID { findings.append("pdk_process_mismatch") }
        if pdk.version != manifest.version { findings.append("pdk_version_mismatch") }
        let manifestReport = manifest.validate()
        if !manifestReport.isValid { findings.append("pdk_manifest_invalid") }

        let rootURL = manifestURL
            .deletingLastPathComponent()
            .standardizedFileURL
        let assetReader = FileSystemTimingArtifactReader(workspaceRoot: rootURL)
        let referenceBuilder = TimingArtifactReferenceBuilder()
        var assets: [TimingPDKAssetEvidence] = []
        for asset in manifest.assets.sorted(by: { $0.assetID < $1.assetID }) {
            let relativePath: ArtifactRelativePath
            do {
                guard !asset.path.hasPrefix("/") else {
                    throw TimingError.invalidInput("PDK asset paths must be relative.")
                }
                relativePath = try ArtifactRelativePath(
                    segments: asset.path.split(separator: "/").map(String.init)
                )
            } catch {
                findings.append("pdk_asset_unsafe_path:\(asset.assetID)")
                assets.append(TimingPDKAssetEvidence(
                    assetID: asset.assetID,
                    relativePath: asset.path,
                    format: asset.format.rawValue,
                    required: asset.required,
                    present: false,
                    declaredDigest: asset.sha256
                ))
                continue
            }
            let assetURL = relativePath.segments.reduce(rootURL) { partial, segment in
                partial.appending(path: segment)
            }
            guard FileManager.default.fileExists(atPath: assetURL.path(percentEncoded: false)) else {
                if asset.required { findings.append("pdk_required_asset_missing:\(asset.assetID)") }
                assets.append(TimingPDKAssetEvidence(
                    assetID: asset.assetID,
                    relativePath: asset.path,
                    format: asset.format.rawValue,
                    required: asset.required,
                    present: false,
                    declaredDigest: asset.sha256
                ))
                continue
            }
            let data: Data
            do {
                let binding = try referenceBuilder.makeBinding(
                    at: assetURL,
                    relativeTo: rootURL,
                    kind: asset.kind,
                    format: asset.format
                )
                data = try await assetReader.read(binding)
            } catch {
                if let timingError = error as? TimingError,
                   case .invalidInput = timingError {
                    findings.append("pdk_asset_unsafe_path:\(asset.assetID)")
                } else if asset.required {
                    findings.append("pdk_required_asset_unreadable:\(asset.assetID)")
                }
                assets.append(TimingPDKAssetEvidence(
                    assetID: asset.assetID,
                    relativePath: asset.path,
                    format: asset.format.rawValue,
                    required: asset.required,
                    present: false,
                    declaredDigest: asset.sha256
                ))
                continue
            }
            let observedDigest = digest(data)
            if let declaredDigest = asset.sha256,
               declaredDigest.caseInsensitiveCompare(observedDigest) != .orderedSame {
                findings.append("pdk_asset_digest_mismatch:\(asset.assetID)")
            }
            if let declaredByteCount = asset.byteCount,
               declaredByteCount != Int64(data.count) {
                findings.append("pdk_asset_byte_count_mismatch:\(asset.assetID)")
            }
            assets.append(TimingPDKAssetEvidence(
                assetID: asset.assetID,
                relativePath: asset.path,
                format: asset.format.rawValue,
                required: asset.required,
                present: true,
                declaredDigest: asset.sha256,
                observedDigest: observedDigest,
                byteCount: Int64(data.count)
            ))
        }

        return TimingPDKEvidence(
            processID: manifest.processID,
            version: manifest.version,
            manifestDigest: manifestDigest,
            cornerIDs: manifest.corners.map(\.cornerID).sorted(),
            assets: assets,
            findings: findings
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

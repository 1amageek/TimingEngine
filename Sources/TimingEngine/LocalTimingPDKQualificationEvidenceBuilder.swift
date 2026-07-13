import CryptoKit
import CircuiteFoundation
import Foundation
import PDKCore
import TimingCore

public struct LocalTimingPDKQualificationEvidenceBuilder: TimingPDKQualificationEvidenceBuilding {
    public let workspaceRoot: URL?

    public init(workspaceRoot: URL? = nil) {
        self.workspaceRoot = workspaceRoot?.standardizedFileURL
    }

    public func build(for pdk: TimingPDKReference) throws -> TimingPDKQualificationEvidence {
        let manifestURL: URL
        do {
            manifestURL = try pdk.manifest.locator.location.resolvedFileURL(
                relativeTo: workspaceRoot
            )
        } catch {
            throw TimingError.artifactReadFailed(
                path: pdk.manifest.locator.location.value,
                message: error.localizedDescription
            )
        }
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw TimingError.artifactReadFailed(path: manifestURL.path(percentEncoded: false), message: error.localizedDescription)
        }
        let manifest: PDKManifest
        do {
            manifest = try PDKManifestCodec.decode(data: manifestData).manifest
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
            .resolvingSymlinksInPath()
        var assets: [TimingPDKAssetEvidence] = []
        for asset in manifest.assets.sorted(by: { $0.assetID < $1.assetID }) {
            let assetURL = rootURL
                .appending(path: asset.path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            guard assetURL.path == rootURL.path || assetURL.path.hasPrefix(rootPath) else {
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
                data = try Data(contentsOf: assetURL)
            } catch {
                if asset.required { findings.append("pdk_required_asset_unreadable:\(asset.assetID)") }
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

        let blockingFindings = findings.filter {
            !$0.hasPrefix("pdk_optional_asset_missing:")
        }
        return TimingPDKQualificationEvidence(
            processID: manifest.processID,
            version: manifest.version,
            manifestDigest: manifestDigest,
            manifestIsValid: manifestReport.isValid,
            cornerIDs: manifest.corners.map(\.cornerID).sorted(),
            assets: assets,
            findings: findings,
            isComplete: blockingFindings.isEmpty && assets.filter(\.required).allSatisfy(\.isVerified)
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

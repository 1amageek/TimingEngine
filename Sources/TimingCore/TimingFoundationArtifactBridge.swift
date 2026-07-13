import CircuiteFoundation
import Foundation
import XcircuitePackage

/// Converts the existing project artifact model at the explicit timing
/// migration boundary. Foundation references are always verified values;
/// legacy references are used only to invoke existing Xcircuite adapters.
public struct TimingFoundationArtifactBridge: Sendable {
    public init() {}

    public func legacyReference(
        from reference: ArtifactReference,
        kind: XcircuiteFileKind,
        format: XcircuiteFileFormat,
        runID: String,
        workspaceRoot: URL?
    ) throws -> XcircuiteFileReference {
        guard reference.digest.algorithm == .sha256 else {
            throw TimingFoundationBoundaryError.unsupportedDigestAlgorithm(
                reference.digest.algorithm.rawValue
            )
        }
        let url = try resolvedURL(for: reference, workspaceRoot: workspaceRoot)
        guard let byteCount = Int64(exactly: reference.byteCount) else {
            throw TimingFoundationBoundaryError.byteCountOutOfRange(
                reference.locator.location.value
            )
        }
        return XcircuiteFileReference(
            artifactID: reference.id.rawValue,
            path: url.path(percentEncoded: false),
            kind: kind,
            format: format,
            sha256: reference.digest.hexadecimalValue,
            byteCount: byteCount,
            producedByRunID: runID
        )
    }

    public func foundationReference(
        from reference: XcircuiteFileReference,
        defaultKind: ArtifactKind,
        defaultFormat: ArtifactFormat,
        producer: ProducerIdentity?
    ) throws -> ArtifactReference {
        guard let sha256 = reference.sha256, !sha256.isEmpty else {
            throw TimingFoundationBoundaryError.missingArtifactDigest(reference.path)
        }
        guard let byteCount = reference.byteCount, byteCount >= 0 else {
            throw TimingFoundationBoundaryError.byteCountOutOfRange(reference.path)
        }
        let digest: ContentDigest
        do {
            digest = try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: sha256
            )
        } catch {
            throw TimingFoundationBoundaryError.invalidArtifactDigest(reference.path)
        }
        let location: ArtifactLocation
        do {
            if reference.path.hasPrefix("/") {
                location = try ArtifactLocation(fileURL: URL(filePath: reference.path))
            } else {
                location = try ArtifactLocation(workspaceRelativePath: reference.path)
            }
        } catch {
            throw TimingFoundationBoundaryError.invalidArtifactLocation(
                reference.path,
                reason: error.localizedDescription
            )
        }
        let kind = try foundationKind(
            for: reference.kind,
            fallback: defaultKind
        )
        let format = try foundationFormat(
            for: reference.format,
            fallback: defaultFormat
        )
        return ArtifactReference(
            id: try foundationID(for: reference, digest: digest),
            locator: ArtifactLocator(
                location: location,
                kind: kind,
                format: format
            ),
            digest: digest,
            byteCount: UInt64(byteCount),
            producer: producer
        )
    }

    public func foundationDiagnostic(
        from diagnostic: XcircuiteEngineDiagnostic,
        namespace: String = "timing",
        subjectKind: DesignObjectKind? = nil
    ) throws -> DesignDiagnostic {
        let diagnosticCode = try makeDiagnosticCode(
            diagnostic.code,
            namespace: namespace
        )
        var detail: String?
        var subject: DesignObjectReference?
        if let entity = diagnostic.entity, !entity.isEmpty {
            do {
                if let subjectKind {
                    subject = try DesignObjectReference(
                        kind: subjectKind,
                        identifier: entity
                    )
                }
            } catch {
                detail = "entity=\(entity); subjectError=\(error.localizedDescription)"
            }
        }
        let actions = diagnostic.suggestedActions.map { action in
            SuggestedAction(
                code: "\(namespace).action.\(token(action))",
                summary: action
            )
        }
        if subject == nil, let entity = diagnostic.entity, !entity.isEmpty {
            detail = detail ?? "entity=\(entity)"
        }
        return DesignDiagnostic(
            code: diagnosticCode,
            severity: foundationSeverity(for: diagnostic.severity),
            summary: diagnostic.message,
            detail: detail,
            subject: subject,
            suggestedActions: actions
        )
    }

    private func resolvedURL(
        for reference: ArtifactReference,
        workspaceRoot: URL?
    ) throws -> URL {
        do {
            return try reference.locator.location.resolvedFileURL(
                relativeTo: workspaceRoot
            )
        } catch ArtifactLocationError.missingWorkspaceRoot {
            throw TimingFoundationBoundaryError.workspaceRootRequired(
                reference.locator.location.value
            )
        } catch {
            throw TimingFoundationBoundaryError.invalidArtifactLocation(
                reference.locator.location.value,
                reason: error.localizedDescription
            )
        }
    }

    private func foundationID(
        for reference: XcircuiteFileReference,
        digest: ContentDigest
    ) throws -> ArtifactID {
        if let artifactID = reference.artifactID, !artifactID.isEmpty {
            do {
                return try ArtifactID(rawValue: artifactID)
            } catch {
                throw TimingFoundationBoundaryError.invalidArtifactIdentity(artifactID)
            }
        }
        let seed = "\(reference.artifactID ?? "")|\(reference.path)|\(digest.hexadecimalValue)"
        let identityDigest: ContentDigest
        do {
            identityDigest = try SHA256ContentDigester().digest(
                data: Data(seed.utf8),
                using: .sha256
            )
        } catch {
            throw TimingFoundationBoundaryError.invalidArtifactIdentity(seed)
        }
        do {
            return try ArtifactID(
                rawValue: "timing-artifact-\(identityDigest.hexadecimalValue)"
            )
        } catch {
            throw TimingFoundationBoundaryError.invalidArtifactIdentity(seed)
        }
    }

    private func foundationKind(
        for kind: XcircuiteFileKind,
        fallback: ArtifactKind
    ) throws -> ArtifactKind {
        switch kind {
        case .constraint:
            return .constraints
        case .netlist:
            return .netlist
        case .parasitic:
            return .parasitics
        case .technology:
            return .technology
        case .report:
            return .report
        case .timingLibrary:
            return try ArtifactKind(rawValue: "timing.library")
        default:
            return fallback
        }
    }

    private func foundationFormat(
        for format: XcircuiteFileFormat,
        fallback: ArtifactFormat
    ) throws -> ArtifactFormat {
        switch format {
        case .json:
            return .json
        case .liberty:
            return .liberty
        case .sdc:
            return try ArtifactFormat(rawValue: "sdc")
        case .sdf:
            return .sdf
        case .spef:
            return .spef
        case .verilog:
            return .verilog
        case .systemVerilog:
            return .systemVerilog
        case .spice:
            return .spice
        case .gdsii:
            return .gdsii
        case .oasis:
            return .oasis
        case .lef:
            return .lef
        case .def:
            return .def
        case .dspf:
            return .dspf
        case .vcd:
            return .vcd
        default:
            let rawValue = format.rawValue
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !rawValue.isEmpty, rawValue != "unknown" else {
                return fallback
            }
            do {
                return try ArtifactFormat(rawValue: rawValue)
            } catch {
                throw TimingFoundationBoundaryError.unsupportedArtifactFormat(
                    format.rawValue
                )
            }
        }
    }

    private func makeDiagnosticCode(
        _ code: String,
        namespace: String
    ) throws -> DiagnosticCode {
        let normalized = token(code)
        let rawValue = normalized.isEmpty ? "\(namespace).execution" : "\(namespace).\(normalized)"
        do {
            return try DiagnosticCode(rawValue: rawValue)
        } catch {
            throw TimingFoundationBoundaryError.invalidDiagnosticCode(rawValue)
        }
    }

    private func foundationSeverity(
        for severity: XcircuiteEngineDiagnosticSeverity
    ) -> DiagnosticSeverity {
        switch severity {
        case .info:
            return .information
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }

    private func token(_ value: String) -> String {
        value.lowercased().map { character in
            if character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" {
                return character
            }
            return "_"
        }.reduce(into: "") { result, character in
            result.append(character)
        }
    }
}

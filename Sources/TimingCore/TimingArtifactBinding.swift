import CircuiteFoundation
import CircuiteFoundationFoundation
import Foundation

public enum TimingArtifactBindingError: Error, Sendable, Equatable {
    case availabilityIdentityMismatch
    case localAvailabilityRequired
    case missingWorkspaceRoot
    case unsupportedLocalRoot(String)
}

/// Binds location-independent content identity to one execution-scoped availability.
public struct TimingArtifactBinding: Sendable, Hashable, Codable {
    public static let workspaceRootIdentifier = "timing-workspace"
    public static let localFileSystemRootIdentifier = "timing-local-file-system"

    public let reference: ArtifactReference
    public let availability: ArtifactAvailability

    public var id: ArtifactID { reference.id }
    public var digest: ContentDigest { reference.digest }
    public var byteCount: UInt64 { reference.byteCount }
    public var descriptor: ArtifactDescriptor { reference.descriptor }

    public init(
        reference: ArtifactReference,
        availability: ArtifactAvailability
    ) throws {
        guard reference.id == availability.artifactID else {
            throw TimingArtifactBindingError.availabilityIdentityMismatch
        }
        self.reference = reference
        self.availability = availability
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: container.decode(ArtifactReference.self, forKey: .reference),
            availability: container.decode(ArtifactAvailability.self, forKey: .availability)
        )
    }

    public var materializationDescription: String {
        switch availability {
        case .local(_, let rootID, let relativePath):
            return "local:\(rootID.rawValue)/\(relativePath.stringValue)"
        case .service(_, let resource):
            return "service:\(resource)"
        }
    }

    /// Stable controlled diagnostic display; legacy wire/display text is unchanged.
    package var controlledMaterializationDescription: String {
        switch availability {
        case .local:
            return materializationDescription
        case .service(_, let resource):
            return "service:\(resource.serviceID.rawValue)/\(resource.namespaceID.rawValue)/\(resource.resourceID.rawValue)@\(resource.generation)"
        }
    }

    /// The final service text and its simultaneously live decimal intermediate.
    /// This computes public value sizes without first rendering the resource.
    package func controlledServiceDescriptionCost() throws -> (output: UInt64, temporary: UInt64) {
        guard case .service(_, let resource) = availability else {
            throw LibertySourceError.invalidCapacity
        }
        var remaining = resource.generation
        var decimalBytes: UInt64 = 1
        while remaining >= 10 { remaining /= 10; decimalBytes += 1 }
        var output = UInt64("service://@".utf8.count)
        func add(_ bytes: UInt64) throws {
            let next = output.addingReportingOverflow(bytes)
            guard !next.overflow else { throw LibertySourceError.arithmeticOverflow }
            output = next.partialValue
        }
        try add(UInt64(resource.serviceID.rawValue.utf8.count))
        try add(UInt64(resource.namespaceID.rawValue.utf8.count))
        try add(UInt64(resource.resourceID.rawValue.utf8.count))
        try add(decimalBytes)
        return (output, decimalBytes)
    }

    public func requireLocalAvailability() throws -> (
        rootID: ArtifactRootID,
        relativePath: ArtifactRelativePath
    ) {
        guard case .local(_, let rootID, let relativePath) = availability else {
            throw TimingArtifactBindingError.localAvailabilityRequired
        }
        return (rootID, relativePath)
    }

    public func localFileURL(relativeTo workspaceRoot: URL?) throws -> URL {
        let local = try requireLocalAvailability()
        switch local.rootID.rawValue {
        case Self.workspaceRootIdentifier:
            guard let workspaceRoot else {
                throw TimingArtifactBindingError.missingWorkspaceRoot
            }
            return local.relativePath.segments.reduce(
                workspaceRoot.standardizedFileURL
            ) { partial, segment in
                partial.appending(path: segment)
            }
        case Self.localFileSystemRootIdentifier:
            return local.relativePath.segments.reduce(URL(filePath: "/")) { partial, segment in
                partial.appending(path: segment)
            }
        default:
            throw TimingArtifactBindingError.unsupportedLocalRoot(local.rootID.rawValue)
        }
    }

    public var isWorkspaceRelative: Bool {
        guard case .local(_, let rootID, _) = availability else {
            return false
        }
        return rootID.rawValue == Self.workspaceRootIdentifier
    }
}

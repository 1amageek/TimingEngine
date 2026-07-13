import CircuiteFoundation
import Foundation
import XcircuitePackage

/// Adapts the canonical artifact reader for the retained legacy backend.
///
/// This type is internal to the compatibility implementation. Public callers
/// should inject `TimingArtifactReading` into the Foundation-native engines.
@available(*, deprecated, message: "Compatibility-only adapter; inject TimingArtifactReading into a Foundation engine.")
public struct LegacyTimingArtifactReaderAdapter: LegacyTimingArtifactReading {
    private let reader: any TimingArtifactReading

    public init(reader: any TimingArtifactReading) {
        self.reader = reader
    }

    public func read(_ reference: XcircuiteFileReference) async throws -> Data {
        let foundationReference = try TimingFoundationArtifactBridge().foundationReference(
            from: reference,
            defaultKind: .report,
            defaultFormat: .json,
            producer: nil
        )
        return try await reader.read(foundationReference)
    }
}

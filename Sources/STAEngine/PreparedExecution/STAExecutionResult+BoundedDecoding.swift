import Foundation
import CircuiteFoundationFoundation
import PDKCore
import PDKDiscovery
import TimingCore

extension STAExecutionResult {
    public static func decodeBounded(_ data: Data, resources: STAExecutionResources)
        throws -> TimingTransformValue<STAExecutionResult> {
        guard UInt64(data.count) <= resources.limits.maximumInputBytes else {
            throw STAPreparationError.capacity("Saved STA result exceeds native input byte ceiling")
        }
        let accounting = try NativeSTAPDKAccounting(resources: resources.sourceResources,
            maximumNesting: resources.sourceLimits.maximumNestingDepth)
        var decoded: STAExecutionResult?
        var originalFailure: (any Error)?
        var digestControl: NativeSTAContentDigestControl?
        do {
            let control = try NativeSTAContentDigestControl.make(accounting: accounting)
            digestControl = control
            let contextBytes = try TimingTransformCapacity.dictionary(CodingUserInfoKey.self,
                (any Sendable).self, minimumCapacity: 1)
            let contextLease = try accounting.reserve(.init(dimension: .temporaryBytes, amount: contextBytes))
            defer { withExtendedLifetime(contextLease) {} }
            try accounting.check()
            let context: [CodingUserInfoKey: any Sendable] = [ContentDigestDecodingContext.controlKey: control]
            let document = try data.withUnsafeBytes { raw in
                try NativePDKBoundedDocumentDecoder().decodeAudited(CheckedResultConstruction.self,
                    bytes: raw.bindMemory(to: UInt8.self).span, accounting: accounting,
                    rejectUnknownFields: false, additionalUserInfo: context) { decoder in
                        do { decoded = try STAExecutionResult(from: decoder) }
                        catch { originalFailure = error; throw error }
                    }
            }
            guard let decoded else {
                throw TimingError.invariantViolation("Saved STA construction did not produce its value")
            }
            try resources.sourceResources.check()
            return try TimingTransformValue(value: decoded, retaining: (document, control),
                resources: resources.sourceResources)
        } catch {
            if let digestControl {
                digestControl.retainFailure(error)
                throw accounting.preservingCause(error, domainCause: originalFailure, retaining: digestControl)
            }
            throw accounting.preservingCause(error, domainCause: originalFailure)
        }
    }
}

/// The audited validation closure performs actual DTO construction exactly once.
/// This marker adds no second decoding pass or saved-result authority.
private struct CheckedResultConstruction: Decodable, Sendable {
    init(from decoder: any Decoder) throws {}
}

import Foundation

/// The host supplies the existing audited JSON decoder without reversing the
/// TimingCore-to-PDK dependency boundary. Schemas remain owned by TimingCore.
public protocol TimingBoundedJSONDecoding: Sendable {
    func decodeDesign(_ data: Data, resources: any LibertySourceResourceAccounting)
        throws -> TimingTransformValue<TimingDesign>
    func decodeParasitics(_ data: Data, resources: any LibertySourceResourceAccounting)
        throws -> TimingTransformValue<TimingParasitics>
}

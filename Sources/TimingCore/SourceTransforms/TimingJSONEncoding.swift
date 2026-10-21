import Foundation

/// Admitted JSON publication; Foundation encoder workspace is outside the managed
/// payload boundary. Custom Encodable allocation remains the schema owner's duty.
public enum TimingJSONEncoding {
    public static func encode<Value: Encodable>(
        _ value: Value,
        formatting: JSONEncoder.OutputFormatting,
        resources original: any LibertySourceResourceAccounting
    ) throws -> TimingTransformValue<Data> {
        let resources = try TimingCheckedSourceResources(original)
        let counterMetadata = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: try LibertySourceCapacity.byteCount(of:
                (UInt64, any LibertySourceResourceAccounting, UInt64, (any Error)?).self,
                capacity: 1))
        let bytes = try TimingJSONUpperBound.count(value, maximumBytes: UInt64(Int.max),
            resources: resources)
        let payload = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        try resources.chargeWork(bytes)
        try resources.check()
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        let encoded = try encoder.encode(value)
        try resources.check()
        guard UInt64(encoded.count) <= bytes else {
            throw TimingTransformError.unsupportedCapability("JSON encoder exceeded its admitted grammar bound")
        }
        withExtendedLifetime(counterMetadata) {}
        return try TimingTransformValue(value: encoded, retaining: payload, resources: resources)
    }

    public static func encode<Value: Encodable>(
        _ value: Value,
        prefix: StaticString,
        formatting: JSONEncoder.OutputFormatting,
        resources original: any LibertySourceResourceAccounting
    ) throws -> TimingTransformValue<Data> {
        let resources = try TimingCheckedSourceResources(original)
        let encoded = try encode(value, formatting: formatting, resources: resources)
        let (count, overflow) = prefix.utf8CodeUnitCount.addingReportingOverflow(encoded.value.count)
        guard !overflow else { throw LibertySourceError.arithmeticOverflow }
        let payload = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(count))
        try resources.chargeWork(UInt64(count))
        try resources.check()
        var bytes = Data()
        bytes.reserveCapacity(count)
        prefix.withUTF8Buffer { bytes.append(contentsOf: $0) }
        bytes.append(encoded.value)
        try resources.check()
        withExtendedLifetime(encoded) {}
        return try TimingTransformValue(value: bytes, retaining: payload, resources: resources)
    }
}

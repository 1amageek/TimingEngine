import Foundation
import TimingCore

/// Exact existing length-prefixed wire construction with one explicitly owned
/// growing Data payload. It is confined to its synchronous construction scope.
internal final class NativeSTAConfigurationFraming {
    private let resources: any LibertySourceResourceAccounting
    private var bytes = Data()
    private var capacity = 0
    private var payload: LibertySourceStorageReservation?
    private let metadata: LibertySourceStorageReservation

    init(resources: any LibertySourceResourceAccounting) throws {
        let checked = try TimingCheckedSourceResources(resources)
        self.resources = checked
        metadata = try checked.reserveStorage(kind: .temporaryBytes,
            byteCount: LibertySourceCapacity.byteCount(of:
                (any LibertySourceResourceAccounting, Data, Int, LibertySourceStorageReservation?, LibertySourceStorageReservation).self,
                capacity: 1))
    }

    func text(_ value: String) throws {
        try resources.chargeWork(UInt64(value.utf8.count))
        try append(value.utf8)
    }

    func integer<T: FixedWidthInteger>(_ value: T) throws {
        // Decimal has at most one digit per binary bit, plus a sign. This bound
        // covers all FixedWidthInteger values before String(value) is formed.
        let count = T.bitWidth.addingReportingOverflow(1)
        guard !count.overflow else { throw LibertySourceError.arithmeticOverflow }
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(count.partialValue))
        try resources.chargeWork(UInt64(count.partialValue))
        try text(String(value))
        withExtendedLifetime(scratch) {}
    }

    func boolean(_ value: Bool) throws { try text(value ? "true" : "false") }

    func json<Value: Encodable>(_ value: Value) throws {
        let encoded = try TimingJSONEncoding.encode(value, formatting: [.sortedKeys], resources: resources)
        try append(encoded.value)
        withExtendedLifetime(encoded) {}
    }

    private func append<Bytes: Collection>(_ body: Bytes) throws where Bytes.Element == UInt8 {
        try resources.check()
        let prefixScratch = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: TimingDiagnosticTextCapacity.maximumIntDescriptionBytes)
        try resources.chargeWork(TimingDiagnosticTextCapacity.maximumIntDescriptionBytes)
        let prefix = String(body.count)
        let first = bytes.count.addingReportingOverflow(prefix.utf8.count)
        let second = first.partialValue.addingReportingOverflow(1)
        let total = second.partialValue.addingReportingOverflow(body.count)
        guard !first.overflow, !second.overflow, !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        if total.partialValue > capacity {
            let doubled = capacity.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { throw LibertySourceError.arithmeticOverflow }
            let requested = max(total.partialValue, max(1, doubled.partialValue))
            let next = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(requested))
            try resources.chargeWork(UInt64(bytes.count))
            try resources.check()
            var replacement = Data(); replacement.reserveCapacity(requested)
            replacement.append(bytes)
            let previous = payload
            bytes = replacement; payload = next; capacity = requested
            withExtendedLifetime(previous) {}
        }
        try resources.chargeWork(UInt64(prefix.utf8.count))
        try resources.chargeWork(1)
        try resources.chargeWork(UInt64(body.count))
        try resources.check()
        bytes.append(contentsOf: prefix.utf8); bytes.append(58); bytes.append(contentsOf: body)
        try resources.check()
        withExtendedLifetime(prefixScratch) {}
    }

    func withBytes<Result>(_ body: (Data) throws -> Result) rethrows -> Result {
        try body(bytes)
    }
}

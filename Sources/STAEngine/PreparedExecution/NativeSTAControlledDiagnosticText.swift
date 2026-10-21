import Foundation
import TimingCore

/// Construction-local owned UTF-8 text. It never escapes its synchronous call;
/// only the immutable final value and its actual payload lease are published.
internal final class NativeSTAControlledDiagnosticText {
    private let resources: any LibertySourceResourceAccounting
    private var value = String()
    private var payload: LibertySourceStorageReservation?
    private let metadata: LibertySourceStorageReservation

    init(resources: any LibertySourceResourceAccounting) throws {
        let checked = try TimingCheckedSourceResources(resources)
        self.resources = checked
        metadata = try checked.reserveStorage(kind: .temporaryBytes,
            byteCount: LibertySourceCapacity.byteCount(of:
                (any LibertySourceResourceAccounting, String, LibertySourceStorageReservation?, LibertySourceStorageReservation).self,
                capacity: 1))
    }

    func append(_ text: String) throws {
        try resources.check()
        let sum = value.utf8.count.addingReportingOverflow(text.utf8.count)
        guard !sum.overflow else { throw LibertySourceError.arithmeticOverflow }
        let next = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(sum.partialValue))
        try resources.chargeWork(UInt64(sum.partialValue))
        try resources.check()
        var replacement = String(); replacement.reserveCapacity(sum.partialValue)
        replacement.append(contentsOf: value); replacement.append(contentsOf: text)
        let previous = payload
        value = replacement; payload = next
        withExtendedLifetime(previous) {}
        try resources.check()
    }

    func integer(_ number: Int) throws {
        let scratch = try resources.reserveStorage(kind: .temporaryBytes,
            byteCount: TimingDiagnosticTextCapacity.maximumIntDescriptionBytes)
        try resources.chargeWork(TimingDiagnosticTextCapacity.maximumIntDescriptionBytes)
        try resources.check()
        try append(String(number))
        withExtendedLifetime(scratch) {}
    }

    func bits(_ number: Double) throws {
        // A UInt64 hexadecimal representation has at most sixteen ASCII digits.
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: 16)
        try resources.chargeWork(16); try resources.check()
        try append(String(number.bitPattern, radix: 16))
        withExtendedLifetime(scratch) {}
    }

    func clipped(_ text: String, limit: Int = 96) throws {
        guard limit >= 0 else { throw LibertySourceError.invalidCapacity }
        let bytes = text.utf8.prefix(limit)
        // Decoding can replace each truncated/invalid byte with U+FFFD (3 bytes).
        let maximum = bytes.count.multipliedReportingOverflow(by: 3)
        guard !maximum.overflow else { throw LibertySourceError.arithmeticOverflow }
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(maximum.partialValue))
        try resources.chargeWork(UInt64(bytes.count)); try resources.check()
        try append(String(decoding: bytes, as: UTF8.self))
        withExtendedLifetime(scratch) {}
    }

    func finish(limit: Int? = nil) throws -> TimingTransformValue<String> {
        try resources.check()
        if let limit {
            guard limit >= 0 else { throw LibertySourceError.invalidCapacity }
            let prefix = value.utf8.prefix(limit)
            let maximum = prefix.count.multipliedReportingOverflow(by: 3)
            guard !maximum.overflow else { throw LibertySourceError.arithmeticOverflow }
            let next = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(maximum.partialValue))
            try resources.chargeWork(UInt64(prefix.count)); try resources.check()
            let replacement = String(decoding: prefix, as: UTF8.self)
            let previous = payload
            value = replacement; payload = next
            withExtendedLifetime(previous) {}
        }
        return try TimingTransformValue(value: value, retaining: payload, resources: resources)
    }
}

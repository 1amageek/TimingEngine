import TimingCore

/// The preparation result owns all newly materialized names and ordered inventories.
internal struct NativeSTAClockCharacterization: Sendable {
    let buffers: [String]
    let sequential: [String]
    let receivers: [(root: String, receiver: String)]
    private let retention: Retention?

    init(buffers: [String], sequential: [String], receivers: [(root: String, receiver: String)], retention: Retention? = nil) {
        self.buffers = buffers; self.sequential = sequential; self.receivers = receivers; self.retention = retention
    }

    final class Retention: Sendable {
        let payloads: [LibertySourceStorageReservation]
        let metadata: LibertySourceStorageReservation
        init(_ payloads: [LibertySourceStorageReservation], metadata: LibertySourceStorageReservation) {
            self.payloads = payloads; self.metadata = metadata
        }
    }

    /// Lexical preparation scratch; it uses the caller's original ledger directly.
    final class Storage {
        let resources: any LibertySourceResourceAccounting
        private var temporary: [LibertySourceStorageReservation] = []
        private var retained: [LibertySourceStorageReservation] = []
        private let temporaryMetadata: LibertySourceStorageReservation
        private let retainedMetadata: LibertySourceStorageReservation
        private let resultCapacity: Int

        init(resources: any LibertySourceResourceAccounting, resultCapacity: Int) throws {
            self.resources = resources
            let total = resultCapacity.addingReportingOverflow(3)
            guard !total.overflow else { throw LibertySourceError.arithmeticOverflow }
            self.resultCapacity = total.partialValue
            temporaryMetadata = try Self.admit(resources, count: 7, type: LibertySourceStorageReservation.self, kind: .temporaryBytes)
            let elements = UInt64(total.partialValue).multipliedReportingOverflow(by: UInt64(MemoryLayout<LibertySourceStorageReservation>.stride))
            let bytes = elements.partialValue.addingReportingOverflow(UInt64(MemoryLayout<([LibertySourceStorageReservation], LibertySourceStorageReservation)>.stride))
            guard !elements.overflow, !bytes.overflow else { throw LibertySourceError.arithmeticOverflow }
            try resources.check()
            retainedMetadata = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes.partialValue)
            try resources.check()
            temporary.reserveCapacity(7); retained.reserveCapacity(total.partialValue)
        }
        private static func admit<T>(_ resources: any LibertySourceResourceAccounting, count: Int, type: T.Type,
            kind: LibertySourceStorageKind) throws -> LibertySourceStorageReservation {
            guard count >= 0 else { throw LibertySourceError.arithmeticOverflow }
            let bytes = UInt64(count).multipliedReportingOverflow(by: UInt64(MemoryLayout<T>.stride))
            guard !bytes.overflow else { throw LibertySourceError.arithmeticOverflow }
            try resources.check(); let value = try resources.reserveStorage(kind: kind, byteCount: bytes.partialValue)
            try resources.check(); return value
        }
        func step(_ count: Int = 1) throws {
            guard count >= 0 else { throw LibertySourceError.arithmeticOverflow }
            try Task.checkCancellation(); try resources.check(); try resources.chargeWork(UInt64(count)); try resources.check()
        }
        func scratch<T>(_ type: T.Type, count: Int) throws {
            guard temporary.count < 7 else { throw LibertySourceError.invalidCapacity }
            temporary.append(try Self.admit(resources, count: count, type: type, kind: .temporaryBytes))
        }
        func scratchSet<T>(_ type: T.Type, count: Int) throws {
            guard temporary.count < 7 else { throw LibertySourceError.invalidCapacity }
            try resources.check(); let bytes = try TimingTransformCapacity.set(type, minimumCapacity: count)
            let value = try resources.reserveStorage(kind: .temporaryBytes, byteCount: bytes); try resources.check(); temporary.append(value)
        }
        func scratchDictionary<K, V>(_ key: K.Type, _ value: V.Type, count: Int) throws {
            guard temporary.count < 7 else { throw LibertySourceError.invalidCapacity }
            try resources.check(); let bytes = try TimingTransformCapacity.dictionary(key, value, minimumCapacity: count)
            let lease = try resources.reserveStorage(kind: .temporaryBytes, byteCount: bytes); try resources.check(); temporary.append(lease)
        }
        func result<T>(_ type: T.Type, count: Int) throws {
            guard retained.count < resultCapacity else { throw LibertySourceError.invalidCapacity }
            retained.append(try Self.admit(resources, count: count, type: type, kind: .liveOwnedBytes))
        }
        func coneStorage(count: Int) throws -> (LibertySourceStorageReservation, LibertySourceStorageReservation) {
            let array = try Self.admit(resources, count: count, type: String.self, kind: .temporaryBytes)
            let seenCount = count.addingReportingOverflow(1)
            guard !seenCount.overflow else { throw LibertySourceError.arithmeticOverflow }
            try resources.check(); let bytes = try TimingTransformCapacity.set(String.self, minimumCapacity: seenCount.partialValue)
            let set = try resources.reserveStorage(kind: .temporaryBytes, byteCount: bytes); try resources.check()
            return (array, set)
        }
        func receiver(_ name: String, delimiter: String, pin: String) throws -> String {
            let first = name.utf8.count.addingReportingOverflow(delimiter.utf8.count)
            let total = first.partialValue.addingReportingOverflow(pin.utf8.count)
            guard !first.overflow, !total.overflow else { throw LibertySourceError.arithmeticOverflow }
            try result(UInt8.self, count: total.partialValue); try step(total.partialValue)
            var text = String(); text.reserveCapacity(total.partialValue)
            text.append(name); text.append(delimiter); text.append(pin); return text
        }
        func sortedResult(_ source: Set<String>) throws -> [String] {
            var outputLease = try Self.admit(resources, count: source.count, type: String.self, kind: .liveOwnedBytes)
            var output: [String] = []; output.reserveCapacity(source.count)
            for value in source { try step(); output.append(value) }
            if output.count > 1 {
                var otherLease = try Self.admit(resources, count: source.count, type: String.self, kind: .liveOwnedBytes)
                var other: [String] = []; other.reserveCapacity(source.count)
                for value in source { try step(); other.append(value) }
                var width = 1
                while width < output.count {
                    var start = 0
                    while start < output.count {
                        let middle = start + min(width, output.count - start)
                        let end = middle + min(width, output.count - middle)
                        var left = start, right = middle, target = start
                        while left < middle || right < end {
                            try step()
                            let takeLeft: Bool
                            if right == end { takeLeft = true }
                            else if left == middle { takeLeft = false }
                            else {
                                try step(output[right].utf8.count); try step(output[left].utf8.count)
                                takeLeft = !(output[right] < output[left])
                            }
                            if takeLeft { other[target] = output[left]; left += 1 }
                            else { other[target] = output[right]; right += 1 }
                            target += 1
                        }
                        start = end
                    }
                    swap(&output, &other); swap(&outputLease, &otherLease)
                    if width > output.count / 2 { break }; width *= 2
                }
                withExtendedLifetime(otherLease) {}
            }
            guard retained.count < resultCapacity else { throw LibertySourceError.invalidCapacity }
            retained.append(outputLease); return output
        }
        func finish() -> Retention { Retention(retained, metadata: retainedMetadata) }
    }
}

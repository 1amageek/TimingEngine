/// Managed Swift collection payload bounds for the fixed Swift 6.4 profile.
/// Object headers, allocator rounding and runtime/framework workspace are excluded.
package enum TimingTransformCapacity {
    package static func dictionary<Key, Value>(_: Key.Type, _: Value.Type,
        minimumCapacity: Int) throws -> UInt64 {
        let stride = MemoryLayout<Key>.stride.addingReportingOverflow(MemoryLayout<Value>.stride)
        guard !stride.overflow else { throw LibertySourceError.arithmeticOverflow }
        return try hashPayload(minimumCapacity: minimumCapacity, elementStride: stride.partialValue)
    }

    package static func set<Element>(_: Element.Type, minimumCapacity: Int) throws -> UInt64 {
        try hashPayload(minimumCapacity: minimumCapacity, elementStride: MemoryLayout<Element>.stride)
    }

    private static func hashPayload(minimumCapacity count: Int, elementStride: Int) throws -> UInt64 {
        guard count >= 0, elementStride >= 0 else { throw LibertySourceError.invalidCapacity }
        guard count > 0 else { return 0 }
        // Swift 6.4's native hash table uses power-of-two buckets and maximum
        // 3/4 load. Include key/value buckets and the occupied-bucket bitset.
        let scaled = count.multipliedReportingOverflow(by: 4)
        guard !scaled.overflow else { throw LibertySourceError.arithmeticOverflow }
        let required = (scaled.partialValue / 3).addingReportingOverflow(1)
        guard !required.overflow else { throw LibertySourceError.arithmeticOverflow }
        var buckets = 1
        while buckets < required.partialValue {
            let next = buckets.multipliedReportingOverflow(by: 2)
            guard !next.overflow else { throw LibertySourceError.arithmeticOverflow }
            buckets = next.partialValue
        }
        let elements = UInt64(buckets).multipliedReportingOverflow(by: UInt64(elementStride))
        let wordCount = (buckets / UInt.bitWidth).addingReportingOverflow(1)
        guard !wordCount.overflow else { throw LibertySourceError.arithmeticOverflow }
        let words = UInt64(wordCount.partialValue).multipliedReportingOverflow(by: UInt64(MemoryLayout<UInt>.stride))
        let total = elements.partialValue.addingReportingOverflow(words.partialValue)
        guard !elements.overflow, !words.overflow, !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        return total.partialValue
    }
}

/// Representation bounds for existing fixed Swift 6.4 numeric descriptions.
/// This counts text payload, not allocator/RSS or arbitrary CustomStringConvertible.
package enum TimingDiagnosticTextCapacity {
    package static var maximumIntDescriptionBytes: UInt64 {
        var magnitude = Int.min.magnitude
        var digits: UInt64 = 1
        while magnitude >= 10 { magnitude /= 10; digits += 1 }
        return digits + 1 // The largest magnitude's optional minus sign.
    }

    package static func description(literal: StaticString, ints: Int, doubles: Int,
        booleans: Int, additionalUTF8: UInt64 = 0) throws -> UInt64 {
        guard ints >= 0, doubles >= 0, booleans >= 0 else { throw LibertySourceError.invalidCapacity }
        var result = UInt64(literal.utf8CodeUnitCount)
        func add(_ count: UInt64, _ width: UInt64) throws {
            let product = count.multipliedReportingOverflow(by: width)
            let next = result.addingReportingOverflow(product.partialValue)
            guard !product.overflow, !next.overflow else { throw LibertySourceError.arithmeticOverflow }
            result = next.partialValue
        }
        try add(UInt64(ints), maximumIntDescriptionBytes)
        // FloatingPointTypes.swift.gyb (swift-6.4.0-RELEASE) description uses an
        // inline 64-byte ASCII buffer and publishes only a subrange of it.
        try add(UInt64(doubles), 64)
        try add(UInt64(booleans), 5)
        try add(1, additionalUTF8)
        return result
    }
}

/// Finite package-only enclosure of exact real arithmetic on Double operands.
package struct TimingNumericInterval: Sendable, Equatable {
    package let lowerBound: Double
    package let upperBound: Double

    package init(_ range: ClosedRange<Double>) throws {
        try self.init(lowerBound: range.lowerBound, upperBound: range.upperBound)
    }

    package init(point: Double) throws {
        try self.init(lowerBound: point, upperBound: point)
    }

    package init(lowerBound: Double, upperBound: Double) throws {
        guard lowerBound.isFinite, upperBound.isFinite, lowerBound <= upperBound else {
            throw TimingNumericBoundsError.invalidInterval
        }
        self.lowerBound = lowerBound; self.upperBound = upperBound
    }

    package func adding(_ other: Self) throws -> Self {
        if other.isZero { return self }
        if isZero { return other }
        if lowerBound == upperBound, other.lowerBound == other.upperBound,
           lowerBound == -other.lowerBound { return try Self(point: 0) }
        return try Self(lowerBound: Self.down(lowerBound + other.lowerBound),
                        upperBound: Self.up(upperBound + other.upperBound))
    }

    package func subtracting(_ other: Self) throws -> Self {
        if other.isZero { return self }
        if lowerBound == upperBound, self == other { return try Self(point: 0) }
        return try Self(lowerBound: Self.down(lowerBound - other.upperBound),
                        upperBound: Self.up(upperBound - other.lowerBound))
    }

    package func multiplied(by other: Self) throws -> Self {
        if isZero || other.isZero { return try Self(point: 0) }
        if other.lowerBound == 1, other.upperBound == 1 { return self }
        if lowerBound == 1, upperBound == 1 { return other }
        let a = lowerBound * other.lowerBound, b = lowerBound * other.upperBound
        let c = upperBound * other.lowerBound, d = upperBound * other.upperBound
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite else { throw TimingNumericBoundsError.nonfiniteResult }
        return try Self(lowerBound: Self.down(min(a, b, c, d)), upperBound: Self.up(max(a, b, c, d)))
    }

    package func divided(by other: Self) throws -> Self {
        guard other.upperBound < 0 || other.lowerBound > 0 else { throw TimingNumericBoundsError.zeroDivisor }
        if isZero { return self }
        if other.lowerBound == 1, other.upperBound == 1 { return self }
        let a = lowerBound / other.lowerBound, b = lowerBound / other.upperBound
        let c = upperBound / other.lowerBound, d = upperBound / other.upperBound
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite else { throw TimingNumericBoundsError.nonfiniteResult }
        return try Self(lowerBound: Self.down(min(a, b, c, d)), upperBound: Self.up(max(a, b, c, d)))
    }

    package func negated() throws -> Self {
        try Self(lowerBound: -upperBound, upperBound: -lowerBound)
    }

    package func absolute() throws -> Self {
        if lowerBound >= 0 { return self }
        if upperBound <= 0 { return try negated() }
        return try Self(lowerBound: 0, upperBound: max(-lowerBound, upperBound))
    }

    private var isZero: Bool { lowerBound == 0 && upperBound == 0 }

    private static func down(_ value: Double) throws -> Double {
        guard value.isFinite, value.nextDown.isFinite else { throw TimingNumericBoundsError.nonfiniteResult }
        return value.nextDown
    }

    private static func up(_ value: Double) throws -> Double {
        guard value.isFinite, value.nextUp.isFinite else { throw TimingNumericBoundsError.nonfiniteResult }
        return value.nextUp
    }
}

import Testing
@testable import TimingCore

@Suite("Outward finite numerical intervals", .timeLimit(.minutes(1)))
struct TimingNumericIntervalTests {
    @Test func exactZeroAndNeutralOperandsDoNotCreateSourceIncidence() throws {
        let zero = try TimingNumericInterval(point: 0)
        let value = try TimingNumericInterval(lowerBound: -3, upperBound: 7)
        #expect(try value.adding(zero) == value)
        #expect(try zero.adding(value) == value)
        #expect(try value.subtracting(zero) == value)
        #expect(try value.multiplied(by: zero) == zero)
        #expect(try zero.multiplied(by: value) == zero)
        #expect(try zero.divided(by: .init(point: -2)) == zero)
        #expect(try TimingNumericInterval(point: 8).subtracting(.init(point: 8)) == zero)
        #expect(try TimingNumericInterval(point: 8).adding(.init(point: -8)) == zero)
        #expect(try value.multiplied(by: .init(point: 1)) == value)
        #expect(try value.divided(by: .init(point: 1)) == value)
    }

    @Test func subnormalProductsAndQuotientsEncloseUnrepresentableExactValues() throws {
        let tiny = Double.leastNonzeroMagnitude
        let half = try TimingNumericInterval(point: tiny).multiplied(by: .init(point: 0.5))
        #expect(half.lowerBound <= 0 && half.upperBound >= tiny)
        let negative = try TimingNumericInterval(point: -tiny).divided(by: .init(point: 2))
        #expect(negative.lowerBound <= -tiny && negative.upperBound >= 0)
        let sum = try TimingNumericInterval(point: tiny).adding(.init(point: tiny))
        #expect(sum.lowerBound <= tiny * 2 && sum.upperBound >= tiny * 2)
    }

    @Test func cancellationSignedProductsAndNegativeDivisionAreOutward() throws {
        let sum = try TimingNumericInterval(point: 1).adding(.init(point: 0x1p-54))
        #expect(sum.lowerBound <= 1 && sum.upperBound >= Double(1).nextUp)
        let difference = try TimingNumericInterval(point: 1).subtracting(.init(point: 0x1p-54))
        #expect(difference.lowerBound <= Double(1).nextDown && difference.upperBound >= 1)
        let a = try TimingNumericInterval(-2...3)
        let b = try TimingNumericInterval(-5 ... -4)
        let product = try a.multiplied(by: b)
        #expect(product.lowerBound <= -15 && product.upperBound >= 10)
        let quotient = try a.divided(by: b)
        #expect(quotient.lowerBound <= -0.75 && quotient.upperBound >= 0.5)
        #expect(try a.absolute() == TimingNumericInterval(0...3))
        #expect(try b.negated() == TimingNumericInterval(4...5))
    }

    @Test func nonfiniteOverflowAndZeroDivisorsFailExplicitly() throws {
        #expect(throws: TimingNumericBoundsError.invalidInterval) { _ = try TimingNumericInterval(point: .nan) }
        #expect(throws: TimingNumericBoundsError.invalidInterval) { _ = try TimingNumericInterval(point: .infinity) }
        #expect(throws: TimingNumericBoundsError.invalidInterval) {
            _ = try TimingNumericInterval(lowerBound: 1, upperBound: -1)
        }
        let largest = try TimingNumericInterval(point: Double.greatestFiniteMagnitude)
        #expect(throws: TimingNumericBoundsError.nonfiniteResult) { _ = try largest.adding(largest) }
        #expect(throws: TimingNumericBoundsError.nonfiniteResult) { _ = try largest.multiplied(by: .init(point: 2)) }
        #expect(throws: TimingNumericBoundsError.nonfiniteResult) { _ = try largest.divided(by: .init(point: 0.5)) }
        #expect(throws: TimingNumericBoundsError.zeroDivisor) {
            _ = try TimingNumericInterval(point: 0).divided(by: .init(-1...1))
        }
        #expect(throws: TimingNumericBoundsError.zeroDivisor) {
            _ = try TimingNumericInterval(point: 1).divided(by: .init(point: -0.0))
        }
    }
}

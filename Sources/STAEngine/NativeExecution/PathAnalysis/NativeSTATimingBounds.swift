import TimingCore

/// Directed host arithmetic for independently composed certified timing intervals.
internal enum NativeSTATimingBounds {
    static func add(_ a: Double, _ b: Double, upper: Bool) throws -> Double {
        let value = try TimingNumericInterval(point: a).adding(TimingNumericInterval(point: b))
        return upper ? value.upperBound : value.lowerBound
    }
    static func sum(_ values: [Double], upper: Bool) throws -> Double {
        var result = try TimingNumericInterval(point: 0)
        for value in values { result = try result.adding(TimingNumericInterval(point: value)) }
        return upper ? result.upperBound : result.lowerBound
    }
    static func scale(_ range: ClosedRange<Double>, by value: Double) throws -> ClosedRange<Double> {
        let result = try TimingNumericInterval(range).multiplied(by: TimingNumericInterval(point: value))
        return result.lowerBound...result.upperBound
    }
    static func derated(_ range: ClosedRange<Double>, early: Double, late: Double) throws -> ClosedRange<Double> {
        let scales = try TimingNumericInterval(min(early, late)...max(early, late))
        let result = try TimingNumericInterval(range).multiplied(by: scales)
        return result.lowerBound...result.upperBound
    }
    static func slew(_ early: Double, _ late: Double) -> ClosedRange<Double> {
        min(early, late)...max(early, late)
    }
}

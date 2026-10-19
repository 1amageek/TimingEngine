import TimingCore

/// Scenario-owned restrictions on otherwise unrestricted prescribed source histories.
internal enum NativeSTAConservativeSourceHistory: Sendable, Hashable {
    struct Clock: Sendable, Hashable {
        let rootIdentity: String
        let period: Double
        let riseReference: ClosedRange<Double>
        let fallReference: ClosedRange<Double>

        struct Ramp {
            let start: TimingNumericInterval
            let end: TimingNumericInterval
            let slopeUpperBound: Double
        }

        /// Returns adjacent rise/fall windows; translating a whole window preserves every cycle.
        func ramps(source: NativeSTAConservativeCoupling.Source,
            thresholds: TimingCharacterizationThresholds) throws -> (rise: Ramp, fall: Ramp) {
            typealias I = TimingNumericInterval
            guard case .dynamic(_, let isPort, let rise, let fall) = source else {
                throw NativeSTAConservativeCouplingError.invalidSourceAuthority("clock history on a constant source")
            }
            let riseSpan = try NativeSTAConservativeCoupling().thresholdSpan(thresholds, rising: true)
            let fallSpan = try NativeSTAConservativeCoupling().thresholdSpan(thresholds, rising: false)
            let riseDuration = try I(rise).divided(by: riseSpan), fallDuration = try I(fall).divided(by: fallSpan)
            let qr = try I(point: isPort ? thresholds.inputRise : thresholds.outputRise).divided(by: I(point: 100))
            let qf = try I(point: 1).subtracting(I(point: isPort ? thresholds.inputFall : thresholds.outputFall)
                .divided(by: I(point: 100)))
            let one = try I(point: 1)
            let riseStart = try I(riseReference).subtracting(qr.multiplied(by: riseDuration))
            let riseEnd = try I(riseReference).adding(one.subtracting(qr).multiplied(by: riseDuration))
            let fallStart = try I(fallReference).subtracting(qf.multiplied(by: fallDuration))
            let fallEnd = try I(fallReference).adding(one.subtracting(qf).multiplied(by: fallDuration))
            let riseMid = riseReference.lowerBound / 2 + riseReference.upperBound / 2
            let fallMid = fallReference.lowerBound / 2 + fallReference.upperBound / 2
            let cycles = ((riseMid - fallMid) / period).rounded(.down) + 1
            guard cycles.isFinite, abs(cycles) < 4_503_599_627_370_496 else {
                throw NativeSTAConservativeCouplingError.invalidSourceAuthority("clock history cycle offset is not representable")
            }
            let shift = try I(point: cycles).multiplied(by: I(point: period))
            return (Ramp(start: riseStart, end: riseEnd,
                         slopeUpperBound: try riseSpan.divided(by: I(rise)).upperBound),
                    Ramp(start: try fallStart.adding(shift), end: try fallEnd.adding(shift),
                         slopeUpperBound: try fallSpan.divided(by: I(fall)).upperBound))
        }
    }

    case clock(Clock)
    case minimumPlateau(seconds: Double)
}

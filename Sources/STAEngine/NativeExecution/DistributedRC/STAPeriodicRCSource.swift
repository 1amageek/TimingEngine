import Foundation
import TimingCore

/// Prescribed periodic voltage source; no clock-tree or drive-current authority is owned here.
internal struct STAPeriodicRCSource: Hashable {
    let period: Double
    let risePhase: Double
    let fallPhase: Double
    let riseSlew: Double
    let fallSlew: Double

    func shape(thresholds: TimingCharacterizationThresholds, sourceIsPort: Bool) throws -> Shape {
        let riseThreshold = (sourceIsPort ? thresholds.inputRise : thresholds.outputRise) / 100
        let fallThreshold = (sourceIsPort ? thresholds.inputFall : thresholds.outputFall) / 100
        let riseDuration = riseSlew / ((thresholds.slewUpperRise - thresholds.slewLowerRise) / 100)
        let fallDuration = fallSlew / ((thresholds.slewUpperFall - thresholds.slewLowerFall) / 100)
        guard [period, risePhase, fallPhase, riseSlew, fallSlew, riseDuration, fallDuration].allSatisfy(\.isFinite),
              period > 0, riseSlew > 0, fallSlew > 0 else {
            throw TimingError.unsupportedSemantic(format: "periodic RC", semantic: "invalid explicit source waveform")
        }
        func phase(_ t: Double) -> Double { let p = t.truncatingRemainder(dividingBy: period); return p < 0 ? p + period : p }
        let riseStart = phase(risePhase - riseDuration * riseThreshold)
        let fallStart = phase(fallPhase - fallDuration * (1 - fallThreshold))
        let fallingOffset = phase(fallStart - riseStart)
        guard riseDuration < fallingOffset, fallingOffset + fallDuration < period else {
            throw TimingError.unsupportedSemantic(format: "periodic RC", semantic: "overlapping source ramps")
        }
        return .init(period: period, risePhase: phase(risePhase), fallPhase: phase(fallPhase), riseStart: riseStart,
            riseDuration: riseDuration, fallDuration: fallDuration, fallingOffset: fallingOffset,
            riseThreshold: riseThreshold, fallThreshold: fallThreshold)
    }
    struct Shape {
        let period: Double
        let risePhase: Double
        let fallPhase: Double
        let riseStart: Double
        let riseDuration: Double
        let fallDuration: Double
        let fallingOffset: Double
        let riseThreshold: Double
        let fallThreshold: Double
        func voltage(_ time: Double) -> Double {
            let remainder = (time - riseStart).truncatingRemainder(dividingBy: period)
            let x = remainder < 0 ? remainder + period : remainder
            if x < riseDuration { return x / riseDuration }
            if x < fallingOffset { return 1 }
            if x < fallingOffset + fallDuration { return 1 - (x - fallingOffset) / fallDuration }
            return 0
        }
        var breakpoints: [Double] {
            [riseStart, riseStart + riseDuration, riseStart + fallingOffset, riseStart + fallingOffset + fallDuration]
                .map { $0.truncatingRemainder(dividingBy: period) }.sorted()
        }
    }
}

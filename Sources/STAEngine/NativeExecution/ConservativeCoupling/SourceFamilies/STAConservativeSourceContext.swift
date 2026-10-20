import TimingCore

/// Checked initial normalized source family. Physical source/rail/time joins remain external.
public struct STAConservativeSourceContext: Sendable {
    public struct Enclosure: Sendable, Equatable {
        public let value: ClosedRange<Double>
        public let leftSlope: ClosedRange<Double>
        public let rightSlope: ClosedRange<Double>
    }
    public let record: STAConservativeSourceContextRecord
    private let control: NativeSTAInitialSourceControl
    private let lease: LibertySourceStorageReservation
    internal init(record: STAConservativeSourceContextRecord, control: NativeSTAInitialSourceControl,
        lease: LibertySourceStorageReservation) {
        self.record = record; self.control = control; self.lease = lease
    }

    /// Time is in the retained timing source's SI seconds; values are normalized.
    /// Includes every allowed phase and both one-sided limits, including negative time.
    public func enclose(sourceAt index: Int, over time: ClosedRange<Double>) throws(STAExecutionError) -> Enclosure {
        do { return try encloseBound(sourceAt: index, over: time) }
        catch is CancellationError { throw .cancelled }
        catch { throw .underlying(error) }
    }

    /// Projects initial and window bounds from this same nonempty normalized family.
    /// All times are SI hulls; an upper consumer must bind its exact times to them.
    public func jointSlice(sourceAt index: Int, initialTime: ClosedRange<Double>,
        over window: ClosedRange<Double>) throws(STAExecutionError) -> STAConservativeSourceJointSlice {
        do {
            try control.checkpoint(amount: 8)
            guard record.sources.indices.contains(index),
                  initialTime.lowerBound.isFinite, initialTime.upperBound.isFinite,
                  window.lowerBound.isFinite, window.upperBound.isFinite,
                  window.lowerBound <= initialTime.lowerBound,
                  initialTime.upperBound <= window.upperBound else {
                throw invalid("joint source index or time containment")
            }
            let bytes = MemoryLayout<STAConservativeSourceJointSlice>.stride.addingReportingOverflow(
                MemoryLayout<LibertySourceStorageReservation>.stride)
            guard !bytes.overflow else { throw LibertySourceError.arithmeticOverflow }
            let outputLease = try control.reserve(bytes: bytes.partialValue, slots: 1)
            let initial = try encloseBound(sourceAt: index, over: initialTime)
            let whole = try encloseBound(sourceAt: index, over: window)
            let slopeLower = min(whole.leftSlope.lowerBound, whole.rightSlope.lowerBound)
            let slopeUpper = max(whole.leftSlope.upperBound, whole.rightSlope.upperBound)
            try control.checkpoint()
            return .checkedProjection(context: self, sourceIndex: index, initialTimeSI: initialTime,
                windowSI: window, initialValue: initial.value, windowValue: whole.value,
                almostEverywhereSlope: slopeLower...slopeUpper, lease: outputLease)
        } catch is CancellationError { throw .cancelled }
        catch { throw .underlying(error) }
    }

    private func encloseBound(sourceAt index: Int, over time: ClosedRange<Double>) throws -> Enclosure {
        typealias I = TimingNumericInterval
        try control.checkpoint()
        guard record.sources.indices.contains(index), time.lowerBound.isFinite, time.upperBound.isFinite else {
            throw invalid("source index or time")
        }
        let source = record.sources[index], a = source.authority
        if let value = a.constantVoltage {
            try control.checkpoint()
            return Enclosure(value: value...value, leftSlope: 0...0, rightSlope: 0...0)
        }
        let rise = try I(a.riseSlew!), fall = try I(a.fallSlew!)
        try control.checkpoint(amount: 8)
        let dr = try NativeSTAConservativeCoupling().thresholdSpan(record.thresholds, rising: true)
        let df = try NativeSTAConservativeCoupling().thresholdSpan(record.thresholds, rising: false)
        let sr = try dr.divided(by: rise), sf = try df.divided(by: fall)
        let globalSlope = -sf.upperBound...sr.upperBound
        func global() -> Enclosure { .init(value: 0...1, leftSlope: globalSlope, rightSlope: globalSlope) }
        guard case .clock(let clock) = source.history else {
            try control.checkpoint()
            return global()
        }
        try control.checkpoint(amount: 16)
        let t = try I(time), p = try I(point: clock.period)
        if try I(point: time.upperBound).subtracting(I(point: time.lowerBound)).upperBound >= clock.period {
            try control.checkpoint()
            return global()
        }
        let ramps = try clock.native.ramps(source: source.native, thresholds: record.thresholds)
        let qr = try I(point: a.sourceIsPort ? record.thresholds.inputRise : record.thresholds.outputRise)
            .divided(by: I(point: 100))
        let qf = try I(point: a.sourceIsPort ? record.thresholds.inputFall : record.thresholds.outputFall)
            .divided(by: I(point: 100))
        let fallReference = try ramps.fall.start.adding(I(point: 1).subtracting(qf).multiplied(by: fall.divided(by: df)))
        let cycleRange = try t.subtracting(I(point: ramps.rise.start.lowerBound)).divided(by: p)
        let lower = cycleRange.lowerBound.rounded(.down), upper = cycleRange.upperBound.rounded(.down)
        guard lower.isFinite, upper.isFinite, abs(lower) < 4_503_599_627_370_490,
              abs(upper) < 4_503_599_627_370_490, upper - lower <= 4,
              let first = Int(exactly: lower), let last = Int(exactly: upper) else {
            throw invalid("periodic cycle is not representable")
        }
        var valueLower = 1.0, valueUpper = 0.0, slopeLower = 0.0, slopeUpper = 0.0
        func include(_ value: I, slope: I) {
            valueLower = min(valueLower, max(0, min(1, value.lowerBound)))
            valueUpper = max(valueUpper, max(0, min(1, value.upperBound)))
            slopeLower = min(slopeLower, slope.lowerBound); slopeUpper = max(slopeUpper, slope.upperBound)
        }
        func overlap(_ lower: Double, _ upper: Double) throws -> I? {
            try control.checkpoint()
            let lo = max(time.lowerBound, lower), hi = min(time.upperBound, upper)
            return lo <= hi ? try I(lowerBound: lo, upperBound: hi) : nil
        }
        // For a slab shorter than one period, outward cycle rounding adds at most
        // neighboring cycles. The checked integer guard bounds this loop to seven.
        for cycle in (first - 1)...(last + 1) {
            try control.checkpoint(amount: 24)
            let shift = try I(point: Double(cycle)).multiplied(by: p)
            let rs = try ramps.rise.start.adding(shift), re = try ramps.rise.end.adding(shift)
            let fs = try ramps.fall.start.adding(shift), fe = try ramps.fall.end.adding(shift)
            let next = try ramps.rise.start.adding(shift).adding(p)
            if let part = try overlap(rs.lowerBound, re.upperBound) {
                let v = try qr.adding(part.subtracting(I(clock.riseReference).adding(shift)).multiplied(by: sr))
                include(v, slope: sr)
            }
            if try overlap(re.lowerBound, fs.upperBound) != nil { include(try I(point: 1), slope: try I(point: 0)) }
            if let part = try overlap(fs.lowerBound, fe.upperBound) {
                let v = try qf.subtracting(part.subtracting(fallReference.adding(shift)).multiplied(by: sf))
                include(v, slope: try sf.negated())
            }
            if try overlap(fe.lowerBound, next.upperBound) != nil { include(try I(point: 0), slope: try I(point: 0)) }
        }
        guard valueLower <= valueUpper else { throw invalid("no complete periodic window") }
        try control.checkpoint()
        return Enclosure(value: valueLower...valueUpper, leftSlope: slopeLower...slopeUpper,
            rightSlope: slopeLower...slopeUpper)
    }
    internal func matchesScenario(_ other: STAConservativeSourceContextRecord) throws -> Bool {
        try control.checkpoint(amount: UInt64(other.modeID.utf8.count) + 1)
        try control.checkpoint(amount: UInt64(other.cornerID.utf8.count) + 1)
        return record.modeID == other.modeID && record.cornerID == other.cornerID
    }
    internal func requireSameRecord(_ other: STAConservativeSourceContextRecord) throws {
        func text(_ value: String) throws { try control.checkpoint(amount: UInt64(value.utf8.count) + 1) }
        for r in [record, other] {
            try control.checkpoint()
            try text(r.modeID); try text(r.cornerID); try text(r.modelIdentity)
            try text(r.executionInputIdentity.hexadecimalValue); try text(r.configurationDigest.hexadecimalValue)
            try text(r.library.digest.hexadecimalValue)
            try text(r.library.descriptor.role.rawValue); try text(r.library.descriptor.kind.rawValue)
            try text(r.library.descriptor.format.rawValue)
            for entry in r.sources {
                try control.checkpoint()
                let a = entry.authority
                try text(a.endpoint.name); try text(a.endpoint.ownerNet)
                if case .clock(let clock) = entry.history { try text(clock.rootIdentity) }
                for arc in a.sourceArcs {
                    try control.checkpoint(); try text(arc.cell); try text(arc.pin)
                    if let kind = arc.timingType { try text(kind) }
                    for table in arc.tables { try control.checkpoint(); try text(table.name) }
                }
            }
        }
        guard record == other else { throw invalid("prepared context mismatch") }
    }
    private func invalid(_ reason: String) -> TimingError { .invalidInput("Initial source jet: " + reason) }
}

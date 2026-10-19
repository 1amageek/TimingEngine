import TimingCore

/// Integrates independently checked physical response polynomials and their defects.
internal struct NativeSTAConservativeResidualResponse {
    typealias N = NativeSTAConservativeNumerics
    typealias I = TimingNumericInterval
    typealias K = NativeSTAConservativeCoupling
    typealias C = NativeSTAConservativeResidualCertificate

    let numerical: N

    struct Facts: Sendable {
        let receiverRows: [Int]
        let sourceCount: Int
        let gL1: N.Matrix
        let hL1: N.Matrix
        let direct: N.Matrix
        let hSegments: [C.Segment]
        let hError: N.Matrix
        let hPrimitiveOscillation: N.Matrix
    }

    func prepare(_ certificate: C.Facts, work: inout UInt64) throws -> Facts {
        try numerical.tick(&work)
        let receivers = certificate.receiverRows.count, sources = certificate.sourceCount
        let doubled = sources.multipliedReportingOverflow(by: 2)
        guard sources > 0, !doubled.overflow else { throw invalid("response source dimensions") }
        let columns = doubled.partialValue
        try numerical.slots(receivers)
        var previousRow = -1
        for row in certificate.receiverRows {
            try numerical.tick(&work)
            guard row > previousRow else { throw invalid("response receiver rows are not sorted and unique") }
            previousRow = row
        }
        try validate(certificate.direct, rows: receivers, columns: sources, nonnegative: false, work: &work)
        try validate(certificate.errors.initial, rows: receivers, columns: columns, nonnegative: true, work: &work)
        try validate(certificate.errors.solve, rows: receivers, columns: columns, nonnegative: true, work: &work)
        try validate(certificate.errors.interpolation, rows: receivers, columns: columns, nonnegative: true, work: &work)
        try validate(certificate.errors.tail, rows: receivers, columns: columns, nonnegative: true, work: &work)
        var g = try numerical.matrix(receivers, sources), h = try numerical.matrix(receivers, sources)
        var hError = try numerical.matrix(receivers, sources)
        var primitive = try numerical.matrix(receivers, sources)
        var primitiveLow = try numerical.matrix(receivers, sources), primitiveHigh = try numerical.matrix(receivers, sources)
        for row in 0..<receivers { for source in 0..<sources {
            try numerical.tick(&work)
            g[row, source] = try errors(certificate.errors, row: row, column: source)
            hError[row, source] = try errors(certificate.errors, row: row, column: sources + source)
            h[row, source] = hError[row, source]
        } }
        try numerical.slots(certificate.segments.count, times: 6)
        var hSegments: [C.Segment] = []
        hSegments.reserveCapacity(certificate.segments.count)
        var previousTime = 0.0
        for segment in certificate.segments {
            try numerical.tick(&work)
            guard segment.start.isFinite, segment.end.isFinite, segment.start == previousTime,
                segment.end > segment.start, segment.bernstein.count == 4 else {
                throw invalid("response segments are not a continuous finite positive grid")
            }
            for coefficient in segment.bernstein {
                try validate(coefficient, rows: receivers, columns: columns, nonnegative: false, work: &work)
            }
            let duration = try I(point: segment.end).subtracting(I(point: segment.start))
            guard duration.lowerBound > 0 else { throw invalid("response segment duration not positive") }
            try numerical.slots(4)
            var projected: [N.Matrix] = []
            projected.reserveCapacity(4)
            for coefficient in segment.bernstein {
                var output = try numerical.matrix(receivers, sources)
                for row in 0..<receivers { for source in 0..<sources {
                    try numerical.tick(&work)
                    output[row, source] = coefficient[row, sources + source]
                } }
                projected.append(output)
            }
            for row in 0..<receivers { for source in 0..<sources {
                try numerical.tick(&work)
                g[row, source] = try g[row, source].adding(integral(segment.bernstein[0][row, source],
                    segment.bernstein[1][row, source], segment.bernstein[2][row, source],
                    segment.bernstein[3][row, source], duration: duration, work: &work))
                h[row, source] = try h[row, source].adding(integral(projected[0][row, source],
                    projected[1][row, source], projected[2][row, source], projected[3][row, source],
                    duration: duration, work: &work))
                var value = primitive[row, source]
                for coefficient in projected {
                    try numerical.tick(&work)
                    value = try value.adding(coefficient[row, source].multiplied(by: duration).divided(by: I(point: 4)))
                    primitiveLow[row, source] = try I(point: min(primitiveLow[row, source].lowerBound, value.lowerBound))
                    primitiveHigh[row, source] = try I(point: max(primitiveHigh[row, source].upperBound, value.upperBound))
                }
                primitive[row, source] = value
            } }
            hSegments.append(C.Segment(start: segment.start, end: segment.end, bernstein: projected))
            previousTime = segment.end
        }
        guard receivers == 0 || !certificate.segments.isEmpty else { throw invalid("missing response trajectory") }
        for index in g.values.indices {
            try numerical.tick(&work)
            g.values[index] = try I(point: g.values[index].upperBound)
            h.values[index] = try I(point: h.values[index].upperBound)
            hError.values[index] = try I(point: hError.values[index].upperBound)
            primitive.values[index] = try I(point: primitiveHigh.values[index].subtracting(primitiveLow.values[index]).upperBound)
        }
        try numerical.slots(certificate.direct.values.count)
        return Facts(receiverRows: certificate.receiverRows, sourceCount: sources, gL1: g, hL1: h,
            direct: certificate.direct, hSegments: hSegments, hError: hError, hPrimitiveOscillation: primitive)
    }

    /// The entire checked trajectory error remains in every suffix, including after its horizon.
    func suffix(_ facts: Facts, receiver: Int, source: Int, elapsed: Double,
        work: inout UInt64) throws -> I {
        try numerical.tick(&work)
        guard elapsed.isFinite, elapsed >= 0, receiver >= 0, receiver < facts.receiverRows.count,
            source >= 0, source < facts.sourceCount else { throw invalid("response suffix arguments") }
        var result = facts.hError[receiver, source]
        for segment in facts.hSegments {
            try numerical.tick(&work)
            if segment.end <= elapsed { continue }
            let duration = try I(point: segment.end).subtracting(I(point: segment.start))
            let b0 = segment.bernstein[0][receiver, source], b1 = segment.bernstein[1][receiver, source]
            let b2 = segment.bernstein[2][receiver, source], b3 = segment.bernstein[3][receiver, source]
            if elapsed <= segment.start {
                result = try result.adding(integral(b0, b1, b2, b3, duration: duration, work: &work))
            } else {
                // Rounding the fraction downward integrates an earlier, hence larger, suffix.
                let ratio = try I(point: elapsed).subtracting(I(point: segment.start)).divided(by: duration)
                let fraction = try I(point: max(0, min(1, ratio.lowerBound)))
                let remaining = try I(point: 1).subtracting(fraction)
                let q0 = try blend(b0, b1, fraction: fraction, remaining: remaining)
                let q1 = try blend(b1, b2, fraction: fraction, remaining: remaining)
                let q2 = try blend(b2, b3, fraction: fraction, remaining: remaining)
                let r0 = try blend(q0, q1, fraction: fraction, remaining: remaining)
                let r1 = try blend(q1, q2, fraction: fraction, remaining: remaining)
                let value = try blend(r0, r1, fraction: fraction, remaining: remaining)
                result = try result.adding(integral(value, r1, q2, b3,
                    duration: duration.multiplied(by: remaining), work: &work))
            }
        }
        return try I(point: result.upperBound)
    }

    /// The caller establishes zero cross-source DC incidence before using this conditional radius.
    func aggressorDerivativeBound(prepared: K.ResidualPrepared, receiver: Int, source: Int,
        queryClock: NativeSTAConservativeSourceHistory.Clock?, queryBand: I?, work: inout UInt64) throws -> I {
        try numerical.tick(&work)
        let facts = prepared.facts
        guard facts.receiverRows.indices.contains(receiver), prepared.sources.indices.contains(source),
              facts.sourceCount == prepared.sources.count else { throw invalid("aggressor response dimensions") }
        let maximumSlope = prepared.sourceSlopes[source, 0]
        let direct = try facts.direct[receiver, source].absolute()
        let gain = try direct.adding(facts.hL1[receiver, source])
        var radius = maximumSlope
        if case .dynamic(_, _, let rise, let fall) = prepared.sources[source] {
            let sr = try K().thresholdSpan(prepared.thresholds, rising: true).divided(by: I(point: rise.lowerBound))
            let sf = try K().thresholdSpan(prepared.thresholds, rising: false).divided(by: I(point: fall.lowerBound))
            let centered = try sr.divided(by: I(point: 2)).adding(sf.divided(by: I(point: 2)))
            radius = try I(point: min(maximumSlope.upperBound, centered.upperBound))
        }
        var best = try radius.multiplied(by: gain).upperBound
        guard let history = prepared.sourceHistories[prepared.sources[source].endpoint] else { return try I(point: best) }
        guard let horizon = facts.hSegments.last?.end else { throw invalid("missing conditional response trajectory") }
        var isolated = false
        var clockRamps: (rise: NativeSTAConservativeSourceHistory.Clock.Ramp, fall: NativeSTAConservativeSourceHistory.Clock.Ramp)?
        switch history {
        case .minimumPlateau(let seconds): isolated = seconds >= horizon
        case .clock(let clock):
            try numerical.tick(&work, 4)
            let ramps = try clock.ramps(source: prepared.sources[source], thresholds: prepared.thresholds)
            clockRamps = ramps
            let firstGap = try ramps.fall.start.subtracting(ramps.rise.end)
            let secondGap = try ramps.rise.start.adding(I(point: clock.period)).subtracting(ramps.fall.end)
            isolated = firstGap.lowerBound >= horizon && secondGap.lowerBound >= horizon
        }
        if isolated {
            try numerical.tick(&work)
            let isolatedGain = try direct.adding(facts.hPrimitiveOscillation[receiver, source])
                .adding(facts.hError[receiver, source])
            best = min(best, try maximumSlope.multiplied(by: isolatedGain).upperBound)
        }
        guard case .clock(let clock) = history, let queryClock, let band = queryBand,
              clock.rootIdentity == queryClock.rootIdentity, clock.period == queryClock.period,
              let ramps = clockRamps else { return try I(point: best) }
        let width = try I(point: band.upperBound).subtracting(I(point: band.lowerBound))
        guard width.upperBound < clock.period else { return try I(point: best) }
        func consider(start: I, end: I, currentSlope: Double) throws {
            let middle = band.lowerBound / 2 + band.upperBound / 2
            let startMiddle = start.lowerBound / 2 + start.upperBound / 2
            let cycle = ((middle - startMiddle) / clock.period).rounded(.down)
            guard cycle.isFinite, abs(cycle) < 4_503_599_627_370_495 else {
                throw KError.invalidSourceAuthority("conditional clock cycle offset is not representable")
            }
            for offset in -1...1 {
                try numerical.tick(&work)
                let shift = try I(point: cycle + Double(offset)).multiplied(by: I(point: clock.period))
                let shiftedStart = try start.adding(shift), shiftedEnd = try end.adding(shift)
                guard band.lowerBound > shiftedStart.upperBound, band.upperBound < shiftedEnd.lowerBound else { continue }
                let elapsed = try I(point: band.lowerBound).subtracting(I(point: shiftedStart.upperBound))
                guard elapsed.lowerBound > 0 else { continue }
                let tail = try suffix(facts, receiver: receiver, source: source, elapsed: elapsed.lowerBound, work: &work)
                let scale = try maximumSlope.adding(I(point: currentSlope))
                best = min(best, try scale.multiplied(by: tail).upperBound)
            }
        }
        try consider(start: ramps.rise.start, end: ramps.rise.end, currentSlope: ramps.rise.slopeUpperBound)
        try consider(start: ramps.fall.start, end: ramps.fall.end, currentSlope: ramps.fall.slopeUpperBound)
        try consider(start: ramps.rise.end, end: ramps.fall.start, currentSlope: 0)
        try consider(start: ramps.fall.end, end: ramps.rise.start.adding(I(point: clock.period)), currentSlope: 0)
        return try I(point: best)
    }

    func bounds(prepared: K.ResidualPrepared, source: TimingParasitics.Endpoint,
        sink: TimingParasitics.Endpoint, edge: TimingEdge, sourceSlew: ClosedRange<Double>,
        work: inout UInt64) throws -> K.Bounds {
        try numerical.tick(&work); try numerical.slots(8)
        guard let column = prepared.sourceIndices[source], column >= 0, column < prepared.sources.count,
            prepared.endpointSource[sink] == column, prepared.sources[column].endpoint == source else {
            throw KError.invalidPrimitive("requested source/receiver has no canonical resistive binding")
        }
        guard case .dynamic(_, let sourceIsPort, let rise, let fall) = prepared.sources[column] else {
            throw KError.invalidSourceAuthority("constant source cannot have a transition")
        }
        guard edge == .rise || edge == .fall else { throw KError.invalidSourceAuthority("unknown requested edge") }
        let rising = edge == .rise, admitted = rising ? rise : fall
        guard sourceSlew.lowerBound.isFinite, sourceSlew.upperBound.isFinite, sourceSlew.lowerBound > 0,
            sourceSlew.lowerBound >= admitted.lowerBound, sourceSlew.upperBound <= admitted.upperBound else {
            throw KError.invalidSourceAuthority("requested slew outside global source domain")
        }
        let thresholds = prepared.thresholds, span = try K().thresholdSpan(thresholds, rising: rising)
        let slope = try span.divided(by: I(sourceSlew)), hundred = try I(point: 100), one = try I(point: 1)
        let physicalLower = try I(point: rising ? thresholds.slewLowerRise : thresholds.slewLowerFall).divided(by: hundred)
        let physicalUpper = try I(point: rising ? thresholds.slewUpperRise : thresholds.slewUpperFall).divided(by: hundred)
        let lower = rising ? physicalLower : try one.subtracting(physicalUpper)
        let upper = rising ? physicalUpper : try one.subtracting(physicalLower)
        let physicalReceiver = try I(point: rising ? thresholds.inputRise : thresholds.inputFall).divided(by: hundred)
        let physicalDriver = try I(point: sourceIsPort
            ? (rising ? thresholds.inputRise : thresholds.inputFall)
            : (rising ? thresholds.outputRise : thresholds.outputFall)).divided(by: hundred)
        let receiverThreshold = rising ? physicalReceiver : try one.subtracting(physicalReceiver)
        let driverThreshold = rising ? physicalDriver : try one.subtracting(physicalDriver)
        guard let physicalRow = prepared.endpointRows[sink] else {
            let delay = try receiverThreshold.subtracting(driverThreshold).divided(by: slope)
            return K.Bounds(delay: delay.lowerBound...delay.upperBound, slew: sourceSlew,
                voltageErrorUpperBound: 0, minimumCrossingDerivative: slope.lowerBound,
                maximumAbsoluteDerivative: slope.upperBound, admittedSourceSlew: admitted)
        }
        let facts = prepared.facts, sources = prepared.sources.count
        guard facts.sourceCount == sources else { throw invalid("response source inventory mismatch") }
        try validate(prepared.sourceSlopes, rows: sources, columns: 1, nonnegative: true, work: &work)
        var receiver: Int?
        for index in facts.receiverRows.indices {
            try numerical.tick(&work)
            if facts.receiverRows[index] == physicalRow { receiver = index; break }
        }
        guard let row = receiver else { throw invalid("requested physical receiver was not certified") }
        var ownIncidence = false
        for offset in prepared.dcIncidence.rowOffsets[physicalRow]..<prepared.dcIncidence.rowOffsets[physicalRow + 1] {
            try numerical.tick(&work)
            let source = prepared.dcIncidence.columnIndices[offset], value = prepared.dcIncidence.values[offset]
            let expected = source == column ? 1.0 : 0.0
            guard value.lowerBound == expected, value.upperBound == expected else {
                throw invalid("conditional response requires exact canonical DC incidence")
            }
            if source == column { ownIncidence = true }
        }
        guard ownIncidence else { throw invalid("missing own-source DC incidence") }
        var voltageError = try I(point: 0), maximumDerivative = try I(point: 0), aggressorDerivative = try I(point: 0)
        for other in 0..<sources {
            try numerical.tick(&work)
            let slopeBound = prepared.sourceSlopes[other, 0]
            voltageError = try voltageError.adding(slopeBound.multiplied(by: facts.gL1[row, other]))
            let derivative = try slopeBound.multiplied(by: facts.direct[row, other].absolute().adding(facts.hL1[row, other]))
            maximumDerivative = try maximumDerivative.adding(derivative)
        }
        let error = voltageError.upperBound
        let upperMargin = try one.subtracting(upper), receiverMargin = try one.subtracting(receiverThreshold)
        guard error < lower.lowerBound, error < upperMargin.lowerBound,
            error < receiverThreshold.lowerBound, error < receiverMargin.lowerBound else {
            throw KError.unprovedCrossing(source: source, sink: sink, edge: edge)
        }
        let errorInterval = try I(lowerBound: -error, upperBound: error)
        let delay = try receiverThreshold.subtracting(driverThreshold).adding(errorInterval).divided(by: slope)
        let twiceError = try I(point: error).multiplied(by: I(point: 2))
        let slewTime = try span.adding(I(lowerBound: -twiceError.upperBound, upperBound: twiceError.upperBound)).divided(by: slope)
        let delta = try I(point: min(lower.lowerBound, receiverThreshold.lowerBound)).subtracting(I(point: error)).divided(by: slope)
        guard delta.lowerBound > 0 else { throw KError.unprovedCrossing(source: source, sink: sink, edge: edge) }
        let tail = try suffix(facts, receiver: row, source: column, elapsed: delta.lowerBound, work: &work)
        let own = try prepared.sourceSlopes[column, 0].adding(I(point: slope.upperBound)).multiplied(by: tail)
        var queryClock: NativeSTAConservativeSourceHistory.Clock?, queryBand: I?
        if let history = prepared.sourceHistories[source], case .clock(let clock) = history {
            queryClock = clock
            let reference = rising ? clock.riseReference : clock.fallReference
            let crossingBand = try I(lowerBound: min(lower.lowerBound, receiverThreshold.lowerBound),
                                     upperBound: max(upper.upperBound, receiverThreshold.upperBound))
            queryBand = try I(reference).adding(crossingBand.adding(errorInterval).subtracting(driverThreshold).divided(by: slope))
        }
        for other in 0..<sources where other != column {
            try numerical.tick(&work)
            aggressorDerivative = try aggressorDerivative.adding(aggressorDerivativeBound(prepared: prepared,
                receiver: row, source: other, queryClock: queryClock, queryBand: queryBand, work: &work))
        }
        let derivativeInterval = try slope.subtracting(own).subtracting(aggressorDerivative)
        let minimumDerivative = derivativeInterval.lowerBound
        guard minimumDerivative > 0 else {
            let querySlope = slope.lowerBound...slope.upperBound
            let derivativeRange = derivativeInterval.lowerBound...derivativeInterval.upperBound
            let ownHistorySlope = prepared.sourceSlopes[column, 0].upperBound
            let ownHError = facts.hError[row, column].upperBound
            guard let horizon = facts.hSegments.last?.end else { throw invalid("missing failed-transition trajectory") }
            try numerical.tick(&work)
            try numerical.slots(16)
            try numerical.slots(sources, times: 8)
            var contributions: [NativeSTAConservativeTransitionDiagnostic.Contribution] = []
            contributions.reserveCapacity(sources)
            for other in 0..<sources {
                try numerical.tick(&work)
                let historySlope = prepared.sourceSlopes[other, 0]
                let direct = try facts.direct[row, other].absolute()
                let derivative: I
                if other == column {
                    derivative = try historySlope.multiplied(by: direct.adding(facts.hL1[row, other]))
                } else {
                    derivative = try aggressorDerivativeBound(prepared: prepared, receiver: row, source: other,
                        queryClock: queryClock, queryBand: queryBand, work: &work)
                }
                contributions.append(.init(source: prepared.sources[other].endpoint, isAggressor: other != column,
                    slopeUpperBound: historySlope.upperBound, directMagnitudeUpperBound: direct.upperBound,
                    hL1UpperBound: facts.hL1[row, other].upperBound, hErrorUpperBound: facts.hError[row, other].upperBound,
                    derivativeUpperBound: derivative.upperBound))
            }
            try numerical.tick(&work, 0)
            let diagnostic = NativeSTAConservativeTransitionDiagnostic(voltageErrorUpperBound: error,
                querySlope: querySlope, ownHistorySlopeUpperBound: ownHistorySlope,
                deltaLowerBound: delta.lowerBound, ownTailUpperBound: tail.upperBound, ownHErrorUpperBound: ownHError,
                ownTermUpperBound: own.upperBound, aggressorDerivativeUpperBound: aggressorDerivative.upperBound,
                minimumDerivative: derivativeRange, maximumDerivativeUpperBound: maximumDerivative.upperBound,
                horizon: horizon, segmentCount: facts.hSegments.count, contributions: contributions)
            throw KError.unprovedUniqueTransition(source: source, sink: sink, edge: edge, diagnostic: diagnostic)
        }
        guard maximumDerivative.upperBound > 0 else { throw KError.inconsistentBounds("nonpositive absolute derivative bound") }
        let minimumSlew = try span.divided(by: I(point: maximumDerivative.upperBound)).lowerBound
        let slewLower = max(slewTime.lowerBound, minimumSlew), slewUpper = slewTime.upperBound
        guard slewLower > 0, slewLower <= slewUpper else { throw KError.inconsistentBounds("empty positive slew intersection") }
        return K.Bounds(delay: delay.lowerBound...delay.upperBound, slew: slewLower...slewUpper,
            voltageErrorUpperBound: error, minimumCrossingDerivative: minimumDerivative,
            maximumAbsoluteDerivative: maximumDerivative.upperBound, admittedSourceSlew: admitted)
    }

    private typealias KError = NativeSTAConservativeCouplingError

    private func invalid(_ message: String) -> KError { .invalidCertificate(message) }

    private func validate(_ matrix: N.Matrix, rows: Int, columns: Int, nonnegative: Bool,
        work: inout UInt64) throws {
        let count = rows.multipliedReportingOverflow(by: columns)
        guard rows >= 0, columns >= 0, !count.overflow, matrix.rows == rows, matrix.columns == columns,
            matrix.values.count == count.partialValue else { throw invalid("response matrix dimensions") }
        for value in matrix.values {
            try numerical.tick(&work)
            guard value.lowerBound.isFinite, value.upperBound.isFinite,
                !nonnegative || value.lowerBound >= 0 else { throw invalid("response matrix value") }
        }
    }

    private func errors(_ errors: C.Errors, row: Int, column: Int) throws -> I {
        try errors.initial[row, column].adding(errors.solve[row, column])
            .adding(errors.interpolation[row, column]).adding(errors.tail[row, column])
    }

    private func integral(_ b0: I, _ b1: I, _ b2: I, _ b3: I, duration: I,
        work: inout UInt64) throws -> I {
        try numerical.tick(&work)
        return try b0.absolute().adding(b1.absolute()).adding(b2.absolute()).adding(b3.absolute())
            .multiplied(by: duration).divided(by: I(point: 4))
    }

    private func blend(_ first: I, _ second: I, fraction: I, remaining: I) throws -> I {
        try first.multiplied(by: remaining).adding(second.multiplied(by: fraction))
    }
}

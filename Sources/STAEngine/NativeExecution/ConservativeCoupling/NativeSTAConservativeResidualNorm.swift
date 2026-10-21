import TimingCore

/// A native solve proposes z; the Stieltjes barrier and residual alone bound the G-inverse norm.
internal struct NativeSTAConservativeResidualNorm {
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias I = TimingNumericInterval
    let numerical: N
    let conductance: S.CSR
    let weight: N.Matrix
    private let imageLower: [Double]
    private let imagePayload: LibertySourceStorageReservation?

    init(numerical: N, conductance: S.CSR, weight: N.Matrix, work: inout UInt64) throws {
        guard conductance.rows == conductance.columns, weight.rows == conductance.rows,
              weight.columns == 1, weight.values.count == weight.rows else { throw Self.invalid("norm barrier shape") }
        self.numerical = numerical; self.conductance = conductance; self.weight = weight
        try numerical.slots(conductance.rows)
        imagePayload = try numerical.budget.reservePayload(Double.self, capacity: conductance.rows, kind: .liveOwnedBytes)
        var lower = [Double](); lower.reserveCapacity(conductance.rows)
        for value in weight.values {
            try numerical.tick(&work)
            guard value.lowerBound == value.upperBound else { throw Self.invalid("norm barrier is not point data") }
            guard value.lowerBound > 0 else { throw Self.unproved("G norm weight is not positive") }
        }
        for row in 0..<conductance.rows {
            try numerical.tick(&work, conductance.rowOffsets[row + 1] - conductance.rowOffsets[row] + 1)
            var sum = try I(point: 0), diagonal = false
            for k in conductance.rowOffsets[row]..<conductance.rowOffsets[row + 1] {
                let column = conductance.columnIndices[k], value = conductance.values[k]
                if row == column {
                    diagonal = true
                    guard value.lowerBound > 0 else { throw Self.unproved("G norm diagonal is not positive") }
                } else {
                    guard value.upperBound <= 0 else { throw Self.invalid("G norm operator is not Stieltjes") }
                }
                sum = try sum.adding(value.multiplied(by: weight[column, 0]))
            }
            guard diagonal, sum.lowerBound > 0 else { throw Self.unproved("positive G weight image not certified") }
            lower.append(sum.lowerBound)
        }
        imageLower = lower
    }

    /// Each returned point is an upper norm bound; no native factor status is trusted.
    func upper(_ rhs: N.Matrix, candidate: N.Matrix, work: inout UInt64) throws -> N.Matrix {
        let count = rhs.rows.multipliedReportingOverflow(by: rhs.columns)
        guard rhs.rows == conductance.rows, rhs.columns >= 0, !count.overflow,
              rhs.values.count == count.partialValue, candidate.rows == rhs.rows,
              candidate.columns == rhs.columns, candidate.values.count == count.partialValue else {
            throw Self.invalid("G norm candidate shape")
        }
        try numerical.tick(&work, count.partialValue)
        for value in candidate.values {
            guard value.lowerBound == value.upperBound else { throw Self.invalid("G norm candidate is not point data") }
        }
        try numerical.tick(&work, 0)
        let columnWork = conductance.values.count.addingReportingOverflow(rhs.rows)
        guard !columnWork.overflow else { throw Self.invalid("G norm column work overflow") }
        var result = try numerical.matrix(1, rhs.columns)
        for column in 0..<rhs.columns {
            var quadratic = try I(point: 0), weightedResidual = try I(point: 0)
            var scale = 0.0, knownZero = true
            try numerical.tick(&work, columnWork.partialValue)
            for row in 0..<rhs.rows {
                let b = rhs[row, column], z = candidate[row, column]
                knownZero = knownZero && b.lowerBound == 0 && b.upperBound == 0
                var gz = try I(point: 0)
                for k in conductance.rowOffsets[row]..<conductance.rowOffsets[row + 1] {
                    gz = try gz.adding(conductance.values[k].multiplied(by: candidate[conductance.columnIndices[k], column]))
                }
                let residual = try b.subtracting(gz).absolute()
                scale = max(scale, try residual.divided(by: I(point: imageLower[row])).upperBound)
                weightedResidual = try weightedResidual.adding(residual.multiplied(by: weight[row, 0]))
                quadratic = try quadratic.adding(z.multiplied(by: b.adding(b).subtracting(gz)))
            }
            try numerical.tick(&work, 0)
            if knownZero { continue }
            let squared = try quadratic.adding(I(point: scale).multiplied(by: weightedResidual)).upperBound
            guard squared > 0 else { throw Self.unproved("positive squared G norm upper bound not certified") }
            result[0, column] = try I(point: squareRootUpper(squared, work: &work))
        }
        try numerical.tick(&work, 0)
        return result
    }

    func squareRootUpper(_ value: Double, work: inout UInt64) throws -> Double {
        try numerical.tick(&work)
        guard value.isFinite, value >= 0 else { throw Self.invalid("invalid squared norm") }
        if value == 0 { return 0 }
        var root = value.squareRoot().nextUp
        guard root.isFinite else { throw Self.unproved("finite norm root not proposed") }
        for attempt in 0..<2 {
            try numerical.tick(&work)
            if try I(point: root).multiplied(by: I(point: root)).lowerBound >= value { return root }
            if attempt == 0 {
                root *= 2
                guard root.isFinite else { throw Self.unproved("finite widened norm root not proposed") }
            }
        }
        throw Self.unproved("norm square root upper bound not certified")
    }

    private static func invalid(_ reason: String) -> NativeSTAConservativeCouplingError {
        .invalidPrimitive(reason)
    }
    private static func unproved(_ reason: String) -> NativeSTAConservativeCandidateNotCertified {
        .init(reason: reason)
    }
}

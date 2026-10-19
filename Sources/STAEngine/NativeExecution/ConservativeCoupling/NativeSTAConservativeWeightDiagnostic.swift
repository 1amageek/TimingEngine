import TimingCore

/// Failure-only evidence; a non-Hurwitz comparison witness never authorizes timing bounds.
internal struct NativeSTAConservativeWeightDiagnostic: Sendable, Equatable, CustomStringConvertible {
    enum PrincipalWitness: Sendable, Equatable, CustomStringConvertible {
        case diagonal(row: Int, coefficient: Double)
        case reciprocalPair(first: Int, second: Int, firstDiagonal: Double, secondDiagonal: Double,
                            forward: Double, reverse: Double, determinantUpper: Double)

        var description: String {
            switch self {
            case .diagonal(let row, let coefficient):
                return "diagonal transformedCoordinateRow=\(row) coefficient=\(coefficient)"
            case .reciprocalPair(let first, let second, let firstDiagonal, let secondDiagonal,
                                 let forward, let reverse, let determinantUpper):
                return "reciprocalPair transformedCoordinateRows=\(first),\(second) Fii=\(firstDiagonal) Fjj=\(secondDiagonal) Fij=\(forward) Fji=\(reverse) determinantUpper=\(determinantUpper)"
            }
        }
    }

    let principalNonHurwitzWitness: PrincipalWitness?
    let dimension: Int
    let nonzeros: Int
    let minimumWeight: Double
    let maximumWeight: Double
    let minimumWeightRow: Int
    let negativeWeights: Int
    let zeroWeights: Int
    let trueResidualMaximumAbsoluteUpper: Double
    let minimumDirectSupportedLower: Double?
    let minimumResidualDerivedSupportedLower: Double?
    let minimumCertifiedSupportedLower: Double?
    let comparisonIsMetzler: Bool
    let comparisonNonHurwitzProved: Bool

    var description: String {
        "rows=\(dimension) nnz=\(nonzeros) minimumWeight=\(minimumWeight) maximumWeight=\(maximumWeight) minimumWeightRow=\(minimumWeightRow) negativeWeights=\(negativeWeights) zeroWeights=\(zeroWeights) trueResidualMaximumAbsoluteUpper=\(trueResidualMaximumAbsoluteUpper) minimumDirectSupportedLower=\(text(minimumDirectSupportedLower)) minimumResidualDerivedSupportedLower=\(text(minimumResidualDerivedSupportedLower)) minimumCertifiedSupportedLower=\(text(minimumCertifiedSupportedLower)) comparisonIsMetzler=\(comparisonIsMetzler) comparisonNonHurwitzProved=\(comparisonNonHurwitzProved) principalNonHurwitzWitness=\(principalNonHurwitzWitness.map { $0.description } ?? "none")"
    }

    static func evaluate(comparison f: NativeSTAConservativeSparseNumerics.CSR,
        candidate w: NativeSTAConservativeNumerics.Matrix, numerical: NativeSTAConservativeNumerics,
        work: inout UInt64) throws -> Self {
        typealias I = TimingNumericInterval
        let n = f.rows, solver = NativeSTAConservativeSparseNumerics(numerical: numerical)
        guard n > 0, f.columns == n, w.rows == n, w.columns == 1, w.values.count == n else {
            throw NativeSTAConservativeCouplingError.invalidCertificate("weight diagnostic shape")
        }
        let principal = try assessPrincipal(comparison: f, numerical: numerical, work: &work)
        let metzler = principal.metzler
        try numerical.slots(14)
        var z = try numerical.matrix(n, 1)
        var minimum = Double.greatestFiniteMagnitude, maximum = -Double.greatestFiniteMagnitude
        var minimumRow = 0, negativeCount = 0, zeroCount = 0
        for i in 0..<n {
            try numerical.tick(&work)
            let value = w[i, 0]
            guard value.lowerBound == value.upperBound else {
                throw NativeSTAConservativeCouplingError.invalidCertificate("weight diagnostic requires a concrete candidate")
            }
            if value.lowerBound < minimum { minimum = value.lowerBound; minimumRow = i }
            maximum = max(maximum, value.upperBound)
            if value.lowerBound < 0 { negativeCount += 1; z[i, 0] = try I(point: -value.lowerBound) }
            if value.lowerBound == 0 { zeroCount += 1 }
        }
        let fw = try solver.product(f, w, work: &work)
        let fz = try solver.product(f, z, work: &work)
        var residualMaximum = 0.0
        var directMinimum: Double?, residualMinimum: Double?, certifiedMinimum: Double?
        for i in 0..<n {
            try numerical.tick(&work)
            let h = try fw[i, 0].negated().subtracting(I(point: 1))
            residualMaximum = max(residualMaximum, try h.absolute().upperBound)
            if z[i, 0].lowerBound > 0 {
                let direct = fz[i, 0].lowerBound
                // On this support wPlus[i] is exactly zero. Metzler off-diagonals give
                // Fz = 1 + h + FwPlus >= 1 + h, with no inverse or stopping tolerance.
                let derived = try I(point: 1).adding(h).lowerBound
                directMinimum = min(directMinimum ?? direct, direct)
                residualMinimum = min(residualMinimum ?? derived, derived)
                let certified = metzler ? max(direct, derived) : direct
                certifiedMinimum = min(certifiedMinimum ?? certified, certified)
            }
            // On zero support the diagonal contribution is exactly zero, and every
            // off-diagonal term is nonnegative. This proves Fz[i] >= 0 structurally.
        }
        let proved = principal.witness != nil || (metzler && negativeCount > 0 && (certifiedMinimum.map { $0 >= 0 } ?? false))
        return Self(principalNonHurwitzWitness: principal.witness, dimension: n, nonzeros: f.values.count, minimumWeight: minimum, maximumWeight: maximum,
            minimumWeightRow: minimumRow, negativeWeights: negativeCount, zeroWeights: zeroCount,
            trueResidualMaximumAbsoluteUpper: residualMaximum, minimumDirectSupportedLower: directMinimum,
            minimumResidualDerivedSupportedLower: residualMinimum, minimumCertifiedSupportedLower: certifiedMinimum,
            comparisonIsMetzler: metzler, comparisonNonHurwitzProved: proved)
    }

    /// A failure-only precheck remains available even if an ordinary weight proposal overflows.
    static func principalWitness(comparison f: NativeSTAConservativeSparseNumerics.CSR,
        numerical: NativeSTAConservativeNumerics, work: inout UInt64) throws -> PrincipalWitness? {
        try assessPrincipal(comparison: f, numerical: numerical, work: &work).witness
    }

    private static func assessPrincipal(comparison f: NativeSTAConservativeSparseNumerics.CSR,
        numerical: NativeSTAConservativeNumerics, work: inout UInt64) throws -> (metzler: Bool, witness: PrincipalWitness?) {
        typealias I = TimingNumericInterval
        let n = f.rows, count = f.values.count
        guard n > 0, n < Int.max, f.columns == n, f.rowOffsets.count == n + 1,
              f.rowOffsets.first == 0, f.rowOffsets.last == count, f.columnIndices.count == count else {
            throw NativeSTAConservativeCouplingError.invalidCertificate("principal diagnostic CSR shape")
        }
        try numerical.slots(n); try numerical.slots(8)
        var diagonal = Array(repeating: 0.0, count: n)
        var metzler = true
        for row in 0..<n {
            try numerical.tick(&work)
            let start = f.rowOffsets[row], end = f.rowOffsets[row + 1]
            guard start >= 0, start <= end, end <= count else {
                throw NativeSTAConservativeCouplingError.invalidCertificate("principal diagnostic CSR offsets")
            }
            var previous = -1
            for offset in start..<end {
                try numerical.tick(&work)
                let column = f.columnIndices[offset], value = f.values[offset]
                guard column > previous, column >= 0, column < n, value.lowerBound.isFinite,
                      value.lowerBound == value.upperBound else {
                    throw NativeSTAConservativeCouplingError.invalidCertificate("principal diagnostic requires sorted unique exact point coefficients")
                }
                previous = column
                if column == row { diagonal[row] = value.lowerBound }
                else if value.lowerBound < 0 { metzler = false }
            }
        }
        guard metzler else { return (false, nil) }
        for row in 0..<n {
            try numerical.tick(&work)
            // An absent diagonal is exactly zero. A Metzler principal 1x1 spectral bound suffices.
            if diagonal[row] >= 0 { return (true, .diagonal(row: row, coefficient: diagonal[row])) }
        }
        for row in 0..<n {
            for offset in f.rowOffsets[row]..<f.rowOffsets[row + 1] {
                try numerical.tick(&work)
                let column = f.columnIndices[offset], forward = f.values[offset]
                if column <= row || forward.lowerBound == 0 { continue }
                var low = f.rowOffsets[column], high = f.rowOffsets[column + 1]
                while low < high {
                    try numerical.tick(&work)
                    let middle = low + (high - low) / 2
                    if f.columnIndices[middle] < row { low = middle + 1 } else { high = middle }
                }
                guard low < f.rowOffsets[column + 1], f.columnIndices[low] == row else { continue }
                let reverse = f.values[low]
                if reverse.lowerBound == 0 { continue }
                try numerical.tick(&work, 3)
                let determinant = try I(point: diagonal[row]).multiplied(by: I(point: diagonal[column]))
                    .subtracting(forward.multiplied(by: reverse))
                // Negative determinant and negative trace imply a positive principal eigenvalue.
                // Metzler principal spectral monotonicity transfers that obstruction to the full F.
                if determinant.upperBound < 0 {
                    return (true, .reciprocalPair(first: row, second: column,
                        firstDiagonal: diagonal[row], secondDiagonal: diagonal[column],
                        forward: forward.lowerBound, reverse: reverse.lowerBound,
                        determinantUpper: determinant.upperBound))
                }
            }
        }
        return (true, nil)
    }

    private func text(_ value: Double?) -> String { value.map { String($0) } ?? "none" }
}

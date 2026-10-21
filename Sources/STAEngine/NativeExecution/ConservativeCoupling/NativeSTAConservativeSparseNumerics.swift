import TimingCore

/// Sparse candidate arithmetic is untrusted until outward comparison/residual verification.
internal struct NativeSTAConservativeSparseNumerics {
    typealias N = NativeSTAConservativeNumerics
    typealias I = TimingNumericInterval
    struct CSR: Sendable {
        let rows: Int
        let columns: Int
        let rowOffsets: [Int]
        let columnIndices: [Int]
        let values: [I]
        fileprivate let offsetPayload: LibertySourceStorageReservation?
        fileprivate let indexPayload: LibertySourceStorageReservation?
        fileprivate let valuePayload: LibertySourceStorageReservation?
        fileprivate init(rows: Int, columns: Int, rowOffsets: [Int], columnIndices: [Int], values: [I],
                         offsetPayload: LibertySourceStorageReservation? = nil,
                         indexPayload: LibertySourceStorageReservation? = nil,
                         valuePayload: LibertySourceStorageReservation? = nil) {
            self.rows = rows; self.columns = columns; self.rowOffsets = rowOffsets
            self.columnIndices = columnIndices; self.values = values
            self.offsetPayload = offsetPayload; self.indexPayload = indexPayload; self.valuePayload = valuePayload
        }
    }
    let numerical: N

    func fromRows<Rows: Collection>(_ rows: Rows, columns: Int, work: inout UInt64) throws -> CSR where Rows.Element == [Int: I] {
        guard columns >= 0 else { throw invalid("negative sparse dimension") }
        var count = 0
        for row in rows {
            try numerical.tick(&work, row.count + 1)
            for (column, value) in row {
                guard column >= 0, column < columns else { throw invalid("sparse column index") }
                if !isZero(value) {
                    let next = count.addingReportingOverflow(1)
                    guard !next.overflow else { throw invalid("sparse entry overflow") }
                    count = next.partialValue
                }
            }
        }
        try numerical.slots(rows.count + 1); try numerical.slots(count, times: 2)
        let offsetPayload = try numerical.budget.reservePayload(Int.self, capacity: rows.count + 1, kind: .liveOwnedBytes)
        let indexPayload = try numerical.budget.reservePayload(Int.self, capacity: count, kind: .liveOwnedBytes)
        let valuePayload = try numerical.budget.reservePayload(I.self, capacity: count, kind: .liveOwnedBytes)
        var offsets = [Int](); offsets.reserveCapacity(rows.count + 1); offsets.append(0)
        var indices = [Int](); indices.reserveCapacity(count)
        var values = [I](); values.reserveCapacity(count)
        for row in rows {
            try numerical.slots(row.count)
            let keyPayload = try numerical.budget.reservePayload(Int.self, capacity: row.count, kind: .temporaryBytes)
            // Sorting may hold its input and merge scratch simultaneously.
            let sortPayload = try numerical.budget.reservePayload(Int.self, capacity: row.count, kind: .temporaryBytes)
            defer { withExtendedLifetime((keyPayload, sortPayload)) {} }
            try numerical.budget.chargeScheduledWork(UInt64(row.count))
            let keys = try row.keys.sorted { left, right in
                try numerical.tick(&work)
                return left < right
            }
            try numerical.tick(&work, row.count + 1)
            for column in keys {
                guard let value = row[column] else { throw invalid("sparse row changed") }
                if !isZero(value) { indices.append(column); values.append(value) }
            }
            offsets.append(values.count)
        }
        return CSR(rows: rows.count, columns: columns, rowOffsets: offsets, columnIndices: indices, values: values,
                   offsetPayload: offsetPayload, indexPayload: indexPayload, valuePayload: valuePayload)
    }

    func product(_ a: CSR, _ rhs: N.Matrix, work: inout UInt64) throws -> N.Matrix {
        guard a.columns == rhs.rows else { throw invalid("sparse product shape") }
        var result = try numerical.matrix(a.rows, rhs.columns)
        for row in 0..<a.rows {
            for column in 0..<rhs.columns {
                try numerical.tick(&work, a.rowOffsets[row + 1] - a.rowOffsets[row] + 1)
                var sum = try I(point: 0)
                for index in a.rowOffsets[row]..<a.rowOffsets[row + 1] {
                    sum = try sum.adding(a.values[index].multiplied(by: rhs[a.columnIndices[index], column]))
                }
                result[row, column] = sum
            }
        }
        return result
    }

    func negated(_ a: CSR, work: inout UInt64) throws -> CSR {
        try numerical.slots(a.values.count)
        let payload = try numerical.budget.reservePayload(I.self, capacity: a.values.count, kind: .liveOwnedBytes)
        var values = [I](); values.reserveCapacity(a.values.count)
        for value in a.values { try numerical.tick(&work); values.append(try value.negated()) }
        return CSR(rows: a.rows, columns: a.columns, rowOffsets: a.rowOffsets, columnIndices: a.columnIndices, values: values,
                   offsetPayload: a.offsetPayload, indexPayload: a.indexPayload, valuePayload: payload)
    }

    func magnitude(_ a: CSR, work: inout UInt64) throws -> CSR {
        try numerical.slots(a.values.count)
        let payload = try numerical.budget.reservePayload(I.self, capacity: a.values.count, kind: .liveOwnedBytes)
        var values = [I](); values.reserveCapacity(a.values.count)
        for value in a.values { try numerical.tick(&work); values.append(try I(point: value.absolute().upperBound)) }
        return CSR(rows: a.rows, columns: a.columns, rowOffsets: a.rowOffsets, columnIndices: a.columnIndices, values: values,
                   offsetPayload: a.offsetPayload, indexPayload: a.indexPayload, valuePayload: payload)
    }

    /// Left-Jacobi BiCGStab proposes finite binary point values; convergence is not proof.
    func approximateSolve(_ a: CSR, _ rhs: N.Matrix, maximumIterations: Int,
                          work: inout UInt64) throws -> N.Matrix {
        let n = a.rows
        guard n == a.columns, rhs.rows == n, maximumIterations > 0 else { throw invalid("sparse candidate shape/iterations") }
        var result = try numerical.matrix(n, rhs.columns)
        if n == 0 { return result }
        try numerical.slots(n, times: 9); try numerical.slots(a.values.count)
        let vectorCount = n.multipliedReportingOverflow(by: 9)
        guard !vectorCount.overflow else { throw invalid("sparse scratch count overflow") }
        let vectorPayload = try numerical.budget.reservePayload(Double.self, capacity: vectorCount.partialValue, kind: .temporaryBytes)
        let valuesPayload = try numerical.budget.reservePayload(Double.self, capacity: a.values.count, kind: .temporaryBytes)
        defer { withExtendedLifetime((vectorPayload, valuesPayload)) {} }
        try numerical.budget.chargeScheduledWork(UInt64(vectorCount.partialValue))
        try numerical.budget.chargeScheduledWork(UInt64(a.values.count))
        var diagonal = Array(repeating: 0.0, count: n)
        var values = Array(repeating: 0.0, count: a.values.count)
        let sparseWork = a.values.count.addingReportingOverflow(n)
        guard !sparseWork.overflow else { throw invalid("sparse candidate operation count overflow") }
        try numerical.tick(&work, sparseWork.partialValue)
        for row in 0..<n {
            for index in a.rowOffsets[row]..<a.rowOffsets[row + 1] {
                let value = midpoint(a.values[index])
                values[index] = value
                if a.columnIndices[index] == row { diagonal[row] = value }
            }
            guard diagonal[row].isFinite, diagonal[row] != 0 else { throw NativeSTAConservativeCandidateNotCertified(reason: "zero candidate preconditioner") }
        }
        try numerical.tick(&work, 0)
        var x = Array(repeating: 0.0, count: n), r = x, shadow = x, p = x, v = x, s = x, t = x
        var b = x
        // COW scratch buffers become independent before iteration; their capacities are reserved above.
        func multiply(_ input: [Double], into output: inout [Double], work: inout UInt64) throws {
            try numerical.tick(&work, sparseWork.partialValue)
            for row in 0..<n {
                var sum = 0.0
                for index in a.rowOffsets[row]..<a.rowOffsets[row + 1] { sum += values[index] * input[a.columnIndices[index]] }
                output[row] = sum / diagonal[row]
                guard output[row].isFinite else { throw NativeSTAConservativeCandidateNotCertified(reason: "nonfinite candidate product") }
            }
            try numerical.tick(&work, 0)
        }
        func dot(_ lhs: [Double], _ rhs: [Double], work: inout UInt64) throws -> Double {
            try numerical.tick(&work, n)
            var sum = 0.0
            for i in 0..<n { sum += lhs[i] * rhs[i] }
            try numerical.tick(&work, 0)
            guard sum.isFinite else { throw NativeSTAConservativeCandidateNotCertified(reason: "nonfinite candidate dot product") }
            return sum
        }
        let tolerance = Double.ulpOfOne.squareRoot()
        for column in 0..<rhs.columns {
            var scale = 0.0
            try numerical.tick(&work, n)
            for i in 0..<n {
                b[i] = midpoint(rhs[i, column]) / diagonal[i]
                guard b[i].isFinite else { throw NativeSTAConservativeCandidateNotCertified(reason: "nonfinite candidate right side") }
                scale = max(scale, abs(b[i]))
                x[i] = 0; p[i] = 0; v[i] = 0
            }
            try numerical.tick(&work, 0)
            if scale == 0 { continue }
            try numerical.tick(&work, n)
            for i in 0..<n { r[i] = b[i] / scale; shadow[i] = r[i] }
            try numerical.tick(&work, 0)
            var previousRho = 1.0, alpha = 1.0, omega = 1.0
            for iteration in 0..<maximumIterations {
                let rho = try dot(shadow, r, work: &work)
                guard rho != 0, omega != 0 else { throw NativeSTAConservativeCandidateNotCertified(reason: "BiCGStab candidate breakdown") }
                if iteration == 0 {
                    try numerical.tick(&work, n)
                    for i in 0..<n { p[i] = r[i] }
                    try numerical.tick(&work, 0)
                } else {
                    let beta = (rho / previousRho) * (alpha / omega)
                    guard beta.isFinite else { throw NativeSTAConservativeCandidateNotCertified(reason: "nonfinite candidate recurrence") }
                    try numerical.tick(&work, n)
                    for i in 0..<n { p[i] = r[i] + beta * (p[i] - omega * v[i]) }
                    try numerical.tick(&work, 0)
                }
                try multiply(p, into: &v, work: &work)
                let divisor = try dot(shadow, v, work: &work)
                guard divisor != 0 else { throw NativeSTAConservativeCandidateNotCertified(reason: "BiCGStab candidate pivot") }
                alpha = rho / divisor
                guard alpha.isFinite else { throw NativeSTAConservativeCandidateNotCertified(reason: "nonfinite candidate step") }
                var norm = 0.0
                try numerical.tick(&work, n)
                for i in 0..<n { s[i] = r[i] - alpha * v[i]; norm = max(norm, abs(s[i])) }
                try numerical.tick(&work, 0)
                if norm <= tolerance {
                    try numerical.tick(&work, n)
                    for i in 0..<n { x[i] += alpha * p[i] }
                    try numerical.tick(&work, 0)
                    break
                }
                try multiply(s, into: &t, work: &work)
                let denominator = try dot(t, t, work: &work)
                guard denominator > 0 else { throw NativeSTAConservativeCandidateNotCertified(reason: "BiCGStab candidate stabilizer") }
                omega = try dot(t, s, work: &work) / denominator
                guard omega.isFinite, omega != 0 else { throw NativeSTAConservativeCandidateNotCertified(reason: "BiCGStab candidate stagnation") }
                norm = 0
                try numerical.tick(&work, n)
                for i in 0..<n {
                    x[i] += alpha * p[i] + omega * s[i]
                    r[i] = s[i] - omega * t[i]
                    norm = max(norm, abs(r[i]))
                }
                try numerical.tick(&work, 0)
                if norm <= tolerance { break }
                previousRho = rho
            }
            try numerical.tick(&work, n)
            for i in 0..<n {
                let value = x[i] * scale
                guard value.isFinite else { throw NativeSTAConservativeCandidateNotCertified(reason: "nonfinite candidate solution") }
                result[i, column] = try I(point: value)
            }
            try numerical.tick(&work, 0)
        }
        return result
    }

    /// Zero-start cyclic GS proposes a comparison weight only; the caller must verify Fw < 0 outward.
    func comparisonWeightCandidate(_ f: CSR, maximumIterations: Int,
                                   work: inout UInt64) throws -> N.Matrix {
        let n = f.rows
        guard f.columns == n, maximumIterations > 0 else { throw invalid("comparison weight shape/iterations") }
        var result = try numerical.matrix(n, 1)
        if n == 0 { return result }
        let operationWork = f.values.count.addingReportingOverflow(n)
        guard !operationWork.overflow else { throw invalid("comparison weight operation count overflow") }
        try numerical.slots(n, times: 2); try numerical.slots(f.values.count)
        let vectorCount = n.multipliedReportingOverflow(by: 2)
        guard !vectorCount.overflow else { throw invalid("comparison scratch count overflow") }
        let vectorPayload = try numerical.budget.reservePayload(Double.self, capacity: vectorCount.partialValue, kind: .temporaryBytes)
        let valuesPayload = try numerical.budget.reservePayload(Double.self, capacity: f.values.count, kind: .temporaryBytes)
        defer { withExtendedLifetime((vectorPayload, valuesPayload)) {} }
        try numerical.budget.chargeScheduledWork(UInt64(vectorCount.partialValue))
        try numerical.budget.chargeScheduledWork(UInt64(f.values.count))
        var diagonal = Array(repeating: 0.0, count: n)
        var values = Array(repeating: 0.0, count: f.values.count)
        var weights = Array(repeating: 0.0, count: n)
        try numerical.tick(&work, operationWork.partialValue)
        for row in 0..<n {
            for index in f.rowOffsets[row]..<f.rowOffsets[row + 1] {
                values[index] = f.values[index].upperBound
                if f.columnIndices[index] == row {
                    diagonal[row] = -values[index]
                } else if f.values[index].lowerBound < 0 {
                    throw invalid("comparison weight requires Metzler operator")
                }
            }
            guard diagonal[row] > 0 else {
                throw NativeSTAConservativeCandidateNotCertified(reason: "comparison diagonal is not negative")
            }
        }
        try numerical.tick(&work, 0)
        let tolerance = Double.ulpOfOne.squareRoot()
        for _ in 0..<maximumIterations {
            try numerical.tick(&work, operationWork.partialValue)
            for row in 0..<n {
                var numerator = 1.0
                for index in f.rowOffsets[row]..<f.rowOffsets[row + 1] where f.columnIndices[index] != row {
                    numerator += values[index] * weights[f.columnIndices[index]]
                }
                let value = numerator / diagonal[row]
                guard value.isFinite, value > 0 else {
                    throw NativeSTAConservativeCandidateNotCertified(reason: "nonfinite or nonpositive GS comparison proposal")
                }
                weights[row] = value
            }
            try numerical.tick(&work, 0)
            // An ordinary true residual controls proposal accuracy only, never source/certificate authority.
            try numerical.tick(&work, operationWork.partialValue)
            var residualMaximum = 0.0
            for row in 0..<n {
                var sum = 0.0
                for index in f.rowOffsets[row]..<f.rowOffsets[row + 1] { sum += values[index] * weights[f.columnIndices[index]] }
                let residual = -sum - 1
                guard residual.isFinite else {
                    throw NativeSTAConservativeCandidateNotCertified(reason: "nonfinite GS comparison residual")
                }
                residualMaximum = max(residualMaximum, abs(residual))
            }
            try numerical.tick(&work, 0)
            if residualMaximum <= tolerance { break }
        }
        try numerical.tick(&work, n)
        for row in 0..<n { result[row, 0] = try I(point: weights[row]) }
        try numerical.tick(&work, 0)
        return result
    }

    /// A is the signed stable generator. F majorizes A, and (-F)w>0 certifies the inverse bound.
    func verifiedSolve(_ a: CSR, _ rhs: N.Matrix, comparison f: CSR, weight: N.Matrix,
                       maximumIterations: Int, work: inout UInt64) throws -> N.Matrix {
        let n = a.rows
        guard n == a.columns, f.rows == n, f.columns == n, weight.rows == n, weight.columns == 1,
              rhs.rows == n else { throw invalid("sparse verified shape") }
        for row in 0..<n {
            try numerical.tick(&work)
            guard weight[row, 0].lowerBound > 0, weight[row, 0].lowerBound == weight[row, 0].upperBound else {
                throw invalid("positive concrete sparse weight required")
            }
            var diagonalFound = false
            for index in f.rowOffsets[row]..<f.rowOffsets[row + 1] {
                try numerical.tick(&work)
                if f.columnIndices[index] == row {
                    diagonalFound = true
                    guard f.values[index].upperBound < 0 else { throw invalid("comparison diagonal sign") }
                } else if f.values[index].lowerBound < 0 { throw invalid("comparison is not Metzler") }
            }
            guard diagonalFound else { throw invalid("comparison diagonal missing") }
            var fIndex = f.rowOffsets[row]
            for index in a.rowOffsets[row]..<a.rowOffsets[row + 1] {
                try numerical.tick(&work)
                let column = a.columnIndices[index]
                while fIndex < f.rowOffsets[row + 1], f.columnIndices[fIndex] < column { try numerical.tick(&work); fIndex += 1 }
                let coefficient = fIndex < f.rowOffsets[row + 1] && f.columnIndices[fIndex] == column
                    ? f.values[fIndex].lowerBound : 0
                let required = column == row ? a.values[index].upperBound : try a.values[index].absolute().upperBound
                guard coefficient >= required else { throw invalid("comparison does not dominate generator") }
            }
            // A missing diagonal represents zero, which cannot be dominated by a stable negative F diagonal.
            var aDiagonal = false
            for index in a.rowOffsets[row]..<a.rowOffsets[row + 1] where a.columnIndices[index] == row { aDiagonal = true }
            guard aDiagonal else { throw invalid("generator diagonal missing") }
        }
        let fw = try product(f, weight, work: &work)
        for row in 0..<n { try numerical.tick(&work); guard fw[row, 0].upperBound < 0 else { throw invalid("comparison weight not strictly stable") } }
        let candidate = try approximateSolve(a, rhs, maximumIterations: maximumIterations, work: &work)
        let ax = try product(a, candidate, work: &work)
        var result = try numerical.matrix(n, rhs.columns)
        for column in 0..<rhs.columns {
            var scale = 0.0
            for row in 0..<n {
                try numerical.tick(&work)
                let residual = try rhs[row, column].subtracting(ax[row, column]).absolute()
                let gamma = try fw[row, 0].negated()
                scale = max(scale, try residual.divided(by: gamma).upperBound)
            }
            for row in 0..<n {
                try numerical.tick(&work)
                let radius = try I(point: scale).multiplied(by: weight[row, 0]).upperBound
                result[row, column] = try candidate[row, column].adding(I(lowerBound: -radius, upperBound: radius))
            }
        }
        return result
    }

    private func midpoint(_ value: I) -> Double { value.lowerBound / 2 + value.upperBound / 2 }
    private func isZero(_ value: I) -> Bool { value.lowerBound == 0 && value.upperBound == 0 }
    private func invalid(_ reason: String) -> NativeSTAConservativeCouplingError { .invalidCertificate(reason) }
}

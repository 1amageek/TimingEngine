import Foundation
import TimingCore

/// Dense, outward arithmetic used only after request-owned workspace admission.
internal struct NativeSTAConservativeNumerics {
    typealias I = TimingNumericInterval
    struct Matrix: Sendable {
        let rows: Int
        let columns: Int
        var values: [I]
        subscript(_ row: Int, _ column: Int) -> I {
            get { values[row * columns + column] }
            set { values[row * columns + column] = newValue }
        }
    }
    let limits: STAExecutionLimits
    let budget: NativeSTAStateBudget
    let resources: (any LibertySourceResourceAccounting)?

    func tick(_ work: inout UInt64, _ count: Int = 1) throws {
        try Task.checkCancellation()
        try resources?.check()
        let total = work.addingReportingOverflow(UInt64(count))
        guard !total.overflow, total.partialValue <= limits.maximumPathWorkUnits else {
            throw STAPathAnalysisError.capacity(resource: "conservative RC work", limit: limits.maximumPathWorkUnits)
        }
        work = total.partialValue
    }
    func slots(_ count: Int) throws { try budget.reserve(count) }
    func slots(_ count: Int, times multiplier: Int) throws {
        let total = count.multipliedReportingOverflow(by: multiplier)
        guard !total.overflow else { throw NativeSTAConservativeCouplingError.invalidPrimitive("workspace count overflow") }
        try slots(total.partialValue)
    }
    func matrix(_ rows: Int, _ columns: Int) throws -> Matrix {
        let count = rows.multipliedReportingOverflow(by: columns)
        guard rows >= 0, columns >= 0, !count.overflow else {
            throw NativeSTAConservativeCouplingError.invalidPrimitive("matrix dimensions overflow")
        }
        try slots(count.partialValue)
        return Matrix(rows: rows, columns: columns, values: Array(repeating: try I(point: 0), count: count.partialValue))
    }
    func copy(_ input: Matrix) throws -> Matrix {
        try slots(input.values.count)
        return input
    }
    func transpose(_ a: Matrix, work: inout UInt64) throws -> Matrix {
        var result = try matrix(a.columns, a.rows)
        for i in 0..<a.rows { for j in 0..<a.columns { try tick(&work); result[j, i] = a[i, j] } }
        return result
    }
    func product(_ a: Matrix, _ b: Matrix, work: inout UInt64) throws -> Matrix {
        guard a.columns == b.rows else { throw NativeSTAConservativeCouplingError.invalidCertificate("matrix shape") }
        var result = try matrix(a.rows, b.columns)
        for i in 0..<a.rows { for j in 0..<b.columns { for k in 0..<a.columns {
            try tick(&work)
            result[i, j] = try result[i, j].adding(a[i, k].multiplied(by: b[k, j]))
        } } }
        return result
    }
    func difference(_ a: Matrix, _ b: Matrix, work: inout UInt64) throws -> Matrix {
        guard a.rows == b.rows, a.columns == b.columns else { throw NativeSTAConservativeCouplingError.invalidCertificate("matrix shape") }
        var result = try matrix(a.rows, a.columns)
        for i in result.values.indices { try tick(&work); result.values[i] = try a.values[i].subtracting(b.values[i]) }
        return result
    }
    func negated(_ a: Matrix, work: inout UInt64) throws -> Matrix {
        var result = try matrix(a.rows, a.columns)
        for i in result.values.indices { try tick(&work); result.values[i] = try a.values[i].negated() }
        return result
    }
    func magnitude(_ a: Matrix, work: inout UInt64) throws -> Matrix {
        var result = try matrix(a.rows, a.columns)
        for i in result.values.indices { try tick(&work); result.values[i] = try I(point: a.values[i].absolute().upperBound) }
        return result
    }
    func identity(_ n: Int, work: inout UInt64) throws -> Matrix {
        var result = try matrix(n, n)
        for i in 0..<n { try tick(&work); result[i, i] = try I(point: 1) }
        return result
    }
    /// Interval LDL proves positive definiteness of every symmetric matrix enclosed by a.
    func positiveDefinite(_ a: Matrix, capacitance: Bool = false, work: inout UInt64) throws {
        let n = a.rows
        guard n == a.columns else { throw NativeSTAConservativeCouplingError.invalidCertificate("SPD shape") }
        var l = try identity(n, work: &work), d = try matrix(n, 1)
        for i in 0..<n {
            var pivot = a[i, i]
            for k in 0..<i { try tick(&work); pivot = try pivot.subtracting(l[i, k].multiplied(by: l[i, k]).multiplied(by: d[k, 0])) }
            guard pivot.lowerBound > 0 else {
                if capacitance { throw NativeSTAConservativeCouplingError.unsupportedCapacitanceProfile("positive definiteness not certified") }
                throw NativeSTAConservativeCouplingError.invalidCertificate("positive definiteness not certified")
            }
            d[i, 0] = pivot
            if i + 1 < n { for j in (i + 1)..<n {
                var value = a[j, i]
                for k in 0..<i { try tick(&work); value = try value.subtracting(l[j, k].multiplied(by: l[i, k]).multiplied(by: d[k, 0])) }
                l[j, i] = try value.divided(by: pivot)
            } }
        }
    }
    func midpoint(_ a: Matrix, work: inout UInt64) throws -> [Double] {
        try slots(a.values.count)
        var result: [Double] = []
        result.reserveCapacity(a.values.count)
        for value in a.values { try tick(&work); result.append(value.lowerBound / 2 + value.upperBound / 2) }
        return result
    }
    /// Ordinary Gauss-Jordan proposes an inverse. Only residual verification below admits it.
    func inverseCandidate(_ a: Matrix, work: inout UInt64) throws -> Matrix {
        let n = a.rows
        var values = try midpoint(a, work: &work), inverse = try identity(n, work: &work)
        for k in 0..<n {
            var pivot = k
            for i in k..<n { try tick(&work); if abs(values[i * n + k]) > abs(values[pivot * n + k]) { pivot = i } }
            guard values[pivot * n + k].isFinite, values[pivot * n + k] != 0 else { throw NativeSTAConservativeCouplingError.invalidCertificate("singular inverse candidate") }
            if pivot != k { for j in 0..<n { try tick(&work); values.swapAt(k * n + j, pivot * n + j); inverse.values.swapAt(k * n + j, pivot * n + j) } }
            let divisor = values[k * n + k]
            for j in 0..<n { try tick(&work); values[k * n + j] /= divisor; inverse[k, j] = try I(point: inverse[k, j].lowerBound / divisor) }
            for i in 0..<n where i != k {
                let factor = values[i * n + k]
                for j in 0..<n {
                    try tick(&work)
                    values[i * n + j] -= factor * values[k * n + j]
                    inverse[i, j] = try I(point: inverse[i, j].lowerBound - factor * inverse[k, j].lowerBound)
                }
            }
        }
        return inverse
    }
    /// R is exact binary candidate data; ||I - R A||inf < 1 proves invertibility.
    /// The Neumann correction encloses the solution for every admitted A and rhs.
    func solve(_ a: Matrix, _ rhs: Matrix, work: inout UInt64) throws -> Matrix {
        let n = a.rows
        guard n == a.columns, n == rhs.rows else { throw NativeSTAConservativeCouplingError.invalidCertificate("solve shape") }
        if n == 0 { return try matrix(0, rhs.columns) }
        let r = try inverseCandidate(a, work: &work)
        let residualOperator = try difference(identity(n, work: &work), product(r, a, work: &work), work: &work)
        var rho = 0.0
        for i in 0..<n {
            var sum = try I(point: 0)
            for j in 0..<n { try tick(&work); sum = try sum.adding(residualOperator[i, j].absolute()) }
            rho = max(rho, sum.upperBound)
        }
        guard rho < 1 else { throw NativeSTAConservativeCouplingError.invalidCertificate("inverse Neumann bound failed") }
        let candidateEnclosure = try product(r, rhs, work: &work)
        var candidate = try matrix(n, rhs.columns)
        for i in candidate.values.indices { try tick(&work); candidate.values[i] = try I(point: candidateEnclosure.values[i].lowerBound / 2 + candidateEnclosure.values[i].upperBound / 2) }
        let residual = try difference(rhs, product(a, candidate, work: &work), work: &work)
        let correction = try product(r, residual, work: &work)
        var result = try matrix(n, rhs.columns)
        for j in 0..<rhs.columns {
            var norm = 0.0
            for i in 0..<n { try tick(&work); norm = max(norm, try correction[i, j].absolute().upperBound) }
            let radius = try I(point: norm).divided(by: I(point: 1).subtracting(I(point: rho))).upperBound
            for i in 0..<n { try tick(&work); result[i, j] = try candidate[i, j].adding(I(lowerBound: -radius, upperBound: radius)) }
        }
        return result
    }
    /// Cholesky whitening and Jacobi generate coordinates; no eigenvalue accuracy is trusted.
    func basis(_ c: Matrix, _ g: Matrix, sweeps: Int, work: inout UInt64) throws -> Matrix {
        let n = c.rows
        var l = try matrix(n, n)
        for i in 0..<n { for j in 0...i {
            var value = c[i, j].lowerBound / 2 + c[i, j].upperBound / 2
            for k in 0..<j { try tick(&work); value -= l[i, k].lowerBound * l[j, k].lowerBound }
            if i == j {
                guard value > 0 else { throw NativeSTAConservativeCouplingError.invalidCertificate("whitening failed") }
                l[i, j] = try I(point: value.squareRoot())
            } else { l[i, j] = try I(point: value / l[j, j].lowerBound) }
        } }
        // The ordinary inverse is used only to propose Q, whose exact entries are verified later.
        let z = try transpose(inverseCandidate(l, work: &work), work: &work)
        let raw = try product(transpose(z, work: &work), product(g, z, work: &work), work: &work)
        var h = try midpoint(raw, work: &work), v = try identity(n, work: &work)
        if n > 1 { for _ in 0..<sweeps { for p in 0..<(n - 1) { for q in (p + 1)..<n {
            try tick(&work)
            let apq = h[p * n + q]
            if apq == 0 { continue }
            let angle = 0.5 * atan2(2 * apq, h[q * n + q] - h[p * n + p])
            let cs = cos(angle), sn = sin(angle)
            for k in 0..<n {
                try tick(&work)
                let hp = h[k * n + p], hq = h[k * n + q]
                h[k * n + p] = cs * hp - sn * hq; h[k * n + q] = sn * hp + cs * hq
                let vp = v[k, p].lowerBound, vq = v[k, q].lowerBound
                v[k, p] = try I(point: cs * vp - sn * vq); v[k, q] = try I(point: sn * vp + cs * vq)
            }
            for k in 0..<n {
                try tick(&work)
                let hp = h[p * n + k], hq = h[q * n + k]
                h[p * n + k] = cs * hp - sn * hq; h[q * n + k] = sn * hp + cs * hq
            }
        } } } }
        let candidate = try product(z, v, work: &work)
        var exact = try matrix(n, n)
        for i in exact.values.indices { try tick(&work); exact.values[i] = try I(point: candidate.values[i].lowerBound / 2 + candidate.values[i].upperBound / 2) }
        return exact
    }
}

import TimingCore

/// Checks a continuous point-polynomial trajectory independently of its native proposal solver.
internal struct NativeSTAConservativeResidualCertificate {
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias I = TimingNumericInterval
    typealias Graph = NativeSTAConservativeSparseGraph
    typealias Candidate = NativeSTAConservativeResidualCandidate
    let numerical: N

    struct Segment: Sendable {
        let start: Double
        let end: Double
        let bernstein: [N.Matrix]
    }
    struct Errors: Sendable {
        let initial: N.Matrix
        let solve: N.Matrix
        let interpolation: N.Matrix
        let tail: N.Matrix
    }
    struct Facts: Sendable {
        let receiverRows: [Int]
        let sourceCount: Int
        let segments: [Segment]
        let errors: Errors
        let direct: N.Matrix
    }

    func prepare(_ reduced: Graph.Reduced, receiverRows: [Int], times: [Double],
                 work: inout UInt64) throws -> Facts {
        try validate(reduced, receiverRows: receiverRows, times: times, work: &work)
        let d = reduced.conductance.rows, sources = reduced.forcing.columns
        let doubled = sources.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { throw invalid("residual column overflow") }
        let columns = doubled.partialValue, width = columns
        let sparse = S(numerical: numerical)
        let trueJ = try solveCapacitance(reduced, rhs: numerical.negated(reduced.forcing, work: &work), work: &work)
        let gj = try sparse.product(reduced.conductance, trueJ, work: &work)
        let trueH = try solveCapacitance(reduced, rhs: numerical.negated(gj, work: &work), work: &work)
        var initial = try numerical.matrix(d, columns)
        for row in 0..<d { for column in 0..<sources {
            try numerical.tick(&work)
            let j = trueJ[row, column], h = trueH[row, column]
            initial[row, column] = try I(point: j.lowerBound / 2 + j.upperBound / 2)
            initial[row, sources + column] = try I(point: h.lowerBound / 2 + h.upperBound / 2)
        } }
        var rhs = try numerical.matrix(d, width), point = try numerical.matrix(d, width)
        var previous = try numerical.copy(initial)
        var initialError = try numerical.matrix(receiverRows.count, columns)
        var solveError = try numerical.matrix(receiverRows.count, columns)
        var interpolationError = try numerical.matrix(receiverRows.count, columns)
        var tailError = try numerical.matrix(receiverRows.count, columns)
        var segments = [Segment](); try numerical.slots(times.count - 1)
        segments.reserveCapacity(times.count - 1)

        return try Candidate.withSession(reduced: reduced, numerical: numerical, work: &work) { session, sessionWork in
            for row in 0..<d { try numerical.tick(&sessionWork); rhs[row, 0] = try I(point: 1) }
            try session.solveG(rhs, into: &point, work: &sessionWork)
            var weight = try numerical.matrix(d, 1)
            for row in 0..<d { try numerical.tick(&sessionWork); weight[row, 0] = point[row, 0] }
            let norm = try NativeSTAConservativeResidualNorm(numerical: numerical,
                conductance: reduced.conductance, weight: weight, work: &sessionWork)

            var dual = try numerical.matrix(receiverRows.count, 1)
            var receiverIndex = 0
            while receiverIndex < receiverRows.count {
                try clear(&rhs, work: &sessionWork)
                let count = min(columns, receiverRows.count - receiverIndex)
                for column in 0..<count {
                    let physicalRow = receiverRows[receiverIndex + column]
                    for k in reduced.reconstruction.rowOffsets[physicalRow]..<reduced.reconstruction.rowOffsets[physicalRow + 1] {
                        try numerical.tick(&sessionWork)
                        rhs[reduced.reconstruction.columnIndices[k], column] = reduced.reconstruction.values[k]
                    }
                }
                try session.solveG(rhs, into: &point, work: &sessionWork)
                let receiverNorms = try norm.upper(rhs, candidate: point, work: &sessionWork)
                for column in 0..<count {
                    try numerical.tick(&sessionWork)
                    dual[receiverIndex + column, 0] = receiverNorms[0, column]
                }
                receiverIndex += count
            }

            try fillInitial(reduced, initial: initial, gj: gj, into: &rhs, work: &sessionWork)
            try session.solveG(rhs, into: &point, work: &sessionWork)
            try add(norm.upper(rhs, candidate: point, work: &sessionWork), dual: dual,
                    scale: I(point: 1), into: &initialError, work: &sessionWork)

            var index = 0
            try session.stream(initial: initial, times: times, work: &sessionWork) { proposed, callbackWork in
                guard index < times.count - 1 else { throw invalid("extra residual candidate segment") }
                try validate(proposed, start: times[index], end: times[index + 1], previous: previous, work: &callbackWork)
                let step = try I(point: proposed.end).subtracting(I(point: proposed.start))
                guard step.lowerBound > 0 else { throw invalid("positive residual step not represented") }
                for component in 0..<4 {
                    try fillResidual(reduced, segment: proposed, component: component, into: &rhs, work: &callbackWork)
                    try session.solveG(rhs, into: &point, work: &callbackWork)
                    let upper = try norm.upper(rhs, candidate: point, work: &callbackWork)
                    if component == 0 {
                        try add(upper, dual: dual, scale: step, into: &solveError, work: &callbackWork)
                    } else {
                        try add(upper, dual: dual, scale: step.divided(by: I(point: 4)),
                                into: &interpolationError, work: &callbackWork)
                    }
                }
                var projected = [N.Matrix](); try numerical.slots(4); projected.reserveCapacity(4)
                for coefficient in proposed.bernstein {
                    projected.append(try project(coefficient, operator: reduced.reconstruction,
                                                 rows: receiverRows, work: &callbackWork))
                }
                segments.append(Segment(start: proposed.start, end: proposed.end, bernstein: projected))
                try numerical.tick(&callbackWork, previous.values.count)
                for k in previous.values.indices { previous.values[k] = proposed.bernstein[3].values[k] }
                index += 1
            }
            guard index == times.count - 1 else { throw invalid("incomplete residual candidate grid") }
            try fillProduct(reduced.capacitance, previous, into: &rhs, work: &sessionWork)
            try session.solveG(rhs, into: &point, work: &sessionWork)
            try add(norm.upper(rhs, candidate: point, work: &sessionWork), dual: dual,
                    scale: I(point: 1), into: &tailError, work: &sessionWork)
            var direct = try project(trueJ, operator: reduced.reconstruction, rows: receiverRows, work: &sessionWork)
            for (row, physicalRow) in receiverRows.enumerated() {
                for k in reduced.dcIncidence.rowOffsets[physicalRow]..<reduced.dcIncidence.rowOffsets[physicalRow + 1] {
                    try numerical.tick(&sessionWork)
                    let column = reduced.dcIncidence.columnIndices[k]
                    direct[row, column] = try direct[row, column].adding(reduced.dcIncidence.values[k])
                }
            }
            return Facts(receiverRows: receiverRows, sourceCount: sources, segments: segments,
                errors: Errors(initial: initialError, solve: solveError,
                               interpolation: interpolationError, tail: tailError), direct: direct)
        }
    }

    /// Validates candidate continuity before any residual can omit a charge jump.
    func validate(_ segment: Candidate.Segment, start: Double, end: Double,
                  previous: N.Matrix, work: inout UInt64) throws {
        guard start.isFinite, end.isFinite, end > start, segment.start == start,
              segment.end == end, segment.bernstein.count == 4 else { throw invalid("residual segment grid/degree") }
        for coefficient in segment.bernstein {
            guard coefficient.rows == previous.rows, coefficient.columns == previous.columns,
                  coefficient.values.count == previous.values.count else {
                throw invalid("residual coefficient shape")
            }
            try numerical.tick(&work, coefficient.values.count)
            for value in coefficient.values {
                guard value.lowerBound == value.upperBound else { throw invalid("residual candidate coefficient is not point data") }
            }
            try numerical.tick(&work, 0)
        }
        try numerical.tick(&work, previous.values.count)
        guard segment.bernstein[0].values == previous.values else { throw invalid("residual candidate charge discontinuity") }
        try numerical.tick(&work, 0)
    }

    /// Component zero is r(0); the other components bound r(theta)-r(0) directly.
    func fillResidual(_ reduced: Graph.Reduced, segment: Candidate.Segment, component: Int,
                      into result: inout N.Matrix, work: inout UInt64) throws {
        guard (0..<4).contains(component), segment.bernstein.count == 4,
              result.rows == reduced.capacitance.rows,
              result.columns >= segment.bernstein[0].columns else { throw invalid("residual scratch shape") }
        let b = segment.bernstein, columns = b[0].columns
        for coefficient in b {
            guard coefficient.rows == reduced.capacitance.columns, coefficient.columns == columns,
                  coefficient.values.count == b[0].values.count else { throw invalid("residual coefficient scratch shape") }
        }
        let step = try I(point: segment.end).subtracting(I(point: segment.start))
        guard step.lowerBound > 0 else { throw invalid("residual step is not positive") }
        let three = try I(point: 3), two = try I(point: 2)
        func derivative(_ row: Int, _ column: Int) throws -> I {
            let d0 = try b[1][row, column].subtracting(b[0][row, column]).multiplied(by: three).divided(by: step)
            if component == 0 { return d0 }
            let d1 = try b[2][row, column].subtracting(b[1][row, column]).multiplied(by: three).divided(by: step)
            if component == 1 { return try d1.subtracting(d0).multiplied(by: two).divided(by: three) }
            let d2 = try b[3][row, column].subtracting(b[2][row, column]).multiplied(by: three).divided(by: step)
            if component == 2 { return try d1.subtracting(d0).multiplied(by: two).adding(d2.subtracting(d0)).divided(by: three) }
            return try d2.subtracting(d0)
        }
        for row in 0..<result.rows { for column in 0..<result.columns {
            if column >= columns { result[row, column] = try I(point: 0); try numerical.tick(&work); continue }
            let cCount = reduced.capacitance.rowOffsets[row + 1] - reduced.capacitance.rowOffsets[row]
            let gCount = reduced.conductance.rowOffsets[row + 1] - reduced.conductance.rowOffsets[row]
            let subtotal = cCount.addingReportingOverflow(gCount)
            let total = subtotal.partialValue.addingReportingOverflow(1)
            guard !subtotal.overflow, !total.overflow else { throw invalid("residual operation count overflow") }
            try numerical.tick(&work, total.partialValue)
            var value = try I(point: 0)
            for k in reduced.capacitance.rowOffsets[row]..<reduced.capacitance.rowOffsets[row + 1] {
                value = try value.adding(reduced.capacitance.values[k].multiplied(by:
                    derivative(reduced.capacitance.columnIndices[k], column)))
            }
            for k in reduced.conductance.rowOffsets[row]..<reduced.conductance.rowOffsets[row + 1] {
                let physical = reduced.conductance.columnIndices[k]
                let coefficient = component == 0 ? b[0][physical, column]
                    : try b[component][physical, column].subtracting(b[0][physical, column])
                value = try value.adding(reduced.conductance.values[k].multiplied(by: coefficient))
            }
            result[row, column] = value
        } }
    }

    private func validate(_ reduced: Graph.Reduced, receiverRows: [Int], times: [Double], work: inout UInt64) throws {
        let d = reduced.conductance.rows, s = reduced.forcing.columns
        guard d > 0, s > 0, reduced.conductance.columns == d,
              reduced.capacitance.rows == d, reduced.capacitance.columns == d,
              reduced.forcing.rows == d, reduced.dynamicRows.count == d,
              reduced.reconstruction.columns == d,
              reduced.dcIncidence.rows == reduced.reconstruction.rows, reduced.dcIncidence.columns == s,
              !receiverRows.isEmpty, times.count >= 2, times[0] == 0 else { throw invalid("residual reduced shape/grid") }
        var last = -1
        for row in receiverRows {
            try numerical.tick(&work)
            guard row > last, row < reduced.reconstruction.rows else { throw invalid("residual receiver ordering") }
            last = row
        }
        for i in 1..<times.count {
            try numerical.tick(&work)
            guard times[i].isFinite, times[i] > times[i - 1] else { throw invalid("residual time grid") }
        }
        try numerical.slots(d)
        var owner = Array(repeating: -1, count: d), first = -1
        for (blockIndex, block) in reduced.capBlocks.enumerated() {
            guard let head = block.first, head > first else { throw invalid("residual CAP partition ordering") }
            first = head; var previous = -1
            for row in block {
                try numerical.tick(&work)
                guard row > previous, row < d, owner[row] == -1 else { throw invalid("residual CAP partition") }
                owner[row] = blockIndex; previous = row
            }
        }
        for row in 0..<d {
            try numerical.tick(&work)
            guard owner[row] >= 0 else { throw invalid("residual incomplete CAP partition") }
            for k in reduced.capacitance.rowOffsets[row]..<reduced.capacitance.rowOffsets[row + 1] {
                try numerical.tick(&work)
                guard owner[row] == owner[reduced.capacitance.columnIndices[k]] else {
                    throw invalid("residual CAP crosses partition")
                }
            }
        }
    }

    private func solveCapacitance(_ reduced: Graph.Reduced, rhs: N.Matrix, work: inout UInt64) throws -> N.Matrix {
        var result = try numerical.matrix(rhs.rows, rhs.columns)
        for rows in reduced.capBlocks {
            var c = try numerical.matrix(rows.count, rows.count), b = try numerical.matrix(rows.count, rhs.columns)
            for (i, row) in rows.enumerated() {
                for column in 0..<rhs.columns { try numerical.tick(&work); b[i, column] = rhs[row, column] }
                for k in reduced.capacitance.rowOffsets[row]..<reduced.capacitance.rowOffsets[row + 1] {
                    try numerical.tick(&work)
                    guard let j = rows.firstIndex(of: reduced.capacitance.columnIndices[k]) else { throw invalid("residual local CAP column") }
                    c[i, j] = reduced.capacitance.values[k]
                }
            }
            let solved: N.Matrix
            do { solved = try numerical.solve(c, b, work: &work) }
            catch let error as NativeSTAConservativeCouplingError {
                switch error {
                case .invalidCertificate("singular inverse candidate"), .invalidCertificate("inverse Neumann bound failed"):
                    throw NativeSTAConservativeCandidateNotCertified(reason: "residual local CAP solve not certified")
                default: throw error
                }
            }
            for (i, row) in rows.enumerated() { for column in 0..<rhs.columns {
                try numerical.tick(&work); result[row, column] = solved[i, column]
            } }
        }
        return result
    }

    private func clear(_ matrix: inout N.Matrix, work: inout UInt64) throws {
        try numerical.tick(&work, matrix.values.count)
        for i in matrix.values.indices { matrix.values[i] = try I(point: 0) }
    }
    private func fillInitial(_ reduced: Graph.Reduced, initial: N.Matrix, gj: N.Matrix,
                             into result: inout N.Matrix, work: inout UInt64) throws {
        try fillProduct(reduced.capacitance, initial, into: &result, work: &work)
        let s = reduced.forcing.columns
        for row in 0..<result.rows { for column in 0..<s {
            try numerical.tick(&work)
            result[row, column] = try reduced.forcing[row, column].negated().subtracting(result[row, column])
            result[row, s + column] = try gj[row, column].negated().subtracting(result[row, s + column])
        } }
    }
    private func fillProduct(_ a: S.CSR, _ b: N.Matrix, into result: inout N.Matrix, work: inout UInt64) throws {
        guard result.rows == a.rows, b.rows == a.columns, result.columns >= b.columns else { throw invalid("residual product scratch") }
        for row in 0..<a.rows { for column in 0..<result.columns {
            try numerical.tick(&work, a.rowOffsets[row + 1] - a.rowOffsets[row] + 1)
            var value = try I(point: 0)
            if column < b.columns {
                for k in a.rowOffsets[row]..<a.rowOffsets[row + 1] {
                    value = try value.adding(a.values[k].multiplied(by: b[a.columnIndices[k], column]))
                }
            }
            result[row, column] = value
        } }
    }
    private func project(_ input: N.Matrix, operator a: S.CSR, rows: [Int], work: inout UInt64) throws -> N.Matrix {
        var result = try numerical.matrix(rows.count, input.columns)
        for (row, physical) in rows.enumerated() { for column in 0..<input.columns {
            try numerical.tick(&work, a.rowOffsets[physical + 1] - a.rowOffsets[physical] + 1)
            var value = try I(point: 0)
            for k in a.rowOffsets[physical]..<a.rowOffsets[physical + 1] {
                value = try value.adding(a.values[k].multiplied(by: input[a.columnIndices[k], column]))
            }
            result[row, column] = value
        } }
        return result
    }
    private func add(_ norm: N.Matrix, dual: N.Matrix, scale: I, into result: inout N.Matrix, work: inout UInt64) throws {
        guard norm.rows == 1, norm.columns >= result.columns, dual.rows == result.rows, dual.columns == 1 else {
            throw invalid("residual error shape")
        }
        for row in 0..<result.rows { for column in 0..<result.columns {
            try numerical.tick(&work)
            let upper = try dual[row, 0].multiplied(by: norm[0, column]).multiplied(by: scale)
            result[row, column] = try I(point: result[row, column].adding(upper).upperBound)
        } }
    }
    private func invalid(_ reason: String) -> NativeSTAConservativeCouplingError { .invalidPrimitive(reason) }
}

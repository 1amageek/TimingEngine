import TimingCore

/// Finite point proposals only; the independent continuous checker owns every certificate.
internal struct NativeSTAConservativeResidualCandidate {
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias I = TimingNumericInterval
    let numerical: N

    struct Segment {
        let start: Double
        let end: Double
        let bernstein: [N.Matrix]
    }

    struct Session: ~Copyable {
        fileprivate let core: Core
        func solveG(_ rhs: N.Matrix, into result: inout N.Matrix, work: inout UInt64) throws {
            try core.solveG(rhs, into: &result, work: &work)
        }
        func stream(initial: N.Matrix, times: [Double], work: inout UInt64,
                    consume: (Segment, inout UInt64) throws -> Void) throws {
            try core.stream(initial: initial, times: times, work: &work, consume: consume)
        }
    }

    static func withSession<R>(reduced: NativeSTAConservativeSparseGraph.Reduced,
                               numerical: N, work: inout UInt64,
                               body: (borrowing Session, inout UInt64) throws -> R) throws -> R {
        try numerical.tick(&work, 0)
        #if os(macOS) && canImport(Darwin)
        let count = reduced.conductance.values.count.addingReportingOverflow(reduced.capacitance.values.count)
        guard !count.overflow else { throw invalid("native pattern count overflow") }
        let (result, _) = try NativeSTAConservativeNativeAllocation.withLease(
            dimension: reduced.conductance.rows, nonzeros: count.partialValue, numerical: numerical, work: &work) { work in
                let core = try Core(reduced: reduced, numerical: numerical, work: &work)
                defer { core.close() }
                let session = Session(core: core)
                return try body(session, &work)
            }
        return result
        #else
        throw NativeSTAConservativeCouplingError.unsupportedNativeCapability("Native macOS sparse Cholesky unavailable")
        #endif
    }

    fileprivate final class Core {
        private struct Block {
            let rows: [Int]
            let lower: [Double]
        }
        private let reduced: NativeSTAConservativeSparseGraph.Reduced
        private let numerical: N
        private let rows: Int
        private let columns: Int
        private var gFactor: NativeSTAConservativeNativeFactor?
        private var shiftFactor: NativeSTAConservativeNativeFactor?
        private var gValues: [Double] = []
        private var cValues: [Double] = []
        private var blocks: [Block] = []
        private var gScratch: [Double] = []
        private var blockScratch: [Double] = []
        private var x0: [Double] = []
        private var x1: [Double] = []
        private var y1: [Double] = []
        private var y2: [Double] = []
        private var mass: [Double] = []
        private var gy1: [Double] = []
        private var gy2: [Double] = []
        private var rhs: [Double] = []
        private var f0: [Double] = []
        private var f1: [Double] = []
        private var coefficients: [N.Matrix] = []
        private var closed = false

        init(reduced: NativeSTAConservativeSparseGraph.Reduced, numerical: N, work: inout UInt64) throws {
            self.reduced = reduced; self.numerical = numerical; rows = reduced.conductance.rows
            let twice = reduced.forcing.columns.multipliedReportingOverflow(by: 2)
            guard !twice.overflow, twice.partialValue > 0 else { throw Self.invalid("candidate source-column shape") }
            columns = twice.partialValue
            do {
                guard reduced.capacitance.rows == rows, reduced.dynamicRows.count == rows, reduced.forcing.rows == rows else { throw Self.invalid("candidate reduced shape") }
                gFactor = try .init(conductance: reduced.conductance, capacitance: nil, numerical: numerical, work: &work)
                shiftFactor = try .init(conductance: reduced.conductance, capacitance: reduced.capacitance, numerical: numerical, work: &work)
                try gFactor!.factor(conductanceScale: 1, capacitanceScale: 0, work: &work)
                try numerical.slots(reduced.conductance.values.count + reduced.capacitance.values.count)
                try numerical.tick(&work, reduced.conductance.values.count + reduced.capacitance.values.count)
                gValues = reduced.conductance.values.map { $0.lowerBound / 2 + $0.upperBound / 2 }
                cValues = reduced.capacitance.values.map { $0.lowerBound / 2 + $0.upperBound / 2 }
                try prepareBlocks(work: &work)
                let count = rows.multipliedReportingOverflow(by: columns)
                guard !count.overflow else { throw Self.invalid("candidate workspace overflow") }
                try numerical.slots(count.partialValue, times: 11)
                gScratch = Array(repeating: 0, count: count.partialValue)
                x0 = Array(repeating: 0, count: count.partialValue); x1 = x0
                y1 = x0; y2 = x0; mass = x0; gy1 = x0; gy2 = x0; rhs = x0; f0 = x0; f1 = x0
                // Independent buffers become unique before the first numerical step.
                for i in x0.indices { x1[i] = 0; y1[i] = 0; y2[i] = 0; mass[i] = 0; gy1[i] = 0; gy2[i] = 0; rhs[i] = 0; f0[i] = 0; f1[i] = 0 }
                try numerical.slots(4)
                for _ in 0..<4 { coefficients.append(try numerical.matrix(rows, columns)) }
            } catch { close(); throw error }
        }

        func solveG(_ input: N.Matrix, into output: inout N.Matrix, work: inout UInt64) throws {
            guard !closed, input.rows == rows, input.columns > 0, input.columns <= columns,
                  output.rows == rows, output.columns == input.columns,
                  input.values.count == rows * input.columns, output.values.count == input.values.count else { throw Self.invalid("candidate G-solve shape/lifecycle") }
            try numerical.tick(&work, input.values.count)
            for row in 0..<rows { for column in 0..<input.columns {
                let value = input[row, column]
                let midpoint = value.lowerBound / 2 + value.upperBound / 2
                guard midpoint.isFinite else { throw Self.invalid("candidate G-solve nonfinite RHS") }
                gScratch[column * rows + row] = midpoint
            } }
            try gFactor!.solve(&gScratch, columns: input.columns, work: &work)
            try numerical.tick(&work, output.values.count)
            for row in 0..<rows { for column in 0..<input.columns {
                output[row, column] = try I(point: gScratch[column * rows + row])
            } }
        }

        func stream(initial: N.Matrix, times: [Double], work: inout UInt64,
                    consume: (Segment, inout UInt64) throws -> Void) throws {
            guard !closed, initial.rows == rows, initial.columns == columns, times.count >= 2,
                  times.first == 0, initial.values.count == rows * columns else { throw Self.invalid("candidate stream shape/grid") }
            try numerical.tick(&work, initial.values.count + times.count)
            for i in times.indices {
                guard times[i].isFinite, times[i] >= 0, i == 0 || times[i] > times[i - 1] else { throw Self.invalid("candidate grid is not strictly increasing") }
            }
            for row in 0..<rows { for column in 0..<columns {
                let value = initial[row, column]
                guard value.lowerBound == value.upperBound, value.lowerBound.isFinite else { throw Self.invalid("candidate initial state is not a finite point") }
                x0[column * rows + row] = value.lowerBound
            } }
            try derivative(x0, into: &f0, work: &work)
            let gamma = 0.435866521508459
            let a21 = (1 - gamma) / 2
            let a31 = -1.5 * gamma * gamma + 4 * gamma - 0.25
            let a32 = 1.5 * gamma * gamma - 5 * gamma + 1.25
            for step in 1..<times.count {
                let start = times[step - 1], end = times[step], dt = end - start
                guard dt.isFinite, dt > 0 else { throw Self.invalid("candidate step underflow/overflow") }
                try shiftFactor!.factor(conductanceScale: dt * gamma, capacitanceScale: 1, work: &work)
                try multiply(reduced.capacitance, values: cValues, x0, into: &mass, work: &work)
                try numerical.tick(&work, rhs.count)
                for i in rhs.indices { rhs[i] = mass[i] }
                try shiftFactor!.solve(&rhs, columns: columns, work: &work)
                for i in rhs.indices { y1[i] = rhs[i] }
                try multiply(reduced.conductance, values: gValues, y1, into: &gy1, work: &work)
                try numerical.tick(&work, rhs.count)
                for i in rhs.indices { rhs[i] = mass[i] - dt * a21 * gy1[i] }
                try shiftFactor!.solve(&rhs, columns: columns, work: &work)
                for i in rhs.indices { y2[i] = rhs[i] }
                try multiply(reduced.conductance, values: gValues, y2, into: &gy2, work: &work)
                try numerical.tick(&work, rhs.count)
                for i in rhs.indices { rhs[i] = mass[i] - dt * (a31 * gy1[i] + a32 * gy2[i]) }
                try shiftFactor!.solve(&rhs, columns: columns, work: &work)
                for i in rhs.indices { x1[i] = rhs[i] }
                try derivative(x1, into: &f1, work: &work)
                try numerical.tick(&work, rhs.count * 4)
                for row in 0..<rows { for column in 0..<columns {
                    let i = column * rows + row
                    coefficients[0][row, column] = try I(point: x0[i])
                    coefficients[1][row, column] = try Self.point(x0[i] + dt / 3 * f0[i])
                    coefficients[2][row, column] = try Self.point(x1[i] - dt / 3 * f1[i])
                    coefficients[3][row, column] = try I(point: x1[i])
                } }
                try consume(Segment(start: start, end: end, bernstein: coefficients), &work)
                try numerical.tick(&work, rhs.count)
                for i in rhs.indices { x0[i] = x1[i]; f0[i] = f1[i] }
            }
        }

        private func multiply(_ matrix: S.CSR, values: [Double], _ input: [Double],
                              into output: inout [Double], work: inout UInt64) throws {
            let charge = matrix.values.count.multipliedReportingOverflow(by: columns)
            guard !charge.overflow else { throw Self.invalid("candidate product work overflow") }
            try numerical.tick(&work, charge.partialValue)
            for row in 0..<rows { for column in 0..<columns {
                var value = 0.0
                for i in matrix.rowOffsets[row]..<matrix.rowOffsets[row + 1] { value += values[i] * input[column * rows + matrix.columnIndices[i]] }
                guard value.isFinite else { throw Self.invalid("nonfinite candidate sparse product") }
                output[column * rows + row] = value
            } }
            try numerical.tick(&work, 0)
        }

        private func derivative(_ input: [Double], into output: inout [Double], work: inout UInt64) throws {
            try multiply(reduced.conductance, values: gValues, input, into: &output, work: &work)
            for block in blocks {
                let size = block.rows.count
                let square = size.multipliedReportingOverflow(by: size)
                let charge = square.partialValue.multipliedReportingOverflow(by: columns)
                guard !square.overflow, !charge.overflow else { throw Self.invalid("candidate local C work overflow") }
                try numerical.tick(&work, charge.partialValue)
                for column in 0..<columns {
                    for i in 0..<size {
                        var value = -output[column * rows + block.rows[i]]
                        for j in 0..<i { value -= block.lower[i * size + j] * blockScratch[j] }
                        blockScratch[i] = value / block.lower[i * size + i]
                    }
                    for i in stride(from: size - 1, through: 0, by: -1) {
                        var value = blockScratch[i]
                        if i + 1 < size { for j in (i + 1)..<size { value -= block.lower[j * size + i] * blockScratch[j] } }
                        blockScratch[i] = value / block.lower[i * size + i]
                        guard blockScratch[i].isFinite else { throw Self.invalid("nonfinite candidate C-block derivative") }
                    }
                    for i in 0..<size { output[column * rows + block.rows[i]] = blockScratch[i] }
                }
            }
        }

        private func prepareBlocks(work: inout UInt64) throws {
            try numerical.slots(rows)
            var owner = Array(repeating: -1, count: rows); var maximum = 0
            for (index, ids) in reduced.capBlocks.enumerated() {
                guard !ids.isEmpty else { throw Self.invalid("empty candidate C block") }
                for row in ids {
                    guard row >= 0, row < rows, owner[row] == -1 else { throw Self.invalid("invalid candidate C partition") }
                    owner[row] = index
                }
                maximum = max(maximum, ids.count)
            }
            guard owner.allSatisfy({ $0 >= 0 }) else { throw Self.invalid("incomplete candidate C partition") }
            try numerical.slots(maximum); blockScratch = Array(repeating: 0, count: maximum)
            try numerical.slots(reduced.capBlocks.count)
            for (blockIndex, ids) in reduced.capBlocks.enumerated() {
                let size = ids.count, count = size.multipliedReportingOverflow(by: size)
                guard !count.overflow else { throw Self.invalid("candidate local C storage overflow") }
                try numerical.slots(count.partialValue)
                var lower = Array(repeating: 0.0, count: count.partialValue)
                for (i, row) in ids.enumerated() {
                    for offset in reduced.capacitance.rowOffsets[row]..<reduced.capacitance.rowOffsets[row + 1] {
                        try numerical.tick(&work, ids.count)
                        let column = reduced.capacitance.columnIndices[offset]
                        guard owner[column] == blockIndex else { throw Self.invalid("candidate C edge crosses partition") }
                        guard let j = ids.firstIndex(of: column) else { throw Self.invalid("candidate C partition index") }
                        lower[i * size + j] = cValues[offset]
                    }
                }
                for i in 0..<size { for j in 0...i {
                    try numerical.tick(&work, j + 1)
                    var value = lower[i * size + j]
                    for k in 0..<j { value -= lower[i * size + k] * lower[j * size + k] }
                    if i == j {
                        guard value.isFinite, value > 0 else { throw Self.invalid("ordinary candidate C-block Cholesky failed") }
                        lower[i * size + j] = value.squareRoot()
                    } else { lower[i * size + j] = value / lower[j * size + j] }
                } }
                blocks.append(Block(rows: ids, lower: lower))
            }
        }

        func close() {
            guard !closed else { return }; closed = true
            shiftFactor?.close(); shiftFactor = nil
            gFactor?.close(); gFactor = nil
        }

        private static func point(_ value: Double) throws -> I {
            guard value.isFinite else { throw invalid("nonfinite candidate Bernstein coefficient") }
            return try I(point: value)
        }

        private static func invalid(_ detail: String) -> NativeSTAConservativeCouplingError { .nativeBackendFailure(detail) }
    }

    private static func invalid(_ detail: String) -> NativeSTAConservativeCouplingError { .nativeBackendFailure(detail) }
}

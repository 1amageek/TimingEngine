import TimingCore

/// Deterministic point proposals; only the independent residual checker grants authority.
/// This non-Sendable owner remains inside its synchronous allocation lease. Every raw range
/// has checked count/stride/bytes, at least 16-byte alignment, explicit trivial-type binding
/// and initialization, and exactly-once typed deinitialization/release. No pointer or RHS
/// borrow escapes. The lease's Mutex protects accounting identities, never these buffers.
internal final class NativeSTAConservativeNativeFactor {
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias A = NativeSTAConservativeNativeAllocation
    private let numerical: N
    let dimension: Int
    private var wordsPerRow = 0
    private var adjacencyCount = 0
    private var adjacency: UnsafeMutablePointer<UInt64>?
    private var degrees: UnsafeMutablePointer<Int>?
    private var neighbors: UnsafeMutablePointer<Int>?
    private var order: UnsafeMutablePointer<Int>?
    private var inverse: UnsafeMutablePointer<Int>?
    private var columnStarts: UnsafeMutablePointer<Int>?
    private var rowIndices: UnsafeMutablePointer<Int32>?
    private var conductance: UnsafeMutablePointer<Double>?
    private var capacitance: UnsafeMutablePointer<Double>?
    private var values: UnsafeMutablePointer<Double>?
    private var scratch: UnsafeMutablePointer<Double>?
    private var adjacencyPayload: LibertySourceStorageReservation?
    private var degreesPayload: LibertySourceStorageReservation?
    private var neighborsPayload: LibertySourceStorageReservation?
    private var orderPayload: LibertySourceStorageReservation?
    private var inversePayload: LibertySourceStorageReservation?
    private var columnStartsPayload: LibertySourceStorageReservation?
    private var scratchPayload: LibertySourceStorageReservation?
    private var rowIndicesPayload: LibertySourceStorageReservation?
    private var conductancePayload: LibertySourceStorageReservation?
    private var capacitancePayload: LibertySourceStorageReservation?
    private var valuesPayload: LibertySourceStorageReservation?
    private var nonzeros = 0
    private var factored = false
    private var closed = false

    init(conductance g: S.CSR, capacitance c: S.CSR?, numerical: N, work: inout UInt64) throws {
        self.numerical = numerical; dimension = g.rows
        do {
            try Self.validateDimensions(rows: g.rows, columns: g.columns)
            try validate(g, work: &work)
            if let c {
                guard c.rows == dimension, c.columns == dimension else { throw invalid("native C/G shape") }
                try validate(c, work: &work)
            }
            wordsPerRow = try sum(dimension, 63) / 64
            adjacencyCount = try product(dimension, wordsPerRow)
            adjacency = try storage(count: adjacencyCount, zero: UInt64(0), payload: &adjacencyPayload, work: &work)
            degrees = try storage(count: dimension, zero: 0, payload: &degreesPayload, work: &work)
            neighbors = try storage(count: dimension, zero: 0, payload: &neighborsPayload, work: &work)
            order = try storage(count: dimension, zero: 0, payload: &orderPayload, work: &work)
            inverse = try storage(count: dimension, zero: 0, payload: &inversePayload, work: &work)
            columnStarts = try storage(count: dimension + 1, zero: 0, payload: &columnStartsPayload, work: &work)
            scratch = try storage(count: dimension, zero: 0.0, payload: &scratchPayload, work: &work)
            try resetGraph(g, c, work: &work)
            for column in 0..<dimension {
                try numerical.tick(&work, dimension)
                var selected = -1, degree = Int.max
                for vertex in 0..<dimension where degrees![vertex] >= 0 {
                    if degrees![vertex] < degree { selected = vertex; degree = degrees![vertex] }
                }
                guard selected >= 0 else { throw invalid("native symbolic active vertex missing") }
                order![column] = selected; inverse![selected] = column
                columnStarts![column + 1] = try sum(degree, 1)
                try eliminate(selected, work: &work)
            }
            for column in 0..<dimension {
                try numerical.tick(&work)
                columnStarts![column + 1] = try sum(columnStarts![column], columnStarts![column + 1])
            }
            nonzeros = columnStarts![dimension]
            rowIndices = try storage(count: nonzeros, zero: Int32(0), payload: &rowIndicesPayload, work: &work)
            conductance = try storage(count: nonzeros, zero: 0.0, payload: &conductancePayload, work: &work)
            capacitance = try storage(count: nonzeros, zero: 0.0, payload: &capacitancePayload, work: &work)
            values = try storage(count: nonzeros, zero: 0.0, payload: &valuesPayload, work: &work)
            try resetGraph(g, c, work: &work)
            for column in 0..<dimension {
                try numerical.tick(&work, dimension - column)
                let vertex = order![column], begin = columnStarts![column], end = columnStarts![column + 1]
                guard degrees![vertex] + 1 == end - begin else { throw invalid("native symbolic pass count mismatch") }
                rowIndices![begin] = Int32(column)
                var offset = begin + 1
                for row in (column + 1)..<dimension {
                    if hasEdge(vertex, order![row]) {
                        guard offset < end else { throw invalid("native symbolic fill overflow") }
                        rowIndices![offset] = Int32(row); offset += 1
                    }
                }
                guard offset == end else { throw invalid("native symbolic fill count mismatch") }
                try eliminate(vertex, work: &work)
            }
            let entries = try sum(g.values.count, c?.values.count ?? 0)
            let searchDepth = Int.bitWidth - dimension.leadingZeroBitCount + 1
            try numerical.tick(&work, try product(entries, searchDepth + 4))
            try visitLower(g, c, work: &work) { row, column, gv, cv in
                let a = self.inverse![row], b = self.inverse![column]
                let offset = try self.location(column: min(a, b), row: max(a, b))
                self.conductance![offset] = gv; self.capacitance![offset] = cv
            }
            releaseSymbolic()
            try numerical.tick(&work, 0); try A.check()
        } catch { close(); throw error }
    }

    func factor(conductanceScale: Double, capacitanceScale: Double, work: inout UInt64) throws {
        factored = false
        guard !closed, conductanceScale.isFinite, capacitanceScale.isFinite else { throw invalid("invalid native factor lifecycle/scale") }
        try numerical.tick(&work, nonzeros)
        for offset in 0..<nonzeros {
            let value = conductanceScale * conductance![offset] + capacitanceScale * capacitance![offset]
            guard value.isFinite else { throw invalid("nonfinite native pencil value") }
            values![offset] = value
        }
        let searchDepth = Int.bitWidth - dimension.leadingZeroBitCount + 1
        for column in 0..<dimension {
            let begin = columnStarts![column], end = columnStarts![column + 1], degree = end - begin - 1
            let updates = try product(degree, degree + 1) / 2
            let charge = try sum(try product(updates, searchDepth + 4), try sum(try product(degree, 2), 1))
            try numerical.tick(&work, charge)
            let pivot = values![begin]
            guard pivot.isFinite, pivot > 0 else { throw invalid("native Cholesky nonpositive or nonfinite pivot") }
            let diagonal = pivot.squareRoot()
            guard diagonal.isFinite, diagonal > 0 else { throw invalid("native Cholesky invalid square root") }
            values![begin] = diagonal
            for offset in (begin + 1)..<end {
                let value = values![offset] / diagonal
                guard value.isFinite else { throw invalid("nonfinite native Cholesky column") }
                values![offset] = value
            }
            for left in (begin + 1)..<end {
                let targetColumn = Int(rowIndices![left]), factor = values![left]
                for right in left..<end {
                    let target = try location(column: targetColumn, row: Int(rowIndices![right]))
                    let product = values![right] * factor
                    let value = values![target] - product
                    guard product.isFinite, value.isFinite else { throw invalid("nonfinite native Cholesky update") }
                    values![target] = value
                }
            }
        }
        try numerical.tick(&work, 0); try A.check()
        factored = true
    }

    /// RHS columns are permuted, solved and copied back in fixed order; no storage is retained.
    func solve(_ rhs: inout [Double], columns: Int, work: inout UInt64) throws {
        let count = dimension.multipliedReportingOverflow(by: columns)
        guard !closed, factored, columns > 0, Int32(exactly: columns) != nil,
              !count.overflow, rhs.count >= count.partialValue else { throw invalid("native solve shape/lifecycle") }
        try numerical.tick(&work, count.partialValue)
        for offset in 0..<count.partialValue { guard rhs[offset].isFinite else { throw invalid("nonfinite native RHS") } }
        let charge = try sum(try product(nonzeros, 4), try product(dimension, 4))
        for rhsColumn in 0..<columns {
            try numerical.tick(&work, charge)
            let base = rhsColumn * dimension
            for row in 0..<dimension { scratch![row] = rhs[base + order![row]] }
            for column in 0..<dimension {
                let begin = columnStarts![column], end = columnStarts![column + 1]
                let value = scratch![column] / values![begin]
                guard value.isFinite else { throw invalid("nonfinite native forward substitution") }
                scratch![column] = value
                for offset in (begin + 1)..<end {
                    let row = Int(rowIndices![offset]), product = values![offset] * value
                    let updated = scratch![row] - product
                    guard product.isFinite, updated.isFinite else { throw invalid("nonfinite native forward update") }
                    scratch![row] = updated
                }
            }
            for column in stride(from: dimension - 1, through: 0, by: -1) {
                let begin = columnStarts![column], end = columnStarts![column + 1]
                var value = scratch![column]
                for offset in (begin + 1)..<end {
                    let product = values![offset] * scratch![Int(rowIndices![offset])]
                    value -= product
                    guard product.isFinite, value.isFinite else { throw invalid("nonfinite native backward update") }
                }
                value /= values![begin]
                guard value.isFinite else { throw invalid("nonfinite native backward substitution") }
                scratch![column] = value
            }
            for row in 0..<dimension { rhs[base + order![row]] = scratch![row] }
            try numerical.tick(&work, 0)
        }
        try A.check()
    }

    /// Releases every initialized range once, including partial symbolic construction.
    func close() {
        guard !closed else { return }; closed = true; factored = false
        releaseSymbolic()
        release(&order, payload: &orderPayload, count: dimension); release(&inverse, payload: &inversePayload, count: dimension)
        release(&columnStarts, payload: &columnStartsPayload, count: dimension + 1)
        release(&rowIndices, payload: &rowIndicesPayload, count: nonzeros)
        release(&conductance, payload: &conductancePayload, count: nonzeros); release(&capacitance, payload: &capacitancePayload, count: nonzeros)
        release(&values, payload: &valuesPayload, count: nonzeros); release(&scratch, payload: &scratchPayload, count: dimension)
    }

    deinit { close() }

    private func resetGraph(_ g: S.CSR, _ c: S.CSR?, work: inout UInt64) throws {
        try numerical.tick(&work, adjacencyCount)
        for offset in 0..<adjacencyCount { adjacency![offset] = 0 }
        try numerical.tick(&work, try product(try sum(g.values.count, c?.values.count ?? 0), 4))
        try visitLower(g, c, work: &work) { row, column, _, _ in
            if row != column {
                self.adjacency![row * self.wordsPerRow + column / 64] |= UInt64(1) << (column % 64)
                self.adjacency![column * self.wordsPerRow + row / 64] |= UInt64(1) << (row % 64)
            }
        }
        for row in 0..<dimension {
            try numerical.tick(&work, wordsPerRow)
            var degree = 0
            for word in 0..<wordsPerRow { degree += adjacency![row * wordsPerRow + word].nonzeroBitCount }
            degrees![row] = degree
        }
    }

    private func hasEdge(_ row: Int, _ column: Int) -> Bool {
        adjacency![row * wordsPerRow + column / 64] & (UInt64(1) << (column % 64)) != 0
    }

    private func eliminate(_ vertex: Int, work: inout UInt64) throws {
        let degree = degrees![vertex]
        guard degree >= 0, degree < dimension else { throw invalid("native symbolic degree invariant") }
        let charge = try sum(try product(try product(degree, wordsPerRow), 10), try sum(try product(wordsPerRow, 3), try product(degree, 3)))
        try numerical.tick(&work, charge)
        var count = 0
        for word in 0..<wordsPerRow {
            var mask = adjacency![vertex * wordsPerRow + word]
            while mask != 0 {
                let neighbor = word * 64 + mask.trailingZeroBitCount
                guard neighbor < dimension, count < degree, degrees![neighbor] >= 0 else { throw invalid("native symbolic neighbor invariant") }
                neighbors![count] = neighbor; count += 1
                mask &= mask - 1
            }
        }
        guard count == degree else { throw invalid("native symbolic degree count mismatch") }
        for index in 0..<count {
            let neighbor = neighbors![index]
            var added = 0
            for word in 0..<wordsPerRow {
                let offset = neighbor * wordsPerRow + word, old = adjacency![offset]
                var mask = adjacency![vertex * wordsPerRow + word]
                if word == neighbor / 64 { mask &= ~(UInt64(1) << (neighbor % 64)) }
                added += (mask & ~old).nonzeroBitCount
                var updated = old | mask
                if word == vertex / 64 { updated &= ~(UInt64(1) << (vertex % 64)) }
                adjacency![offset] = updated
            }
            degrees![neighbor] += added - 1
        }
        degrees![vertex] = -1
    }

    private func location(column: Int, row: Int) throws -> Int {
        var lower = columnStarts![column], upper = columnStarts![column + 1]
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Int(rowIndices![middle]) < row { lower = middle + 1 } else { upper = middle }
        }
        guard lower < columnStarts![column + 1], Int(rowIndices![lower]) == row else { throw invalid("native symbolic update target missing") }
        return lower
    }

    private func validate(_ matrix: S.CSR, work: inout UInt64) throws {
        guard matrix.rows >= 0, matrix.rows == matrix.columns, matrix.rowOffsets.count == matrix.rows + 1,
              matrix.rowOffsets.first == 0, matrix.rowOffsets.last == matrix.values.count,
              matrix.columnIndices.count == matrix.values.count else { throw invalid("native CSR shape") }
        for row in 0..<matrix.rows {
            let begin = matrix.rowOffsets[row], end = matrix.rowOffsets[row + 1]
            guard begin >= 0, end >= begin, end <= matrix.values.count else { throw invalid("native CSR offsets") }
            var previous = -1
            for offset in begin..<end {
                try numerical.tick(&work)
                let column = matrix.columnIndices[offset], value = matrix.values[offset]
                guard column > previous, column < matrix.columns, value.lowerBound.isFinite, value.upperBound.isFinite else { throw invalid("native CSR indices/value") }
                previous = column
            }
        }
    }

    private func visitLower(_ g: S.CSR, _ c: S.CSR?, work: inout UInt64,
        body: (Int, Int, Double, Double) throws -> Void) throws {
        for row in 0..<dimension {
            var gi = g.rowOffsets[row], ci = c?.rowOffsets[row] ?? 0
            let ge = g.rowOffsets[row + 1], ce = c?.rowOffsets[row + 1] ?? 0
            while gi < ge || ci < ce {
                try numerical.tick(&work)
                let gc = gi < ge ? g.columnIndices[gi] : Int.max
                let cc = ci < ce ? c!.columnIndices[ci] : Int.max
                let column = min(gc, cc)
                let gv = gc == column ? midpoint(g.values[gi]) : 0
                let cv = cc == column ? midpoint(c!.values[ci]) : 0
                if column <= row { try body(row, column, gv, cv) }
                if gc == column { gi += 1 }; if cc == column { ci += 1 }
            }
        }
    }

    /// Raw storage is covered by the lease's one quota-slot reservation, never charged twice.
    private func storage<T>(count: Int, zero: T, payload: inout LibertySourceStorageReservation?, work: inout UInt64) throws -> UnsafeMutablePointer<T> {
        let bytes = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
        guard count > 0, !bytes.overflow else { throw invalid("native storage byte count overflow") }
        try numerical.tick(&work, count)
        payload = try numerical.budget.reservePayload(T.self, capacity: count, kind: .temporaryBytes)
        let raw = try A.allocate(bytes.partialValue)
        let pointer = raw.bindMemory(to: T.self, capacity: count)
        pointer.initialize(repeating: zero, count: count)
        return pointer
    }

    private func release<T>(_ pointer: inout UnsafeMutablePointer<T>?, payload: inout LibertySourceStorageReservation?, count: Int) {
        defer { payload = nil }
        guard let owned = pointer else { return }
        owned.deinitialize(count: count); A.release(UnsafeMutableRawPointer(owned)); pointer = nil
    }

    private func releaseSymbolic() {
        release(&adjacency, payload: &adjacencyPayload, count: adjacencyCount)
        release(&degrees, payload: &degreesPayload, count: dimension); release(&neighbors, payload: &neighborsPayload, count: dimension)
    }

    private func sum(_ a: Int, _ b: Int) throws -> Int {
        let value = a.addingReportingOverflow(b)
        guard !value.overflow else { throw invalid("native operation count overflow") }
        return value.partialValue
    }
    private func product(_ a: Int, _ b: Int) throws -> Int {
        let value = a.multipliedReportingOverflow(by: b)
        guard !value.overflow else { throw invalid("native operation count overflow") }
        return value.partialValue
    }
    static func validateDimensions(rows: Int, columns: Int) throws {
        guard rows > 0, rows < Int.max, Int32(exactly: rows) != nil, columns == rows else {
            throw NativeSTAConservativeCouplingError.nativeBackendFailure("native dimension exceeds row-index storage or is not square")
        }
    }
    private func midpoint(_ value: TimingNumericInterval) -> Double { value.lowerBound / 2 + value.upperBound / 2 }
    private func invalid(_ detail: String) -> NativeSTAConservativeCouplingError { .nativeBackendFailure(detail) }
}

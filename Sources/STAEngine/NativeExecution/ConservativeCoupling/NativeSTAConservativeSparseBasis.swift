import TimingCore

/// Block-local exact binary coordinate proposals; only verified transformed operators are returned.
internal struct NativeSTAConservativeSparseBasis {
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias I = TimingNumericInterval
    typealias Graph = NativeSTAConservativeSparseGraph
    enum Candidate: Sendable { case localModal, whitening, identity }
    private struct Block {
        let q: N.Matrix
        let transpose: N.Matrix
        let mass: N.Matrix
    }
    let numerical: N

    func transform(_ reduced: Graph.Reduced, candidate: Candidate, maximumSweeps: Int,
                   work: inout UInt64) throws -> Graph.Operators {
        let d = reduced.dynamicRows.count, sources = reduced.forcing.columns
        guard maximumSweeps >= 0, reduced.conductance.rows == d, reduced.conductance.columns == d,
              reduced.capacitance.rows == d, reduced.capacitance.columns == d, reduced.forcing.rows == d,
              reduced.reconstruction.columns == d, reduced.dcIncidence.rows == reduced.reconstruction.rows,
              reduced.dcIncidence.columns == sources else { throw invalid("shape") }
        let scratch = NativeSTATransformStorage(budget: numerical.budget, kind: .temporaryBytes)
        defer { withExtendedLifetime(scratch) {} }
        try numerical.slots(d, times: 2)
        var blockOf = try scratch.repeated(-1, count: d)
        var localOf = try scratch.repeated(-1, count: d)
        for (index, block) in reduced.capBlocks.enumerated() {
            guard !block.isEmpty else { throw invalid("empty partition block") }
            var previous = -1
            for (local, row) in block.enumerated() {
                try numerical.tick(&work)
                guard row >= 0, row < d, row > previous, blockOf[row] == -1 else { throw invalid("partition") }
                blockOf[row] = index; localOf[row] = local; previous = row
            }
        }
        for row in 0..<d { try numerical.tick(&work); guard blockOf[row] >= 0 else { throw invalid("incomplete partition") } }
        try numerical.slots(reduced.capBlocks.count, times: 3)
        try scratch.reserve(Block.self, capacity: reduced.capBlocks.count)
        var coordinates: [Block] = []; coordinates.reserveCapacity(reduced.capBlocks.count)
        let zero = try I(point: 0)
        for (blockIndex, block) in reduced.capBlocks.enumerated() {
            let count = block.count
            var c = try numerical.matrix(count, count), g = try numerical.matrix(count, count)
            for (i, row) in block.enumerated() {
                for offset in reduced.capacitance.rowOffsets[row]..<reduced.capacitance.rowOffsets[row + 1] {
                    try numerical.tick(&work)
                    let column = reduced.capacitance.columnIndices[offset]
                    guard blockOf[column] == blockIndex else { throw invalid("capacitance cross-block entry") }
                    c[i, localOf[column]] = reduced.capacitance.values[offset]
                }
                for offset in reduced.conductance.rowOffsets[row]..<reduced.conductance.rowOffsets[row + 1] {
                    try numerical.tick(&work)
                    let column = reduced.conductance.columnIndices[offset]
                    if blockOf[column] == blockIndex { g[i, localOf[column]] = reduced.conductance.values[offset] }
                }
            }
            var q: N.Matrix
            if count == 1 {
                q = try numerical.identity(1, work: &work)
            } else if case .identity = candidate {
                q = try numerical.identity(count, work: &work)
            } else {
                var maximumDiagonal = 0.0
                for i in 0..<count {
                    try numerical.tick(&work)
                    maximumDiagonal = max(maximumDiagonal, c[i, i].lowerBound / 2 + c[i, i].upperBound / 2)
                }
                let scale = maximumDiagonal.squareRoot()
                guard scale.isFinite, scale > 0 else {
                    throw NativeSTAConservativeCandidateNotCertified(reason: "local basis scale not finite and positive")
                }
                let sweeps: Int
                switch candidate { case .localModal: sweeps = maximumSweeps; case .whitening, .identity: sweeps = 0 }
                let proposed = try candidateProof { try numerical.basis(c, g, sweeps: sweeps, work: &work) }
                q = try numerical.matrix(count, count)
                for i in q.values.indices {
                    try numerical.tick(&work)
                    let value = proposed.values[i].lowerBound * scale
                    guard value.isFinite else {
                        throw NativeSTAConservativeCandidateNotCertified(reason: "local basis candidate entry not finite")
                    }
                    // Exact binary coordinates define the transform; approximation accuracy grants no authority.
                    q.values[i] = try I(point: value)
                }
            }
            let qt = try numerical.transpose(q, work: &work)
            let mass = try numerical.product(qt, numerical.product(c, q, work: &work), work: &work)
            // Verified mass positivity proves Q invertible without trusting Cholesky/Jacobi proposals.
            try candidateProof { try numerical.positiveDefinite(mass, work: &work) }
            coordinates.append(Block(q: q, transpose: qt, mass: mass))
        }
        try numerical.slots(d, times: 2)
        var aRows = try NativeSTAConservativeRowStorage(count: d, numerical: numerical)
        var jRows = try NativeSTAConservativeRowStorage(count: d, numerical: numerical)
        for (blockIndex, block) in reduced.capBlocks.enumerated() {
            let count = block.count, coordinate = coordinates[blockIndex]
            let blockStorage = NativeSTATransformStorage(budget: numerical.budget, kind: .temporaryBytes)
            defer { withExtendedLifetime(blockStorage) {} }
            try blockStorage.reserveSet(Int.self, capacity: reduced.capBlocks.count)
            var neighborSet: Set<Int> = []
            if numerical.budget.transformResources != nil { neighborSet.reserveCapacity(reduced.capBlocks.count) }
            for row in block {
                for offset in reduced.conductance.rowOffsets[row]..<reduced.conductance.rowOffsets[row + 1] {
                    try numerical.tick(&work)
                    let neighbor = blockOf[reduced.conductance.columnIndices[offset]]
                    if !neighborSet.contains(neighbor) { try numerical.slots(1); neighborSet.insert(neighbor) }
                }
            }
            try numerical.slots(neighborSet.count)
            try blockStorage.reserve(Int.self, capacity: neighborSet.count)
            try blockStorage.reserve(Int.self, capacity: neighborSet.count)
            let neighbors = try neighborSet.sorted { left, right in try numerical.tick(&work); return left < right }
            var columnCount = 0
            for neighbor in neighbors { try numerical.tick(&work); columnCount = try sum(columnCount, reduced.capBlocks[neighbor].count) }
            try numerical.slots(neighbors.count, times: 2); try numerical.slots(columnCount)
            try blockStorage.reserveDictionary(Int.self, Int.self, capacity: neighbors.count)
            try blockStorage.reserve(Int.self, capacity: columnCount)
            var offsets: [Int: Int] = [:]; offsets.reserveCapacity(neighbors.count)
            var columns: [Int] = []; columns.reserveCapacity(columnCount)
            for neighbor in neighbors {
                try numerical.tick(&work); offsets[neighbor] = columns.count
                for column in reduced.capBlocks[neighbor] { try numerical.tick(&work); columns.append(column) }
            }
            // Reserve every possible transformed off-block entry, including zeros, before dictionary allocation.
            try numerical.slots(try product(count, columnCount), times: 3)
            try numerical.slots(try product(count, sources), times: 3)
            var rhs = try numerical.matrix(count, try sum(columnCount, sources))
            for (i, row) in block.enumerated() {
                for offset in reduced.conductance.rowOffsets[row]..<reduced.conductance.rowOffsets[row + 1] {
                    let column = reduced.conductance.columnIndices[offset], targetBlock = blockOf[column]
                    guard let targetOffset = offsets[targetBlock] else { throw invalid("missing neighbor block") }
                    let right = coordinates[targetBlock].q, j = localOf[column]
                    for leftMode in 0..<count { for rightMode in 0..<right.columns {
                        try numerical.tick(&work)
                        let value = try coordinate.transpose[leftMode, i]
                            .multiplied(by: reduced.conductance.values[offset]).multiplied(by: right[j, rightMode])
                        rhs[leftMode, targetOffset + rightMode] = try rhs[leftMode, targetOffset + rightMode].adding(value)
                    } }
                }
                for leftMode in 0..<count { for source in 0..<sources {
                    try numerical.tick(&work)
                    rhs[leftMode, columnCount + source] = try rhs[leftMode, columnCount + source]
                        .adding(coordinate.transpose[leftMode, i].multiplied(by: reduced.forcing[row, source]))
                } }
            }
            let solved = try candidateProof { try numerical.solve(coordinate.mass, rhs, work: &work) }
            for (i, row) in block.enumerated() {
                for (j, column) in columns.enumerated() {
                    try numerical.tick(&work); try aRows.set(solved[i, j].negated(), row: row, column: column)
                }
                for source in 0..<sources { try numerical.tick(&work); try jRows.set(solved[i, columnCount + source].negated(), row: row, column: source) }
            }
        }
        var reconstructionFill = 0
        for column in reduced.reconstruction.columnIndices {
            try numerical.tick(&work)
            reconstructionFill = try sum(reconstructionFill, reduced.capBlocks[blockOf[column]].count)
        }
        try numerical.slots(reduced.reconstruction.rows)
        try numerical.slots(reconstructionFill, times: 3)
        var tRows = try NativeSTAConservativeRowStorage(count: reduced.reconstruction.rows, numerical: numerical)
        for row in 0..<reduced.reconstruction.rows {
            for offset in reduced.reconstruction.rowOffsets[row]..<reduced.reconstruction.rowOffsets[row + 1] {
                let column = reduced.reconstruction.columnIndices[offset], targetBlock = blockOf[column]
                let q = coordinates[targetBlock].q
                for (mode, targetColumn) in reduced.capBlocks[targetBlock].enumerated() {
                    try numerical.tick(&work)
                    let value = try reduced.reconstruction.values[offset].multiplied(by: q[localOf[column], mode])
                    try tRows.set((tRows[row][targetColumn] ?? zero).adding(value), row: row, column: targetColumn)
                }
            }
        }
        let solver = S(numerical: numerical)
        return Graph.Operators(dynamicRows: reduced.dynamicRows,
            a: try solver.fromRows(aRows, columns: d, work: &work),
            j: try solver.fromRows(jRows, columns: sources, work: &work),
            reconstruction: try solver.fromRows(tRows, columns: d, work: &work), dcIncidence: reduced.dcIncidence, transformRetention: reduced.transformRetention)
    }

    private func candidateProof<Result>(_ operation: () throws -> Result) throws -> Result {
        do { return try operation() }
        catch let error as NativeSTAConservativeCouplingError {
            if case .invalidCertificate(let reason) = error {
                throw NativeSTAConservativeCandidateNotCertified(reason: reason)
            }
            throw error
        }
    }

    private func sum(_ first: Int, _ second: Int) throws -> Int {
        let result = first.addingReportingOverflow(second)
        guard !result.overflow else { throw invalid("fill overflow") }; return result.partialValue
    }
    private func product(_ first: Int, _ second: Int) throws -> Int {
        let result = first.multipliedReportingOverflow(by: second)
        guard !result.overflow else { throw invalid("fill overflow") }; return result.partialValue
    }
    private func invalid(_ reason: String) -> NativeSTAConservativeCouplingError { .invalidPrimitive("sparse basis " + reason) }
}

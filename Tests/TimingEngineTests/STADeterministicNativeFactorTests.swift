import Testing
import TimingCore
@testable import STAEngine

@Suite("Deterministic native sparse Cholesky", .timeLimit(.minutes(1)))
struct STADeterministicNativeFactorTests {
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias A = NativeSTAConservativeNativeAllocation
    typealias F = NativeSTAConservativeNativeFactor
    typealias I = TimingNumericInterval
    private enum ProbeFailure: Error { case deliberate }

    private func context(workLimit: UInt64 = 1_000_000_000_000, slots: Int = 1_000_000) throws -> N {
        N(limits: try .init(maximumPathStates: slots, maximumPathWorkUnits: workLimit),
          budget: .init(maximum: slots), resources: nil)
    }

    private func sparse(_ values: [[Double]], numerical: N, work: inout UInt64) throws -> S.CSR {
        var rows = Array(repeating: [Int: I](), count: values.count)
        for row in values.indices {
            for column in values[row].indices where values[row][column] != 0 {
                rows[row][column] = try I(point: values[row][column])
            }
        }
        return try S(numerical: numerical).fromRows(rows, columns: values.count, work: &work)
    }

    private func pencil(_ g: [[Double]], _ c: [[Double]], _ gs: Double, _ cs: Double) -> [[Double]] {
        var result = g
        for row in g.indices {
            for column in g[row].indices { result[row][column] = gs * g[row][column] + cs * c[row][column] }
        }
        return result
    }

    private func multiply(_ matrix: [[Double]], _ columns: [Double]) -> [Double] {
        let size = matrix.count
        var result = Array(repeating: 0.0, count: columns.count)
        for column in 0..<(columns.count / size) {
            for row in 0..<size {
                for k in 0..<size { result[column * size + row] += matrix[row][k] * columns[column * size + k] }
            }
        }
        return result
    }

    // Partial-pivot Gaussian elimination is independent of the sparse Cholesky implementation.
    private func reference(_ matrix: [[Double]], rhs: [Double]) throws -> [Double] {
        let size = matrix.count
        var a = matrix, result = rhs
        let columns = rhs.count / size
        for k in 0..<size {
            var pivot = k
            for row in k..<size where abs(a[row][k]) > abs(a[pivot][k]) { pivot = row }
            try #require(abs(a[pivot][k]) > 1e-15)
            if pivot != k {
                a.swapAt(pivot, k)
                for column in 0..<columns { result.swapAt(column * size + pivot, column * size + k) }
            }
            for row in (k + 1)..<size {
                let scale = a[row][k] / a[k][k]
                for j in k..<size { a[row][j] -= scale * a[k][j] }
                for column in 0..<columns { result[column * size + row] -= scale * result[column * size + k] }
            }
        }
        for column in 0..<columns {
            for row in stride(from: size - 1, through: 0, by: -1) {
                var value = result[column * size + row]
                for k in (row + 1)..<size { value -= a[row][k] * result[column * size + k] }
                result[column * size + row] = value / a[row][row]
            }
        }
        return result
    }

    private func expectBackend(_ body: () throws -> Void) throws {
        do { try body(); Issue.record("Expected a typed native backend refusal") }
        catch let error as NativeSTAConservativeCouplingError {
            guard case .nativeBackendFailure = error else { throw error }
        }
    }

    private func expectCapacity(_ body: () throws -> Void) throws {
        do { try body(); Issue.record("Expected a typed resource capacity refusal") }
        catch let error as STAPathAnalysisError {
            guard case .capacity = error else { throw error }
        }
    }

    @Test func nonuniformSparseGridFreshOwnersAndRefactorsMatchBits() throws {
        let n = try context(); var work: UInt64 = 0
        // These grid dimensions are fixture data, not production size limits.
        let width = 4, height = 5, size = width * height
        var g = Array(repeating: Array(repeating: 0.0, count: size), count: size)
        var c = g
        for row in 0..<size {
            g[row][row] = 0.75 + Double(row % 5) / 8
            c[row][row] = 0.5 + Double(row % 7) / 16
            for adjacent in [row + 1, row + width] {
                guard adjacent < size, adjacent != row + 1 || row % width != width - 1 else { continue }
                let weight = 0.25 + Double((row * 17 + adjacent * 3) % 13) / 32
                g[row][row] += weight; g[adjacent][adjacent] += weight
                g[row][adjacent] = -weight; g[adjacent][row] = -weight
            }
        }
        // A C-only edge exercises the union pattern as well as off-diagonal capacitance.
        c[0][0] += 0.125; c[size - 1][size - 1] += 0.125
        c[0][size - 1] = -0.125; c[size - 1][0] = -0.125
        let gs = try sparse(g, numerical: n, work: &work), cs = try sparse(c, numerical: n, work: &work)
        let physical = pencil(g, c, 0.75, 1.25)
        let expected = (0..<(size * 3)).map { Double(($0 * 7) % 19 - 9) / 8 }
        let rhs = multiply(physical, expected)
        let (_, statistics) = try A.withLease(dimension: size, nonzeros: gs.values.count + cs.values.count,
            numerical: n, work: &work) { work in
                var baseline: [UInt64] = []
                for owner in 0..<3 {
                    let factor = try F(conductance: gs, capacitance: cs, numerical: n, work: &work)
                    defer { factor.close() }
                    for pass in 0..<3 {
                        if pass == 2 { try factor.factor(conductanceScale: 2, capacitanceScale: 0.25, work: &work) }
                        try factor.factor(conductanceScale: 0.75, capacitanceScale: 1.25, work: &work)
                        var solution = rhs
                        try factor.solve(&solution, columns: 3, work: &work)
                        let bits = solution.map(\.bitPattern)
                        if owner == 0 && pass == 0 { baseline = bits } else { #expect(bits == baseline) }
                        for i in solution.indices { #expect(abs(solution[i] - expected[i]) < 2e-12) }
                        let reconstructed = multiply(physical, solution)
                        for i in rhs.indices { #expect(abs(reconstructed[i] - rhs[i]) < 2e-12) }
                    }
                }
            }
        #expect(statistics.outstandingAllocations == 0)
    }

    @Test func multiplePencilsAndRHSMatchIndependentDenseReference() throws {
        let n = try context(); var work: UInt64 = 0
        let g = [[7.0, -2, -0.25, 0], [-2, 6, -1, -0.5], [-0.25, -1, 5, -0.75], [0, -0.5, -0.75, 4]]
        let c = [[2.0, -0.2, 0, 0], [-0.2, 1.5, -0.1, 0], [0, -0.1, 3, -0.3], [0, 0, -0.3, 1]]
        let gs = try sparse(g, numerical: n, work: &work), cs = try sparse(c, numerical: n, work: &work)
        let rhs = [1.0, -2, 0.5, 4, 0, 0, 0, 0, -3, 2, 7, -1]
        let (_, statistics) = try A.withLease(dimension: 4, nonzeros: gs.values.count + cs.values.count,
            numerical: n, work: &work) { work in
                let factor = try F(conductance: gs, capacitance: cs, numerical: n, work: &work)
                defer { factor.close() }
                for (gScale, cScale) in [(1.0, 0.0), (0.25, 1.0), (0.0, 1.0)] {
                    let expected = try reference(pencil(g, c, gScale, cScale), rhs: rhs)
                    try factor.factor(conductanceScale: gScale, capacitanceScale: cScale, work: &work)
                    var actual = rhs
                    try factor.solve(&actual, columns: 3, work: &work)
                    for i in actual.indices { #expect(abs(actual[i] - expected[i]) < 2e-12) }
                }
            }
        #expect(statistics.outstandingAllocations == 0)
    }

    @Test func pivotNonfiniteAndLifecycleRefusalsNeverReuseAStaleFactor() throws {
        let n = try context(); var work: UInt64 = 0
        let g = try sparse([[2.0, -0.5], [-0.5, 1]], numerical: n, work: &work)
        let singular = try sparse([[1.0, 1], [1, 1]], numerical: n, work: &work)
        let indefinite = try sparse([[1.0, 2], [2, 1]], numerical: n, work: &work)
        let (_, statistics) = try A.withLease(dimension: 2, nonzeros: 12, numerical: n, work: &work) { work in
            for matrix in [singular, indefinite] {
                let factor = try F(conductance: matrix, capacitance: nil, numerical: n, work: &work)
                defer { factor.close() }
                try expectBackend { try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work) }
                var rhs = [1.0, 2]
                try expectBackend { try factor.solve(&rhs, columns: 1, work: &work) }
            }
            let factor = try F(conductance: g, capacitance: nil, numerical: n, work: &work)
            defer { factor.close() }
            try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work)
            try expectBackend { try factor.factor(conductanceScale: -1, capacitanceScale: 0, work: &work) }
            var rhs = [1.0, 2]
            try expectBackend { try factor.solve(&rhs, columns: 1, work: &work) }
            for scale in [Double.nan, Double.infinity] {
                try expectBackend { try factor.factor(conductanceScale: scale, capacitanceScale: 0, work: &work) }
            }
            try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work)
            for value in [Double.nan, Double.infinity] {
                var invalid = [value, 1]
                try expectBackend { try factor.solve(&invalid, columns: 1, work: &work) }
            }
            var recovered = [1.0, 2]
            try factor.solve(&recovered, columns: 1, work: &work)
            #expect(abs(2 * recovered[0] - 0.5 * recovered[1] - 1) < 1e-12)
            factor.close(); factor.close()
            try expectBackend { try factor.solve(&rhs, columns: 1, work: &work) }
            try expectBackend { try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work) }
        }
        #expect(statistics.outstandingAllocations == 0)
    }

    @Test func resourceAndInjectedAllocationFailuresKeepTheirCategories() throws {
        let n = try context(); var work: UInt64 = 0
        let g = try sparse([[2.0, -0.5], [-0.5, 1]], numerical: n, work: &work)
        try expectCapacity {
            _ = try A.withLease(dimension: 2, nonzeros: g.values.count, numerical: n,
                policy: .init(quotaBytes: 32, recordCapacity: 1), work: &work) { work in
                    let factor = try F(conductance: g, capacitance: nil, numerical: n, work: &work)
                    factor.close()
                }
        }
        try expectBackend {
            _ = try A.withLease(dimension: 2, nonzeros: g.values.count, numerical: n,
                policy: .init(quotaBytes: 16_384, recordCapacity: 64, failAfterAllocations: 1), work: &work) { work in
                    let factor = try F(conductance: g, capacitance: nil, numerical: n, work: &work)
                    factor.close()
                }
        }
        let bounded = try context(workLimit: 100_000)
        var boundedWork: UInt64 = 0
        let (_, statistics) = try A.withLease(dimension: 2, nonzeros: g.values.count, numerical: bounded,
            work: &boundedWork) { work in
                let factor = try F(conductance: g, capacitance: nil, numerical: bounded, work: &work)
                defer { factor.close() }
                work = bounded.limits.maximumPathWorkUnits
                try expectCapacity { try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work) }
                // The final lease cancellation check charges zero work, preserving the exhausted limit.
            }
        #expect(statistics.outstandingAllocations == 0)
        let storage = try context(slots: 16)
        var storageWork: UInt64 = 0
        try expectCapacity {
            _ = try A.withLease(dimension: 2, nonzeros: g.values.count, numerical: storage,
                policy: .init(quotaBytes: 1_024, recordCapacity: 8), work: &storageWork) { _ in
                    Issue.record("Unadmitted native storage entered the factor body")
                }
        }
    }

    @Test func thrownBodyClosesBeforeLeaseFinishAndAllowsAFreshOwner() throws {
        let n = try context(); var work: UInt64 = 0
        let g = try sparse([[2.0]], numerical: n, work: &work)
        let (_, statistics) = try A.withLease(dimension: 1, nonzeros: 1, numerical: n, work: &work) { work in
            func fail(_ work: inout UInt64) throws {
                let factor = try F(conductance: g, capacitance: nil, numerical: n, work: &work)
                defer { factor.close(); factor.close() }
                try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work)
                throw ProbeFailure.deliberate
            }
            do { try fail(&work); Issue.record("Expected deliberate body failure") }
            catch ProbeFailure.deliberate { }
            let next = try F(conductance: g, capacitance: nil, numerical: n, work: &work)
            defer { next.close() }
            try next.factor(conductanceScale: 1, capacitanceScale: 0, work: &work)
            var rhs = [4.0]
            try next.solve(&rhs, columns: 1, work: &work)
            #expect(abs(rhs[0] - 2) < 2e-15)
            #expect(abs(2 * rhs[0] - 4) < 4e-15)
        }
        // A successful lease reports outstanding allocations before emergency cleanup.
        #expect(statistics.outstandingAllocations == 0)
    }

    @Test func cancellationAfterInitializationPropagatesAndReleasesTheLease() async throws {
        let task = Task {
            let n = try context(); var work: UInt64 = 0
            let g = try sparse([[2.0]], numerical: n, work: &work)
            do {
                _ = try A.withLease(dimension: 1, nonzeros: 1, numerical: n, work: &work) { work in
                    let factor = try F(conductance: g, capacitance: nil, numerical: n, work: &work)
                    defer { factor.close() }
                    withUnsafeCurrentTask { $0?.cancel() }
                    try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work)
                }
                Issue.record("Cancelled factor operation unexpectedly succeeded")
            } catch is CancellationError { }
        }
        try await task.value
        let n = try context(); var work: UInt64 = 0
        let g = try sparse([[2.0]], numerical: n, work: &work)
        let (_, statistics) = try A.withLease(dimension: 1, nonzeros: 1, numerical: n, work: &work) { work in
            let factor = try F(conductance: g, capacitance: nil, numerical: n, work: &work)
            defer { factor.close() }
            try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work)
        }
        #expect(statistics.outstandingAllocations == 0)
    }
}

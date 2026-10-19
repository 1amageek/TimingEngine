import Testing
import Synchronization
import TimingCore
@testable import STAEngine

@Suite("Sparse conservative numerical certificates", .timeLimit(.minutes(1)))
struct STAConservativeSparseNumericsTests {
    typealias S = NativeSTAConservativeSparseNumerics
    typealias I = TimingNumericInterval

    private func helper(workLimit: UInt64 = 100_000_000, slots: Int = 1_000_000) throws -> S {
        let limits = try STAExecutionLimits(maximumPathStates: slots, maximumPathWorkUnits: workLimit)
        return S(numerical: .init(limits: limits, budget: .init(maximum: slots), resources: nil))
    }
    private func matrix(_ helper: S, _ values: [[Double]]) throws -> NativeSTAConservativeNumerics.Matrix {
        var result = try helper.numerical.matrix(values.count, values.first?.count ?? 0)
        for row in values.indices { for column in values[row].indices { result[row, column] = try I(point: values[row][column]) } }
        return result
    }
    private func generator(_ helper: S, work: inout UInt64) throws -> S.CSR {
        try helper.fromRows([[0: I(point: -4), 1: I(point: 1)], [0: I(point: 2), 1: I(point: -3)]], columns: 2, work: &work)
    }

    @Test func sparseProductPreservesKnownZeroSupportAndEnclosesDenseReference() throws {
        let s = try helper(); var work: UInt64 = 0
        let a = try s.fromRows([[2: I(point: 2), 0: I(point: -3), 1: I(point: 0)], [:], [1: I(point: 4)]], columns: 3, work: &work)
        #expect(a.rowOffsets == [0, 2, 2, 3] && a.columnIndices == [0, 2, 1])
        let rhs = try matrix(s, [[1, 0], [2, 0], [4, 0]])
        let result = try s.product(a, rhs, work: &work)
        #expect(result[0, 0].lowerBound <= 5 && result[0, 0].upperBound >= 5)
        #expect(try result[1, 0] == I(point: 0) && result[2, 0].lowerBound <= 8 && result[2, 0].upperBound >= 8)
        for row in 0..<3 { #expect(try result[row, 1] == I(point: 0)) }
        let magnitude = try s.magnitude(a, work: &work)
        let negative = try s.negated(a, work: &work)
        #expect(magnitude.columnIndices == a.columnIndices && magnitude.values[0].lowerBound == 3)
        #expect(negative.values[0].lowerBound == 3 && negative.values[1].upperBound == -2)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            _ = try s.fromRows([[3: I(point: 1)]], columns: 3, work: &work)
        }
    }

    @Test func signedStableGeneratorResidualEnclosesEveryIntervalVertex() throws {
        let s = try helper(); var work: UInt64 = 0
        let a = try s.fromRows([
            [0: I(-4.001 ... -3.999), 1: I(0.999...1.001)],
            [0: I(1.999...2.001), 1: I(-3.001 ... -2.999)]
        ], columns: 2, work: &work)
        let f = try s.fromRows([[0: I(point: -3.999), 1: I(point: 1.001)],
                               [0: I(point: 2.001), 1: I(point: -2.999)]], columns: 2, work: &work)
        let rhs = try matrix(s, [[-2, 0], [-4, 0]])
        let solved = try s.verifiedSolve(a, rhs, comparison: f, weight: matrix(s, [[1], [1]]), maximumIterations: 32, work: &work)
        for bits in 0..<16 {
            let aa = bits & 1 == 0 ? -4.001 : -3.999
            let ab = bits & 2 == 0 ? 0.999 : 1.001
            let ac = bits & 4 == 0 ? 1.999 : 2.001
            let ad = bits & 8 == 0 ? -3.001 : -2.999
            let determinant = aa * ad - ab * ac
            let x = (-2 * ad + 4 * ab) / determinant
            let y = (-4 * aa + 2 * ac) / determinant
            #expect(solved[0, 0].lowerBound <= x && solved[0, 0].upperBound >= x)
            #expect(solved[1, 0].lowerBound <= y && solved[1, 0].upperBound >= y)
        }
        #expect(try solved[0, 1] == I(point: 0) && solved[1, 1] == I(point: 0))
    }

    @Test func passivePhysicalPencilNeedsALocalCapacitanceBlockBasis() throws {
        let s = try helper(); let n = s.numerical; var work: UInt64 = 0
        // Unit ground capacitors/conductances, C(1,2)=1 and R(0,1)=0.01.
        // These two distinct primitive edges produce a two-node C block and a singleton.
        let c = try matrix(s, [[1, 0, 0], [0, 2, -1], [0, -1, 2]])
        let g = try matrix(s, [[101, -100, 0], [-100, 101, 0], [0, 0, 1]])
        try n.positiveDefinite(c, capacitance: true, work: &work)
        try n.positiveDefinite(g, work: &work)
        func comparison(_ a: NativeSTAConservativeNumerics.Matrix) throws -> NativeSTAConservativeNumerics.Matrix {
            var result = try n.matrix(3, 3)
            for i in 0..<3 { for j in 0..<3 {
                try n.tick(&work)
                result[i, j] = try I(point: i == j ? a[i, j].upperBound : a[i, j].absolute().upperBound)
            } }
            return result
        }
        let originalA = try n.negated(n.solve(c, g, work: &work), work: &work)
        let negativeIdentityF = try n.negated(comparison(originalA), work: &work)
        let firstMinor = try negativeIdentityF[1, 1].multiplied(by: negativeIdentityF[2, 2])
            .subtracting(negativeIdentityF[1, 2].multiplied(by: negativeIdentityF[2, 1]))
        let secondMinor = try negativeIdentityF[1, 0].multiplied(by: negativeIdentityF[2, 2])
            .subtracting(negativeIdentityF[1, 2].multiplied(by: negativeIdentityF[2, 0]))
        let determinant = try negativeIdentityF[0, 0].multiplied(by: firstMinor)
            .subtracting(negativeIdentityF[0, 1].multiplied(by: secondMinor))
        #expect(determinant.upperBound < 0)

        // Generate coordinates only for the actual size-two C block; keep singleton identity.
        let cb = try matrix(s, [[2, -1], [-1, 2]])
        let gb = try matrix(s, [[101, 0], [0, 1]])
        let qb = try n.basis(cb, gb, sweeps: 8, work: &work)
        var q = try n.identity(3, work: &work)
        for i in 0..<2 { for j in 0..<2 { q[i + 1, j + 1] = qb[i, j] } }
        let qt = try n.transpose(q, work: &work)
        let mass = try n.product(qt, n.product(c, q, work: &work), work: &work)
        try n.positiveDefinite(mass, capacitance: true, work: &work)
        let stiffness = try n.product(qt, n.product(g, q, work: &work), work: &work)
        let a = try n.negated(n.solve(mass, stiffness, work: &work), work: &work)
        let f = try comparison(a)
        var rows = Array(repeating: [Int: I](), count: 3)
        for i in 0..<3 { for j in 0..<3 { rows[i][j] = f[i, j] } }
        let sparseF = try s.fromRows(rows, columns: 3, work: &work)
        let ones = try matrix(s, [[1], [1], [1]])
        let w = try s.approximateSolve(s.negated(sparseF, work: &work), ones, maximumIterations: 64, work: &work)
        let fw = try s.product(sparseF, w, work: &work)
        for i in 0..<3 { #expect(w[i, 0].lowerBound > 0 && fw[i, 0].upperBound < 0) }
        #expect(work > 0)
    }

    @Test func localTransformRetainsOffBlockFillForcingAndPhysicalReconstruction() throws {
        let s = try helper(); let n = s.numerical; var work: UInt64 = 0
        func sparse(_ matrix: NativeSTAConservativeNumerics.Matrix) throws -> S.CSR {
            var rows = Array(repeating: [Int: I](), count: matrix.rows)
            for i in 0..<matrix.rows { for j in 0..<matrix.columns { rows[i][j] = matrix[i, j] } }
            return try s.fromRows(rows, columns: matrix.columns, work: &work)
        }
        func dense(_ matrix: S.CSR) throws -> NativeSTAConservativeNumerics.Matrix {
            var result = try n.matrix(matrix.rows, matrix.columns)
            for row in 0..<matrix.rows {
                for offset in matrix.rowOffsets[row]..<matrix.rowOffsets[row + 1] {
                    result[row, matrix.columnIndices[offset]] = matrix.values[offset]
                }
            }
            return result
        }
        let c = try matrix(s, [[1, 0, 0], [0, 2, -1], [0, -1, 2]])
        let g = try matrix(s, [[101, -100, 0], [-100, 101, 0], [0, 0, 1]])
        let forcing = try matrix(s, [[1], [1], [1]])
        let reconstruction = try matrix(s, [[1, 0, 0], [0, 1, 0], [0, 0, 1], [0.25, 0.5, 0.25]])
        let dc = try sparse(matrix(s, [[1], [1], [1], [1]]))
        let reduced = try NativeSTAConservativeSparseGraph.Reduced(dynamicRows: [0, 1, 2],
            conductance: sparse(g), capacitance: sparse(c), forcing: forcing,
            reconstruction: sparse(reconstruction), dcIncidence: dc, capBlocks: [[0], [1, 2]])
        let transformer = NativeSTAConservativeSparseBasis(numerical: n)
        for candidate in [NativeSTAConservativeSparseBasis.Candidate.identity, .whitening, .localModal] {
            let output = try transformer.transform(reduced, candidate: candidate, maximumSweeps: 8, work: &work)
            #expect(output.dynamicRows == reduced.dynamicRows && output.dcIncidence.values == dc.values)
            let a = try dense(output.a), j = try dense(output.j), t = try dense(output.reconstruction)
            var q = try n.matrix(3, 3)
            // W begins with identity, so the physical reconstruction exposes the exact proposed Q.
            for i in 0..<3 { for k in 0..<3 { q[i, k] = t[i, k] } }
            #expect(q[0, 0].lowerBound == 1 && q[0, 0].upperBound == 1)
            #expect(q[0, 1].upperBound == 0 && q[1, 0].upperBound == 0)
            let qt = try n.transpose(q, work: &work)
            let mass = try n.product(qt, n.product(c, q, work: &work), work: &work)
            try n.positiveDefinite(mass, work: &work)
            let stiffness = try n.product(qt, n.product(g, q, work: &work), work: &work)
            let dynamicsResidual = try n.product(mass, a, work: &work)
            for index in stiffness.values.indices {
                let residual = try dynamicsResidual.values[index].adding(stiffness.values[index])
                #expect(residual.lowerBound <= 0 && residual.upperBound >= 0)
            }
            let sourceResidual = try n.product(mass, j, work: &work)
            let transformedForcing = try n.product(qt, forcing, work: &work)
            for index in sourceResidual.values.indices {
                let residual = try sourceResidual.values[index].adding(transformedForcing.values[index])
                #expect(residual.lowerBound <= 0 && residual.upperBound >= 0)
            }
            let expectedT = try n.product(reconstruction, q, work: &work)
            for index in t.values.indices {
                let difference = try t.values[index].subtracting(expectedT.values[index])
                #expect(difference.lowerBound <= 0 && difference.upperBound >= 0)
            }
            if case .localModal = candidate {
                // G[0,2] is exactly zero; its transformed mode coupling must still be retained.
                #expect(a[0, 2].lowerBound != 0 || a[0, 2].upperBound != 0)
                var f = try n.matrix(3, 3)
                for i in 0..<3 { for k in 0..<3 {
                    f[i, k] = try I(point: i == k ? a[i, k].upperBound : a[i, k].absolute().upperBound)
                } }
                let comparison = try sparse(f)
                let ones = try matrix(s, [[1], [1], [1]])
                let w = try s.approximateSolve(s.negated(comparison, work: &work), ones,
                    maximumIterations: 64, work: &work)
                let fw = try s.product(comparison, w, work: &work)
                for i in 0..<3 { #expect(w[i, 0].lowerBound > 0 && fw[i, 0].upperBound < 0) }
            }
        }
    }

    @Test func malformedLocalPartitionAndCumulativeWorkRemainFatal() throws {
        let s = try helper(); let n = s.numerical; var work: UInt64 = 0
        let identity = try s.fromRows([[0: I(point: 1)], [1: I(point: 1)]], columns: 2, work: &work)
        let missing = NativeSTAConservativeSparseGraph.Reduced(dynamicRows: [0, 1], conductance: identity,
            capacitance: identity, forcing: try matrix(s, [[1], [1]]), reconstruction: identity,
            dcIncidence: try s.fromRows([[0: I(point: 1)], [0: I(point: 1)]], columns: 1, work: &work), capBlocks: [[0]])
        #expect(throws: NativeSTAConservativeCouplingError.invalidPrimitive("sparse basis incomplete partition")) {
            _ = try NativeSTAConservativeSparseBasis(numerical: n).transform(missing, candidate: .localModal,
                maximumSweeps: 8, work: &work)
        }
        let valid = NativeSTAConservativeSparseGraph.Reduced(dynamicRows: [0, 1], conductance: identity,
            capacitance: identity, forcing: try matrix(s, [[1], [1]]), reconstruction: identity,
            dcIncidence: missing.dcIncidence, capBlocks: [[0], [1]])
        let limited = try helper(workLimit: 1)
        work = 1
        #expect(throws: STAPathAnalysisError.self) {
            _ = try NativeSTAConservativeSparseBasis(numerical: limited.numerical).transform(valid,
                candidate: .identity, maximumSweeps: 8, work: &work)
        }
        #expect(work == 1)
    }

    @Test func inaccurateOneIterationCandidateNeedsAndReceivesAnOutwardResidualCorrection() throws {
        let s = try helper(); var work: UInt64 = 0
        let a = try generator(s, work: &work), rhs = try matrix(s, [[-2], [-4]])
        let candidate = try s.approximateSolve(a, rhs, maximumIterations: 1, work: &work)
        #expect(abs(candidate[0, 0].lowerBound - 1) + abs(candidate[1, 0].lowerBound - 2) > 1e-5)
        let solved = try s.verifiedSolve(a, rhs, comparison: a, weight: matrix(s, [[1], [1]]), maximumIterations: 1, work: &work)
        #expect(solved[0, 0].lowerBound <= 1 && solved[0, 0].upperBound >= 1)
        #expect(solved[1, 0].lowerBound <= 2 && solved[1, 0].upperBound >= 2)
    }

    @Test func optimisticComparisonUnstableWeightAndPositiveOperatorNeverGrantProof() throws {
        let s = try helper(); var work: UInt64 = 0
        let a = try generator(s, work: &work), rhs = try matrix(s, [[1], [1]])
        let optimistic = try s.fromRows([[0: I(point: -4)], [1: I(point: -3)]], columns: 2, work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            _ = try s.verifiedSolve(a, rhs, comparison: optimistic, weight: matrix(s, [[1], [1]]), maximumIterations: 4, work: &work)
        }
        for weight in [[[100.0], [1.0]], [[0.0], [1.0]]] {
            #expect(throws: NativeSTAConservativeCouplingError.self) {
                _ = try s.verifiedSolve(a, rhs, comparison: a, weight: matrix(s, weight), maximumIterations: 4, work: &work)
            }
        }
        let positive = try s.negated(a, work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            _ = try s.verifiedSolve(positive, rhs, comparison: a, weight: matrix(s, [[1], [1]]), maximumIterations: 4, work: &work)
        }
    }

    private final class CheckpointResources: LibertySourceResourceAccounting {
        enum Failure: Error, Equatable { case cancelled, unexpectedWork, unexpectedStorage }
        private let checks = Mutex(0)
        private let refuseAt: Int?
        init(refuseAt: Int? = nil) { self.refuseAt = refuseAt }
        var checkCount: Int { checks.withLock { $0 } }
        func check() throws {
            let count = checks.withLock { value in value += 1; return value }
            if count == refuseAt { throw Failure.cancelled }
        }
        func chargeWork(_ amount: UInt64) throws { throw Failure.unexpectedWork }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            throw Failure.unexpectedStorage
        }
    }

    @Test func boundedCandidatePassesKeepWorkTotalsAndExactCandidateBits() throws {
        let base = try helper(); var setupWork: UInt64 = 0
        let a = try generator(base, work: &setupWork), rhs = try matrix(base, [[-2], [-4]])
        var plainWork: UInt64 = 0
        let plain = try base.approximateSolve(a, rhs, maximumIterations: 1, work: &plainWork)
        let resources = CheckpointResources()
        let limits = try STAExecutionLimits(maximumPathStates: 1_000_000)
        let checked = S(numerical: .init(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: resources))
        var checkedWork: UInt64 = 0
        let observed = try checked.approximateSolve(a, rhs, maximumIterations: 1, work: &checkedWork)
        let expectedWork = UInt64(3 * a.values.count + 13 * a.rows)
        #expect(plainWork == expectedWork && checkedWork == expectedWork)
        #expect(resources.checkCount == 26)
        for i in plain.values.indices {
            #expect(plain.values[i].lowerBound.bitPattern == observed.values[i].lowerBound.bitPattern)
            #expect(plain.values[i].upperBound.bitPattern == observed.values[i].upperBound.bitPattern)
        }
        // A scalar diagonal system takes the early-s branch, with its own unchanged charge.
        let diagonal = try base.fromRows([[0: I(point: 2)]], columns: 1, work: &setupWork)
        var earlyWork: UInt64 = 0
        let early = try base.approximateSolve(diagonal, matrix(base, [[4]]), maximumIterations: 2, work: &earlyWork)
        #expect(earlyWork == UInt64(2 * diagonal.values.count + 10 * diagonal.rows))
        #expect(early[0, 0].lowerBound == 2 && early[0, 0].upperBound == 2)
    }

    @Test func wholeOperationBudgetAndSourceCancellationRefuseAtBoundaries() throws {
        let base = try helper(); var setupWork: UInt64 = 0
        let a = try generator(base, work: &setupWork), rhs = try matrix(base, [[-2], [-4]])
        let expectedWork = UInt64(3 * a.values.count + 13 * a.rows)
        let limited = try helper(workLimit: expectedWork - 1)
        var limitedWork: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) {
            _ = try limited.approximateSolve(a, rhs, maximumIterations: 1, work: &limitedWork)
        }
        // The last whole vector pass is rejected before partially charging any of its elements.
        #expect(limitedWork == expectedWork - UInt64(a.rows))
        for (refuseAt, admittedWork) in [(1, UInt64(0)), (2, UInt64(6)), (3, UInt64(6)),
                                         (4, UInt64(8)), (11, UInt64(14)), (12, UInt64(20))] {
            let resources = CheckpointResources(refuseAt: refuseAt)
            let limits = try STAExecutionLimits(maximumPathStates: 1_000_000)
            let controlled = S(numerical: .init(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: resources))
            var work: UInt64 = 0
            #expect(throws: CheckpointResources.Failure.cancelled) {
                _ = try controlled.approximateSolve(a, rhs, maximumIterations: 1, work: &work)
            }
            #expect(work == admittedWork && resources.checkCount == refuseAt)
        }
    }

    @Test func zeroStartGaussSeidelCertifiesAStableComparisonDespiteNegativeBiCGProposal() throws {
        let s = try helper(); var work: UInt64 = 0
        let f = try s.fromRows([[0: I(point: -1), 1: I(point: 4)],
                               [0: I(point: 0.1), 1: I(point: -1)]], columns: 2, work: &work)
        let ones = try matrix(s, [[1], [1]])
        let bicg = try s.approximateSolve(s.negated(f, work: &work), ones, maximumIterations: 1, work: &work)
        #expect(bicg[0, 0].upperBound < 0 && bicg[1, 0].upperBound < 0)
        let weight = try s.comparisonWeightCandidate(f, maximumIterations: 64, work: &work)
        let fw = try s.product(f, weight, work: &work)
        for row in 0..<2 { #expect(weight[row, 0].lowerBound > 0 && fw[row, 0].upperBound < 0) }
        #expect(abs(weight[0, 0].lowerBound - 25.0 / 3) < 1e-6)
        #expect(abs(weight[1, 0].lowerBound - 11.0 / 6) < 1e-6)
        let repeated = try s.comparisonWeightCandidate(f, maximumIterations: 64, work: &work)
        #expect(repeated.values == weight.values)
    }

    @Test func finiteGaussSeidelCandidateForUnstableComparisonGrantsNoCertificate() throws {
        let s = try helper(); var setupWork: UInt64 = 0
        let f = try s.fromRows([[0: I(point: -1), 1: I(point: 2)],
                               [0: I(point: 2), 1: I(point: -1)]], columns: 2, work: &setupWork)
        var work: UInt64 = 0
        let weight = try s.comparisonWeightCandidate(f, maximumIterations: 2, work: &work)
        #expect(weight[0, 0].lowerBound == 7 && weight[1, 0].lowerBound == 15)
        #expect(work == UInt64(5 * (f.values.count + f.rows) + f.rows))
        let fw = try s.product(f, weight, work: &setupWork)
        #expect(fw[0, 0].lowerBound > 0)
        let limited = try helper(workLimit: work - 1)
        var limitedWork: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) {
            _ = try limited.comparisonWeightCandidate(f, maximumIterations: 2, work: &limitedWork)
        }
        #expect(limitedWork == work - UInt64(f.rows))
        let resources = CheckpointResources(refuseAt: 2)
        let limits = try STAExecutionLimits(maximumPathStates: 1_000_000)
        let controlled = S(numerical: .init(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: resources))
        var controlledWork: UInt64 = 0
        #expect(throws: CheckpointResources.Failure.cancelled) {
            _ = try controlled.comparisonWeightCandidate(f, maximumIterations: 2, work: &controlledWork)
        }
        #expect(controlledWork == UInt64(f.values.count + f.rows) && resources.checkCount == 2)
    }

    @Test func gaussSeidelRejectsUnsupportedSignsAndNonfiniteProposalsExplicitly() throws {
        let s = try helper(); var work: UInt64 = 0
        let positiveDiagonal = try s.fromRows([[0: I(point: 1)]], columns: 1, work: &work)
        #expect(throws: NativeSTAConservativeCandidateNotCertified(reason: "comparison diagonal is not negative")) {
            _ = try s.comparisonWeightCandidate(positiveDiagonal, maximumIterations: 1, work: &work)
        }
        let nonMetzler = try s.fromRows([[0: I(point: -1), 1: I(point: -1)], [1: I(point: -1)]], columns: 2, work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.invalidCertificate("comparison weight requires Metzler operator")) {
            _ = try s.comparisonWeightCandidate(nonMetzler, maximumIterations: 1, work: &work)
        }
        let overflow = try s.fromRows([[0: I(point: -Double.leastNonzeroMagnitude)]], columns: 1, work: &work)
        #expect(throws: NativeSTAConservativeCandidateNotCertified(reason: "nonfinite or nonpositive GS comparison proposal")) {
            _ = try s.comparisonWeightCandidate(overflow, maximumIterations: 1, work: &work)
        }
    }

    @Test func numericalCandidateRefusalDoesNotReclassifyStructuralFailures() throws {
        let s = try helper(); var work: UInt64 = 0
        let zeroDiagonal = try s.fromRows([[:]], columns: 1, work: &work)
        let rhs = try matrix(s, [[1]])
        #expect(throws: NativeSTAConservativeCandidateNotCertified(reason: "zero candidate preconditioner")) {
            _ = try s.approximateSolve(zeroDiagonal, rhs, maximumIterations: 4, work: &work)
        }
        #expect(throws: NativeSTAConservativeCouplingError.invalidCertificate("sparse candidate shape/iterations")) {
            _ = try s.approximateSolve(zeroDiagonal, rhs, maximumIterations: 0, work: &work)
        }
    }

    @Test func nativeWorkAndStorageCapsRemainSharedAndCannotRestart() throws {
        let s = try helper(workLimit: 50); var work: UInt64 = 0
        let a = try generator(s, work: &work)
        let rhs = try matrix(s, [[1], [1]])
        #expect(throws: STAPathAnalysisError.self) { _ = try s.approximateSolve(a, rhs, maximumIterations: 100, work: &work) }
        let tiny = try helper(slots: 1)
        #expect(throws: STAPathAnalysisError.self) { _ = try tiny.fromRows([[0: I(point: 1)]], columns: 1, work: &work) }
    }

    private struct RefusingSourceResources: LibertySourceResourceAccounting {
        enum Failure: Error, Equatable { case originalOwnerRefusal }
        func check() throws { throw Failure.originalOwnerRefusal }
        func chargeWork(_ amount: UInt64) throws { throw Failure.originalOwnerRefusal }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            throw Failure.originalOwnerRefusal
        }
    }

    @Test func originalSourceOwnerRefusalPropagatesWithoutAReplacementCounter() throws {
        let limits = try STAExecutionLimits()
        let s = S(numerical: .init(limits: limits, budget: .init(maximum: limits.maximumPathStates),
                                  resources: RefusingSourceResources()))
        var work: UInt64 = 7
        #expect(throws: RefusingSourceResources.Failure.originalOwnerRefusal) {
            _ = try s.fromRows([[0: I(point: 1)]], columns: 1, work: &work)
        }
        #expect(work == 7)
    }

    @Test func cancellationRemainsCancellation() async throws {
        let task = Task {
            let s = try helper(); var work: UInt64 = 0
            withUnsafeCurrentTask { $0?.cancel() }
            return try generator(s, work: &work)
        }
        do { _ = try await task.value; Issue.record("Cancelled sparse construction succeeded") }
        catch is CancellationError { }
    }
}

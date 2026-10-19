import Testing
@testable import TimingCore
@testable import STAEngine

@Suite("Sparse comparison failure diagnosis")
struct STAConservativeWeightDiagnosticTests {
    private func diagnose(_ coefficients: [[Double]], _ weights: [Double]) throws -> NativeSTAConservativeWeightDiagnostic {
        let limits = try STAExecutionLimits(maximumPathStates: 10_000)
        let n = NativeSTAConservativeNumerics(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: nil)
        let s = NativeSTAConservativeSparseNumerics(numerical: n)
        var work: UInt64 = 0
        var rows = Array(repeating: [Int: TimingNumericInterval](), count: coefficients.count)
        var w = try n.matrix(weights.count, 1)
        for i in coefficients.indices {
            for j in coefficients[i].indices { rows[i][j] = try .init(point: coefficients[i][j]) }
            w[i, 0] = try .init(point: weights[i])
        }
        return try .evaluate(comparison: s.fromRows(rows, columns: weights.count, work: &work), candidate: w, numerical: n, work: &work)
    }

    @Test("negative exact solve proves an unstable Metzler comparison")
    func unstableComparison() throws {
        let result = try diagnose([[-1, 2], [2, -1]], [-1, -1])
        #expect(result.negativeWeights == 2)
        #expect(result.trueResidualMaximumAbsoluteUpper < 1e-12)
        #expect(result.comparisonNonHurwitzProved)
        #expect(try #require(result.minimumCertifiedSupportedLower) > 0)
    }

    @Test("bad negative candidate cannot falsely condemn a stable comparison")
    func inaccurateCandidate() throws {
        let result = try diagnose([[-2, 1], [1, -2]], [-1, -1])
        #expect(result.negativeWeights == 2)
        #expect(result.trueResidualMaximumAbsoluteUpper >= 2)
        #expect(!result.comparisonNonHurwitzProved)
    }

    @Test("zero support is certified by signs even for reducible comparisons")
    func reducibleWitness() throws {
        let result = try diagnose([[-1, 0], [0, 1]], [1, -1])
        #expect(result.negativeWeights == 1)
        #expect(result.comparisonNonHurwitzProved)
    }

    @Test("non-Metzler data cannot authorize the Perron witness")
    func invalidSigns() throws {
        let result = try diagnose([[1, -0.5], [0, 1]], [-1, -1])
        #expect(!result.comparisonIsMetzler)
        #expect(!result.comparisonNonHurwitzProved)
    }

    @Test("a reciprocal principal witness is independent of an inaccurate positive weight")
    func reciprocalPrincipalWitness() throws {
        let result = try diagnose([[-1, 2, 0], [2, -1, 0], [0.5, 0, -3]], [1, 1, 1])
        #expect(result.negativeWeights == 0)
        #expect(result.minimumCertifiedSupportedLower == nil)
        #expect(result.comparisonNonHurwitzProved)
        let witness = try #require(result.principalNonHurwitzWitness)
        guard case .reciprocalPair(let first, let second, let fii, let fjj, let fij, let fji, let determinant) = witness else {
            Issue.record("Expected a reciprocal principal witness"); return
        }
        #expect(first == 0 && second == 1)
        #expect(fii == -1 && fjj == -1 && fij == 2 && fji == 2)
        #expect(determinant < 0)
        #expect(determinant >= -3)
        #expect(witness.description.contains("transformedCoordinateRows=0,1"))
        #expect(!witness.description.contains("endpoint"))
    }

    @Test("nonnegative or absent diagonal proves a principal spectral obstruction")
    func diagonalPrincipalWitness() throws {
        let positive = try diagnose([[-1, 1], [0, 0.25]], [1, 1])
        #expect(positive.principalNonHurwitzWitness == .diagonal(row: 1, coefficient: 0.25))
        #expect(positive.comparisonNonHurwitzProved)
        let absent = try diagnose([[-1, 1], [0, 0]], [1, 1])
        #expect(absent.principalNonHurwitzWitness == .diagonal(row: 1, coefficient: 0))
        #expect(absent.comparisonNonHurwitzProved)
    }

    @Test("unproved larger cycles and zero determinant do not become principal certificates")
    func noPrincipalWitness() throws {
        let cycle = try diagnose([[-1, 2, 0], [0, -1, 2], [2, 0, -1]], [1, 1, 1])
        #expect(cycle.principalNonHurwitzWitness == nil)
        #expect(!cycle.comparisonNonHurwitzProved)
        let boundary = try diagnose([[-1, 1], [1, -1]], [1, 1])
        #expect(boundary.principalNonHurwitzWitness == nil)
        #expect(!boundary.comparisonNonHurwitzProved)
        let stable = try diagnose([[-2, 1], [1, -2]], [-1, -1])
        #expect(stable.principalNonHurwitzWitness == nil)
        #expect(!stable.comparisonNonHurwitzProved)
    }

    @Test("mismatched shape and nonpoint coefficients fail before principal evidence is used")
    func malformedPrincipalInput() throws {
        typealias I = TimingNumericInterval
        let limits = try STAExecutionLimits(maximumPathStates: 10_000)
        let n = NativeSTAConservativeNumerics(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: nil)
        let solver = NativeSTAConservativeSparseNumerics(numerical: n)
        let minusOne = try I(point: -1), two = try I(point: 2)
        var work: UInt64 = 0
        let nonsquare = try solver.fromRows([[0: minusOne, 1: two], [0: two, 1: minusOne]], columns: 3, work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try NativeSTAConservativeWeightDiagnostic.principalWitness(comparison: nonsquare, numerical: n, work: &work)
        }
        let nonpoint = try solver.fromRows([[0: I(lowerBound: -2, upperBound: -1)], [1: minusOne]], columns: 2, work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try NativeSTAConservativeWeightDiagnostic.principalWitness(comparison: nonpoint, numerical: n, work: &work)
        }
        let valid = try solver.fromRows([[0: minusOne], [1: minusOne]], columns: 2, work: &work)
        let invalidWeight = NativeSTAConservativeNumerics.Matrix(rows: 2, columns: 1, values: [])
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try NativeSTAConservativeWeightDiagnostic.evaluate(comparison: valid, candidate: invalidWeight, numerical: n, work: &work)
        }
    }

    @Test("principal scans preserve cumulative work failures")
    func principalWorkLimit() throws {
        let limits = try STAExecutionLimits(maximumPathStates: 100, maximumPathWorkUnits: 1)
        let n = NativeSTAConservativeNumerics(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: nil)
        let constructionLimits = try STAExecutionLimits(maximumPathStates: 100)
        let construction = NativeSTAConservativeNumerics(limits: constructionLimits,
            budget: .init(maximum: constructionLimits.maximumPathStates), resources: nil)
        let minusOne = try TimingNumericInterval(point: -1), two = try TimingNumericInterval(point: 2)
        var constructionWork: UInt64 = 0
        let f = try NativeSTAConservativeSparseNumerics(numerical: construction)
            .fromRows([[0: minusOne, 1: two], [0: two, 1: minusOne]], columns: 2, work: &constructionWork)
        var work: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) {
            try NativeSTAConservativeWeightDiagnostic.principalWitness(comparison: f, numerical: n, work: &work)
        }
    }

}

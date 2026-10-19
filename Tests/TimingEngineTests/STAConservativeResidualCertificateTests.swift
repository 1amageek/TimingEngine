import Testing
import Synchronization
import TimingCore
@testable import STAEngine

@Suite("Source-local continuous residual certificates", .timeLimit(.minutes(1)))
struct STAConservativeResidualCertificateTests {
    typealias C = NativeSTAConservativeResidualCertificate
    typealias Q = NativeSTAConservativeResidualNorm
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias I = TimingNumericInterval
    typealias G = NativeSTAConservativeSparseGraph

    private func context(workLimit: UInt64 = 100_000_000, slots: Int = 1_000_000,
                         resources: (any LibertySourceResourceAccounting)? = nil) throws -> N {
        let limits = try STAExecutionLimits(maximumPathStates: slots, maximumPathWorkUnits: workLimit)
        return N(limits: limits, budget: .init(maximum: slots), resources: resources)
    }
    private func matrix(_ n: N, _ rows: [[Double]]) throws -> N.Matrix {
        var result = try n.matrix(rows.count, rows.first?.count ?? 0)
        for i in rows.indices { for j in rows[i].indices { result[i, j] = try I(point: rows[i][j]) } }
        return result
    }
    private func pole(_ n: N, work: inout UInt64) throws -> G.Reduced {
        let s = S(numerical: n)
        let identity = try s.fromRows([[0: I(point: 1)]], columns: 1, work: &work)
        return G.Reduced(dynamicRows: [0], conductance: identity, capacitance: identity,
            forcing: try matrix(n, [[1]]), reconstruction: identity, dcIncidence: identity, capBlocks: [[0]])
    }

    @Test func deliberatelyInaccurateNativeCandidatesStillEncloseEveryIntervalVertex() throws {
        let n = try context(), s = S(numerical: n); var work: UInt64 = 0
        let g = try s.fromRows([[0: I(point: 2), 1: I(point: -1)],
                               [0: I(point: -1), 1: I(point: 2)]], columns: 2, work: &work)
        let norm = try Q(numerical: n, conductance: g, weight: matrix(n, [[1], [1]]), work: &work)
        var rhs = try matrix(n, [[1, 0], [-0.5, 0]])
        rhs[0, 0] = try I(1 ... 1.01); rhs[1, 0] = try I(-0.5 ... -0.49)
        for candidate in [[[0.0, 0.0], [0.0, 0.0]], [[1.0, 0.0], [-1.0, 0.0]], [[0.5, 0.0], [0.01, 0.0]]] {
            let upper = try norm.upper(rhs, candidate: matrix(n, candidate), work: &work)
            for x in [1.0, 1.01] { for y in [-0.5, -0.49] {
                let exactSquared = (2 * x * x + 2 * x * y + 2 * y * y) / 3
                #expect(upper[0, 0].lowerBound == upper[0, 0].upperBound)
                #expect(upper[0, 0].upperBound * upper[0, 0].upperBound >= exactSquared)
            } }
            #expect(try upper[0, 1] == I(point: 0))
        }
    }

    @Test func weightSignOperatorSignAndPointAuthorityAreChecked() throws {
        let n = try context(), s = S(numerical: n); var work: UInt64 = 0
        let g = try s.fromRows([[0: I(point: 2), 1: I(point: -1)],
                               [0: I(point: -1), 1: I(point: 2)]], columns: 2, work: &work)
        #expect(throws: NativeSTAConservativeCandidateNotCertified.self) {
            _ = try Q(numerical: n, conductance: g, weight: matrix(n, [[-1], [1]]), work: &work)
        }
        let nonM = try s.fromRows([[0: I(point: 1), 1: I(point: -2)],
                                  [0: I(point: -2), 1: I(point: 1)]], columns: 2, work: &work)
        #expect(throws: NativeSTAConservativeCandidateNotCertified.self) {
            _ = try Q(numerical: n, conductance: nonM, weight: matrix(n, [[1], [1]]), work: &work)
        }
        let positiveOffDiagonal = try s.fromRows([[0: I(point: 2), 1: I(point: 1)],
            [0: I(point: 1), 1: I(point: 2)]], columns: 2, work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            _ = try Q(numerical: n, conductance: positiveOffDiagonal, weight: matrix(n, [[1], [1]]), work: &work)
        }
        let norm = try Q(numerical: n, conductance: g, weight: matrix(n, [[1], [1]]), work: &work)
        var notPoint = try matrix(n, [[1], [1]])
        notPoint[0, 0] = try I(0.99 ... 1.01)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            _ = try norm.upper(matrix(n, [[1], [1]]), candidate: notPoint, work: &work)
        }
        let malformed = N.Matrix(rows: 2, columns: 1, values: [])
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            _ = try norm.upper(matrix(n, [[1], [1]]), candidate: malformed, work: &work)
        }
    }

    @Test func verifiedRootsIncludeTheSubnormalFloorAndRejectNegativeSquares() throws {
        let n = try context(); var work: UInt64 = 0
        let reduced = try pole(n, work: &work)
        let norm = try Q(numerical: n, conductance: reduced.conductance,
                         weight: matrix(n, [[1]]), work: &work)
        #expect(try norm.squareRootUpper(0, work: &work) == 0)
        for value in [Double.leastNonzeroMagnitude, Double.leastNormalMagnitude, 0.1, 2.0, 1e200] {
            let root = try norm.squareRootUpper(value, work: &work)
            #expect(root.isFinite && root > 0)
            #expect(try I(point: root).multiplied(by: I(point: root)).lowerBound >= value)
        }
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            _ = try norm.squareRootUpper(-1, work: &work)
        }
    }

    @Test func cubicResidualAndVariationMatchAnIndependentLinearPolynomial() throws {
        let n = try context(); var work: UInt64 = 0
        let reduced = try pole(n, work: &work), checker = C(numerical: n)
        let coefficients = try [1.0, 2.0 / 3, 1.0 / 3, 0.0].map { try matrix(n, [[$0]]) }
        let segment = NativeSTAConservativeResidualCandidate.Segment(start: 0, end: 1, bernstein: coefficients)
        try checker.validate(segment, start: 0, end: 1, previous: coefficients[0], work: &work)
        var scratch = try n.matrix(1, 1)
        for component in 0..<4 {
            try checker.fillResidual(reduced, segment: segment, component: component, into: &scratch, work: &work)
            // C=G=1 and p(t)=1-t give residual -t, r(0)=0 and Bernstein variation -k/3.
            let reference = -Double(component) / 3
            #expect(scratch[0, 0].lowerBound <= reference && scratch[0, 0].upperBound >= reference)
        }
        var discontinuous = coefficients
        discontinuous[0] = try matrix(n, [[0.9]])
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try checker.validate(.init(start: 0, end: 1, bernstein: discontinuous),
                start: 0, end: 1, previous: coefficients[0], work: &work)
        }
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try checker.validate(segment, start: 0.1, end: 1, previous: coefficients[0], work: &work)
        }
    }

    @Test func completeOnePoleTraceBoundsTheAnalyticalInfiniteImpulseIntegral() throws {
        #if os(macOS)
        if #available(macOS 27, *) {
            let n = try context(slots: 16_000_000); var work: UInt64 = 0
            let reduced = try pole(n, work: &work), checker = C(numerical: n)
            let facts = try checker.prepare(reduced, receiverRows: [0],
                times: [0, 0.0625, 0.125, 0.25, 0.5, 1, 2, 4, 8, 16], work: &work)
            #expect(facts.sourceCount == 1 && facts.receiverRows == [0] && facts.segments.count == 9)
            #expect(facts.direct[0, 0].lowerBound <= 0 && facts.direct[0, 0].upperBound >= 0)
            for column in 0..<2 {
                var bound = 0.0
                for segment in facts.segments {
                    let dt = segment.end - segment.start
                    bound += dt / 4 * (try segment.bernstein.reduce(0.0) { try $0 + $1[0, column].absolute().upperBound })
                }
                for error in [facts.errors.initial, facts.errors.solve, facts.errors.interpolation, facts.errors.tail] {
                    #expect(error[0, column].lowerBound >= 0)
                    bound += error[0, column].upperBound
                }
                // g=-exp(-t), h=exp(-t), so each exact infinite absolute integral equals one.
                #expect(bound >= 1 && bound.isFinite)
            }
            #expect(facts.errors.initial[0, 0].upperBound < 1e-10)
        }
        #endif
    }

    @Test func missingPhysicalCapacitancePartitionCannotReachTheNativeSolver() throws {
        let n = try context(); var work: UInt64 = 0
        let original = try pole(n, work: &work)
        let malformed = G.Reduced(dynamicRows: original.dynamicRows, conductance: original.conductance,
            capacitance: original.capacitance, forcing: original.forcing, reconstruction: original.reconstruction,
            dcIncidence: original.dcIncidence, capBlocks: [])
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            _ = try C(numerical: n).prepare(malformed, receiverRows: [0], times: [0, 1], work: &work)
        }
    }

    private struct RefusingResources: LibertySourceResourceAccounting {
        enum Failure: Error, Equatable { case ownerRefusal }
        func check() throws { throw Failure.ownerRefusal }
        func chargeWork(_ amount: UInt64) throws { throw Failure.ownerRefusal }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            throw Failure.ownerRefusal
        }
    }

    @Test func originalWorkStorageAndSourceFailuresPropagateBeforeNativeEntry() throws {
        let ordinary = try context(); var work: UInt64 = 0
        let reduced = try pole(ordinary, work: &work)
        for n in [try context(workLimit: 1), try context(slots: 1)] {
            var localWork: UInt64 = 0
            #expect(throws: STAPathAnalysisError.self) {
                _ = try C(numerical: n).prepare(reduced, receiverRows: [0], times: [0, 1], work: &localWork)
            }
        }
        let refusing = try context(resources: RefusingResources()); var localWork: UInt64 = 0
        #expect(throws: RefusingResources.Failure.ownerRefusal) {
            _ = try C(numerical: refusing).prepare(reduced, receiverRows: [0], times: [0, 1], work: &localWork)
        }
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            _ = try C(numerical: ordinary).prepare(reduced, receiverRows: [0, 0], times: [0, 1], work: &work)
        }
    }

    @Test func cancellationRemainsCancellation() async throws {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            let n = try context(); var work: UInt64 = 0
            _ = try pole(n, work: &work)
        }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled residual fixture construction succeeded") }
        catch is CancellationError { }
    }

    private final class BatchAccountant: LibertySourceResourceAccounting {
        enum Failure: Error, Equatable { case checkpoint, unexpectedAccounting }
        private struct State { var checks = 0; var refuseAt: Int? }
        private let state = Mutex(State())
        var checks: Int { state.withLock { $0.checks } }
        func arm(after count: Int? = nil) -> Int {
            state.withLock { value in
                let current = value.checks
                value.refuseAt = count.map { current + $0 }
                return value.checks
            }
        }
        func check() throws {
            try state.withLock { value in
                value.checks += 1
                if value.checks == value.refuseAt { throw Failure.checkpoint }
            }
        }
        func chargeWork(_ amount: UInt64) throws { throw Failure.unexpectedAccounting }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            throw Failure.unexpectedAccounting
        }
    }

    @Test func boundedNormPassKeepsExactWorkAndZeroBits() throws {
        let accountant = BatchAccountant(), n = try context(resources: accountant)
        var work: UInt64 = 0
        let g = try S(numerical: n).fromRows([[0: I(point: 1)], [1: I(point: 1)]], columns: 2, work: &work)
        let norm = try Q(numerical: n, conductance: g, weight: matrix(n, [[1], [1]]), work: &work)
        let zeros = try matrix(n, [[0, 0], [0, 0]])
        let before = work, checks = accountant.arm()
        let result = try norm.upper(zeros, candidate: zeros, work: &work)
        // m*(nnzG+2*n)=2*(2+4), and zero columns spend no root work.
        #expect(work - before == 12 && accountant.checks - checks == 7)
        #expect(result.values.allSatisfy { $0.lowerBound.bitPattern == 0 && $0.upperBound.bitPattern == 0 })
    }

    @Test func pointPassCapacityRefusesBeforeItsFirstMutationOrResultAllocation() throws {
        let fixture = try context(); var fixtureWork: UInt64 = 0
        let g = try S(numerical: fixture).fromRows([[0: I(point: 1)], [1: I(point: 1)]], columns: 2, work: &fixtureWork)
        let weight = try matrix(fixture, [[1], [1]]), zeros = try matrix(fixture, [[0, 0], [0, 0]])
        let accountant = BatchAccountant(), n = try context(workLimit: 9, slots: 10, resources: accountant)
        var work: UInt64 = 0
        let norm = try Q(numerical: n, conductance: g, weight: weight, work: &work)
        #expect(work == 6)
        let checks = accountant.arm()
        #expect(throws: STAPathAnalysisError.self) { _ = try norm.upper(zeros, candidate: zeros, work: &work) }
        #expect(work == 6 && accountant.checks - checks == 1)
        // Only the two barrier-image slots were reserved; no result was allocated.
        try n.slots(8)
    }

    @Test func pointAndKnownZeroColumnPostchecksPropagateTheOriginalOwnerError() throws {
        let fixture = try context(); var fixtureWork: UInt64 = 0
        let g = try S(numerical: fixture).fromRows([[0: I(point: 1)], [1: I(point: 1)]], columns: 2, work: &fixtureWork)
        let weight = try matrix(fixture, [[1], [1]]), zeros = try matrix(fixture, [[0], [0]])
        for refusal in [2, 4, 5] {
            let accountant = BatchAccountant(), n = try context(resources: accountant)
            var work: UInt64 = 0
            let norm = try Q(numerical: n, conductance: g, weight: weight, work: &work)
            let before = work, checks = accountant.arm(after: refusal)
            #expect(throws: BatchAccountant.Failure.checkpoint) {
                _ = try norm.upper(zeros, candidate: zeros, work: &work)
            }
            // Point postcheck, known-zero column postcheck, then final return postcheck.
            #expect(accountant.checks - checks == refusal)
            #expect(work - before == (refusal == 2 ? 2 : 6))
        }
    }

    @Test func normColumnCapacityIsChargedBeforeTheFirstRow() throws {
        let fixture = try context(); var fixtureWork: UInt64 = 0
        let g = try S(numerical: fixture).fromRows([[0: I(point: 1)], [1: I(point: 1)]], columns: 2, work: &fixtureWork)
        let weight = try matrix(fixture, [[1], [1]]), zeros = try matrix(fixture, [[0], [0]])
        let accountant = BatchAccountant(), n = try context(workLimit: 11, slots: 10, resources: accountant)
        var work: UInt64 = 0
        let norm = try Q(numerical: n, conductance: g, weight: weight, work: &work)
        let checks = accountant.arm()
        #expect(throws: STAPathAnalysisError.self) { _ = try norm.upper(zeros, candidate: zeros, work: &work) }
        // Barrier work six plus the two-element point pass; the four-unit column was refused whole.
        #expect(work == 8 && accountant.checks - checks == 3)
        try n.slots(7)
    }

    @Test func coefficientPassesKeepExactWorkAndRefuseAtBothPostBoundaries() throws {
        let fixture = try context(), previous = try matrix(fixture, [[0, 0]])
        let segment = NativeSTAConservativeResidualCandidate.Segment(start: 0, end: 1,
            bernstein: [previous, previous, previous, previous])
        let refusals: [Int?] = [nil, 2, 10]
        for refusal in refusals {
            let accountant = BatchAccountant(), n = try context(resources: accountant)
            var work: UInt64 = 0
            let checks = accountant.arm(after: refusal)
            if let refusal {
                #expect(throws: BatchAccountant.Failure.checkpoint) {
                    try C(numerical: n).validate(segment, start: 0, end: 1, previous: previous, work: &work)
                }
                #expect(accountant.checks - checks == refusal)
                #expect(work == (refusal == 2 ? 2 : 10))
            } else {
                try C(numerical: n).validate(segment, start: 0, end: 1, previous: previous, work: &work)
                #expect(work == 10 && accountant.checks - checks == 10)
            }
        }
        let small = try context(workLimit: 1); var work: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) {
            try C(numerical: small).validate(segment, start: 0, end: 1, previous: previous, work: &work)
        }
        #expect(work == 0)
    }

    @Test func invalidPointInsideAPreadmittedPassKeepsItsTypedFailure() throws {
        let fixture = try context(), previous = try matrix(fixture, [[0, 0]])
        var invalid = previous
        invalid[0, 0] = try I(0...1)
        let segment = NativeSTAConservativeResidualCandidate.Segment(start: 0, end: 1,
            bernstein: [invalid, previous, previous, previous])
        let accountant = BatchAccountant(), n = try context(resources: accountant)
        var work: UInt64 = 0
        let checks = accountant.arm(after: 2)
        #expect(throws: NativeSTAConservativeCouplingError.invalidPrimitive("residual candidate coefficient is not point data")) {
            try C(numerical: n).validate(segment, start: 0, end: 1, previous: previous, work: &work)
        }
        #expect(work == 2 && accountant.checks - checks == 1)
    }
}

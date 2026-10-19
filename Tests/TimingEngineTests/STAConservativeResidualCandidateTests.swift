import Foundation
import Testing
import TimingCore
@testable import STAEngine

@Suite("Native residual point candidates and lease accounting", .timeLimit(.minutes(1)))
struct STAConservativeResidualCandidateTests {
    typealias N = NativeSTAConservativeNumerics
    typealias S = NativeSTAConservativeSparseNumerics
    typealias G = NativeSTAConservativeSparseGraph
    typealias C = NativeSTAConservativeResidualCandidate
    typealias A = NativeSTAConservativeNativeAllocation
    typealias I = TimingNumericInterval

    private func context(workLimit: UInt64 = 1_000_000_000_000_000, slots: Int = 1_000_000,
                         resources: (any LibertySourceResourceAccounting)? = nil) throws -> N {
        N(limits: try .init(maximumPathStates: slots, maximumPathWorkUnits: workLimit),
          budget: .init(maximum: slots), resources: resources)
    }
    private func matrix(_ n: N, _ data: [[Double]]) throws -> N.Matrix {
        var result = try n.matrix(data.count, data.first?.count ?? 0)
        for row in data.indices { for column in data[row].indices { result[row, column] = try I(point: data[row][column]) } }
        return result
    }
    private func pole(_ n: N, work: inout UInt64) throws -> G.Reduced {
        let s = S(numerical: n)
        return G.Reduced(dynamicRows: [0],
            conductance: try s.fromRows([[0: I(point: 4)]], columns: 1, work: &work),
            capacitance: try s.fromRows([[0: I(point: 2)]], columns: 1, work: &work),
            forcing: try matrix(n, [[1]]),
            reconstruction: try s.fromRows([[0: I(point: 1)]], columns: 1, work: &work),
            dcIncidence: try s.fromRows([[0: I(point: 1)]], columns: 1, work: &work), capBlocks: [[0]])
    }
    private func policy(_ n: N, failAfter: Int? = nil) -> A.Policy {
        // This explicit test policy exercises the same allocator route; production keeps its request-owned quota.
        A.Policy(quotaBytes: n.limits.maximumPathStates * 4,
                 recordCapacity: n.limits.maximumPathStates / 64, failAfterAllocations: failAfter)
    }

    @Test func nativeDimensionsRejectOverflowAndNegativeColumnsBeforeFactorConstruction() throws {
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try NativeSTAConservativeNativeFactor.validateDimensions(rows: Int.max, columns: Int.max)
        }
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try NativeSTAConservativeNativeFactor.validateDimensions(rows: 1, columns: -1)
        }
    }

    @Test func defaultProductionOnePoleUsesNativeSolveAndAlexanderHermitePoints() throws {
        let n = try context(slots: 16_000_000); var work: UInt64 = 0
        let reduced = try pole(n, work: &work), initial = try matrix(n, [[1, -2]])
        var solution = try matrix(n, [[0]])
        var observed: [[Double]] = []
        try C.withSession(reduced: reduced, numerical: n, work: &work) { session, work in
            try session.solveG(matrix(n, [[2]]), into: &solution, work: &work)
            #expect(abs(solution[0, 0].lowerBound - 0.5) < 1e-14)
            try session.stream(initial: initial, times: [0, 0.01, 0.02], work: &work) { segment, _ in
                #expect(segment.bernstein.count == 4)
                observed.append(segment.bernstein.map { $0[0, 0].lowerBound })
                for coefficient in segment.bernstein {
                    for value in coefficient.values { #expect(value.lowerBound == value.upperBound && value.lowerBound.isFinite) }
                    #expect(abs(coefficient[0, 1].lowerBound + 2 * coefficient[0, 0].lowerBound) < 1e-13)
                }
            }
        }
        #expect(observed.count == 2 && observed[0][0] == 1 && observed[1][0] == observed[0][3])
        let gamma = 0.435866521508459, z = 0.02
        let a21 = (1 - gamma) / 2, a31 = -1.5 * gamma * gamma + 4 * gamma - 0.25
        let a32 = 1.5 * gamma * gamma - 5 * gamma + 1.25, denominator = 1 + z * gamma
        let y1 = 1 / denominator, y2 = (1 - z * a21 * y1) / denominator
        let expected = (1 - z * (a31 * y1 + a32 * y2)) / denominator
        #expect(abs(observed[0][3] - expected) < 1e-14)
        #expect(abs(observed[0][1] - (1 - 0.02 / 3)) < 1e-14)
        #expect(abs(observed[0][2] - expected * (1 + 0.02 / 3)) < 1e-14)
        #expect(abs(observed[1][3] - exp(-0.04)) < 1e-7)
    }

    @Test func coupledPhysicalCapacitanceDerivativeKeepsDifferentialMode() throws {
        let n = try context(slots: 16_000_000); let s = S(numerical: n); var work: UInt64 = 0
        let reduced = G.Reduced(dynamicRows: [0, 1],
            conductance: try s.fromRows([[0: I(point: 1)], [1: I(point: 1)]], columns: 2, work: &work),
            capacitance: try s.fromRows([[0: I(point: 2), 1: I(point: -1)], [0: I(point: -1), 1: I(point: 2)]], columns: 2, work: &work),
            forcing: try matrix(n, [[1], [0]]),
            reconstruction: try s.fromRows([[0: I(point: 1)], [1: I(point: 1)]], columns: 2, work: &work),
            dcIncidence: try s.fromRows([[0: I(point: 1)], [0: I(point: 1)]], columns: 1, work: &work), capBlocks: [[0, 1]])
        let initial = try matrix(n, [[1, -1], [-1, 1]])
        var last = 0.0
        try C.withSession(reduced: reduced, numerical: n, work: &work) { session, work in
            try session.stream(initial: initial, times: [0, 0.1, 0.2], work: &work) { segment, _ in
                let b = segment.bernstein
                #expect(abs(b[1][0, 0].lowerBound - b[0][0, 0].lowerBound * (1 - 0.1 / 9)) < 1e-13)
                for point in b { #expect(abs(point[0, 0].lowerBound + point[1, 0].lowerBound) < 1e-13) }
                last = b[3][0, 0].lowerBound
            }
        }
        #expect(abs(last - exp(-0.2 / 3)) < 1e-6)
    }

    #if os(macOS)
    @Test func callerReservedWorkspaceRefusesNativeLeaseBeforeCandidateConstruction() throws {
        let n = try context(slots: 1_000_000); var work: UInt64 = 0
        let reduced = try pole(n, work: &work)
        try n.slots(750_000)
        var entered = false
        #expect(throws: STAPathAnalysisError.capacity(resource: "cumulative native state slots", limit: 1_000_000)) {
            _ = try C.withSession(reduced: reduced, numerical: n, work: &work) { _, _ in entered = true }
        }
        #expect(!entered)
    }

    @Test func quotaBoundaryAndRecordCapacityAreExactAndCleanupAllowsNextLease() throws {
        let n = try context(); var work: UInt64 = 0
        let (_, statistics) = try A.withLease(dimension: 1, nonzeros: 2, numerical: n,
            policy: .init(quotaBytes: 128, recordCapacity: 1), work: &work) { _ in
                let pointer = try A.allocate(112)
                #expect(UInt(bitPattern: pointer) & 15 == 0)
                A.release(pointer)
            }
        #expect(statistics.cumulativeBytes == 128 && statistics.peakLiveBytes == 128 && statistics.outstandingAllocations == 0)
        #expect(throws: STAPathAnalysisError.self) {
            _ = try A.withLease(dimension: 1, nonzeros: 2, numerical: n,
                policy: .init(quotaBytes: 128, recordCapacity: 1), work: &work) { _ in _ = try A.allocate(113) }
        }
        #expect(throws: STAPathAnalysisError.self) {
            _ = try A.withLease(dimension: 1, nonzeros: 2, numerical: n,
                policy: .init(quotaBytes: 128, recordCapacity: 1), work: &work) { _ in
                    let first = try A.allocate(8); defer { A.release(first) }
                    _ = try A.allocate(8)
                }
        }
        let (_, recovered) = try A.withLease(dimension: 1, nonzeros: 2, numerical: n,
            policy: .init(quotaBytes: 128, recordCapacity: 1), work: &work) { _ in A.release(try A.allocate(112)) }
        #expect(recovered.outstandingAllocations == 0)
    }

    @Test func injectedAllocationFailureAfterPartialAllocationIsTypedAndCleanupAllowsNextLease() throws {
        let n = try context(); var work: UInt64 = 0
        let small = A.Policy(quotaBytes: 128, recordCapacity: 2)
        var injected = small; injected.failAfterAllocations = 1
        var released = false
        do {
            _ = try A.withLease(dimension: 1, nonzeros: 2, numerical: n,
                policy: injected, work: &work) { _ in
                    let first = try A.allocate(16)
                    defer { A.release(first); released = true }
                    _ = try A.allocate(16)
                }
            Issue.record("Injected malloc failure unexpectedly returned a candidate")
        } catch let error as NativeSTAConservativeCouplingError {
            if case .nativeBackendFailure = error { } else { Issue.record("Injected malloc failure changed backend category") }
        }
        #expect(released)
        let (_, statistics) = try A.withLease(dimension: 1, nonzeros: 2, numerical: n,
            policy: small, work: &work) { _ in A.release(try A.allocate(16)) }
        #expect(statistics.outstandingAllocations == 0)
    }

    @Test func indefiniteNativeFactorIsFatalAndAllOwnedStorageIsReleased() throws {
        let n = try context(slots: 16_000_000); let sparse = S(numerical: n); var work: UInt64 = 0
        let g = try sparse.fromRows([[0: I(point: -1)]], columns: 1, work: &work)
        let (_, statistics) = try A.withLease(dimension: 1, nonzeros: 1, numerical: n,
            policy: policy(n), work: &work) { work in
                let factor = try NativeSTAConservativeNativeFactor(conductance: g, capacitance: nil, numerical: n, work: &work)
                defer { factor.close(); factor.close() }
                do {
                    try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work)
                    Issue.record("Indefinite Cholesky unexpectedly returned a candidate")
                } catch let error as NativeSTAConservativeCouplingError {
                    if case .nativeBackendFailure = error { } else { Issue.record("Native factor failure changed category") }
                }
            }
        #expect(statistics.outstandingAllocations == 0)
    }

    @Test func twoConcurrentNativeJobsKeepIndependentFactorsAndQuotas() async throws {
        let results = try await withThrowingTaskGroup(of: Double.self) { group in
            for scale in [1.0, 2.0] {
                group.addTask {
                    let n = try context(slots: 16_000_000); let s = S(numerical: n); var work: UInt64 = 0
                    let g = try s.fromRows([[0: I(point: 4 * scale), 1: I(point: -scale)],
                                           [0: I(point: -scale), 1: I(point: 3 * scale)]], columns: 2, work: &work)
                    let (answer, statistics) = try A.withLease(dimension: 2, nonzeros: g.values.count,
                        numerical: n, policy: policy(n), work: &work) { work in
                            let factor = try NativeSTAConservativeNativeFactor(conductance: g, capacitance: nil, numerical: n, work: &work)
                            defer { factor.close() }
                            try factor.factor(conductanceScale: 1, capacitanceScale: 0, work: &work)
                            var rhs = [3 * scale, 2 * scale]
                            try factor.solve(&rhs, columns: 1, work: &work)
                            return rhs[0] + rhs[1]
                        }
                    #expect(statistics.outstandingAllocations == 0 && statistics.peakLiveBytes <= policy(n).quotaBytes!)
                    return answer
                }
            }
            var results: [Double] = []
            for try await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 2 && results.allSatisfy { abs($0 - 2) < 1e-13 })
    }
    #endif

    private struct RefusingResources: LibertySourceResourceAccounting {
        enum Failure: Error { case ownerRefusal }
        func check() throws { throw Failure.ownerRefusal }
        func chargeWork(_ amount: UInt64) throws { throw Failure.ownerRefusal }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation { throw Failure.ownerRefusal }
    }

    @Test func sourceAndWorkRefusalsPropagateWithoutNativeSuccess() throws {
        let ordinary = try context(); var work: UInt64 = 0
        let reduced = try pole(ordinary, work: &work)
        let refused = try context(resources: RefusingResources())
        #expect(throws: RefusingResources.Failure.self) {
            _ = try C.withSession(reduced: reduced, numerical: refused, work: &work) { _, _ in 0 }
        }
        let bounded = try context(workLimit: 1)
        var exceededWork: UInt64 = 2
        #expect(throws: STAPathAnalysisError.capacity(resource: "conservative RC work", limit: 1)) {
            _ = try C.withSession(reduced: reduced, numerical: bounded, work: &exceededWork) { _, _ in 0 }
        }
        #expect(exceededWork == 2)
    }

    @Test func cancellationIsCheckedBeforeOpeningNativeLease() async throws {
        let cancelled = await Task {
            do {
                let n = try context(); var work: UInt64 = 0
                let reduced = try pole(n, work: &work)
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try C.withSession(reduced: reduced, numerical: n, work: &work) { _, _ in 0 }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        #expect(cancelled)
    }
}

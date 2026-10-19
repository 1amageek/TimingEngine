import Foundation
import Testing
@testable import TimingCore
@testable import STAEngine

@Suite("Source-local certified residual response")
struct STAConservativeResidualResponseTests {
    private typealias N = NativeSTAConservativeNumerics
    private typealias I = TimingNumericInterval
    private typealias C = NativeSTAConservativeResidualCertificate
    private typealias R = NativeSTAConservativeResidualResponse
    private typealias K = NativeSTAConservativeCoupling
    private typealias E = TimingParasitics.Endpoint

    private func numerical(states: Int = 2_000_000, work: UInt64 = 100_000_000) throws -> N {
        let limits = try STAExecutionLimits(maximumPathStates: states, maximumPathWorkUnits: work)
        return N(limits: limits, budget: .init(maximum: states), resources: nil)
    }

    /// These polynomial receipts isolate integration; only the checker owns physical validity.
    private func polynomialReceipt(_ n: N, sources: Int = 1, g: [Double], h: [Double],
        duration: Double = 2, error: Double = 0) throws -> C.Facts {
        var coefficients: [N.Matrix] = []
        for index in 0..<4 {
            var matrix = try n.matrix(1, 2 * sources)
            matrix[0, 0] = try I(point: g[index])
            matrix[0, sources] = try I(point: h[index])
            coefficients.append(matrix)
        }
        var errors = try n.matrix(1, 2 * sources)
        for index in errors.values.indices { errors.values[index] = try I(point: error) }
        var direct = try n.matrix(1, sources)
        direct[0, 0] = try I(point: 1)
        return C.Facts(receiverRows: [0], sourceCount: sources,
            segments: [.init(start: 0, end: duration, bernstein: coefficients)],
            errors: .init(initial: errors, solve: errors, interpolation: errors, tail: errors), direct: direct)
    }

    @Test("signed and crossing-zero polynomials retain absolute gain and all four errors")
    func polynomialGain() throws {
        let n = try numerical()
        var work: UInt64 = 0
        let response = R(numerical: n)
        let signed = try response.prepare(polynomialReceipt(n, sources: 2,
            g: [-1, -1, -1, -1], h: [0, 0, 0, 4], error: 0.25), work: &work)
        #expect(signed.gL1[0, 0].upperBound >= 3)
        #expect(signed.gL1[0, 0].upperBound < 3.000000000001)
        #expect(signed.hL1[0, 0].upperBound >= 3)
        #expect(signed.hError[0, 0].upperBound >= 1)
        #expect(signed.hSegments[0].bernstein.allSatisfy { $0.columns == 2 })
        let crossing = try response.prepare(polynomialReceipt(n,
            g: [1, -1, 1, -1], h: [0, 0, 0, 0]), work: &work)
        // p(theta) = (1-2 theta)^3 has zero signed integral but absolute integral 1/2.
        #expect(crossing.gL1[0, 0].upperBound >= 0.5)
        #expect(crossing.gL1[0, 0].upperBound <= 2.000000000001)
    }

    @Test("an independent source keeps exactly zero physical response")
    func independentSourceLocality() throws {
        let n = try numerical()
        var work: UInt64 = 0
        let response = R(numerical: n)
        let facts = try response.prepare(polynomialReceipt(n, sources: 2,
            g: [-1, -1, -1, -1], h: [1, 1, 1, 1]), work: &work)
        #expect(facts.gL1[0, 1].upperBound == 0)
        #expect(facts.hL1[0, 1].upperBound == 0)
        #expect(try response.suffix(facts, receiver: 0, source: 1, elapsed: 1, work: &work).upperBound == 0)
    }

    @Test("suffix subdivision encloses an independent cubic integral and retains the whole defect")
    func suffixIntegral() throws {
        let n = try numerical()
        var work: UInt64 = 0
        let response = R(numerical: n)
        let facts = try response.prepare(polynomialReceipt(n,
            g: [0, 0, 0, 0], h: [0, 0, 0, 4], error: 0.25), work: &work)
        for elapsed in [0.0, 0.125, 1, 1.875, 2, 3] {
            let actual = elapsed >= 2 ? 1 : 1 + 2 * (1 - pow(elapsed / 2, 4))
            let bound = try response.suffix(facts, receiver: 0, source: 0, elapsed: elapsed, work: &work)
            #expect(bound.upperBound >= actual)
            #expect(bound.upperBound < actual + 1e-12)
        }
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try response.suffix(facts, receiver: 0, source: 0, elapsed: -1, work: &work)
        }
    }

    @Test("missing pieces, broken grids and negative defect receipts fail at the boundary")
    func malformedReceipts() throws {
        let n = try numerical()
        var work: UInt64 = 0
        let response = R(numerical: n)
        let receipt = try polynomialReceipt(n, g: [0, 0, 0, 0], h: [1, 1, 1, 1])
        let broken = C.Facts(receiverRows: receipt.receiverRows, sourceCount: receipt.sourceCount,
            segments: [.init(start: 1, end: 2, bernstein: receipt.segments[0].bernstein)],
            errors: receipt.errors, direct: receipt.direct)
        #expect(throws: NativeSTAConservativeCouplingError.self) { try response.prepare(broken, work: &work) }
        let missing = C.Facts(receiverRows: receipt.receiverRows, sourceCount: receipt.sourceCount,
            segments: [], errors: receipt.errors, direct: receipt.direct)
        #expect(throws: NativeSTAConservativeCouplingError.self) { try response.prepare(missing, work: &work) }
        var negative = try n.matrix(1, 2)
        negative[0, 1] = try I(point: -1)
        let invalid = C.Facts(receiverRows: receipt.receiverRows, sourceCount: receipt.sourceCount,
            segments: receipt.segments, errors: .init(initial: negative, solve: receipt.errors.solve,
                interpolation: receipt.errors.interpolation, tail: receipt.errors.tail), direct: receipt.direct)
        #expect(throws: NativeSTAConservativeCouplingError.self) { try response.prepare(invalid, work: &work) }
    }

    @Test("integration preserves cumulative storage and work refusals")
    func capacity() throws {
        let receipt = try polynomialReceipt(numerical(), g: [0, 0, 0, 0], h: [1, 1, 1, 1])
        var work: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) {
            try R(numerical: numerical(states: 1)).prepare(receipt, work: &work)
        }
        work = 0
        #expect(throws: STAPathAnalysisError.self) {
            try R(numerical: numerical(work: 1)).prepare(receipt, work: &work)
        }
    }

    @Test("integration cancellation remains cancellation")
    func cancellation() async throws {
        let n = try numerical()
        let receipt = try polynomialReceipt(n, g: [0, 0, 0, 0], h: [1, 1, 1, 1])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var work: UInt64 = 0
            return try R(numerical: n).prepare(receipt, work: &work)
        }
        do { _ = try await task.value; Issue.record("Cancelled integration published gain facts") }
        catch is CancellationError { }
    }

    #if os(macOS)
    private var thresholds: TimingCharacterizationThresholds {
        .init(inputRise: 50, inputFall: 50, outputRise: 50, outputFall: 50,
            slewLowerRise: 20, slewUpperRise: 80, slewLowerFall: 20, slewUpperFall: 80)
    }

    private func onePole(tau: Double = 1e-12, sourceIsPort: Bool = true,
        admitted: ClosedRange<Double> = 3e-9...9e-9,
        thresholds: TimingCharacterizationThresholds? = nil,
        work: inout UInt64) throws -> K.ResidualPrepared {
        let n = try numerical(states: 16_000_000), t = thresholds ?? self.thresholds
        let driver = E(name: "driver", ownerNet: "n"), sink = E(name: "sink", ownerNet: "n")
        let capacitance = 1e-14, resistance = tau / capacitance
        let id = TimingParasitics.SourceID(declaringNet: "n", identifier: 1, line: 1)
        let inventory = TimingParasitics(networks: [.init(name: "n",
            capacitances: [.init(source: id, first: sink, capacitance: capacitance)],
            resistances: [.init(source: id, first: driver, second: sink, resistance: resistance)],
            connections: [driver, sink])])
        let solver = NativeSTAConservativeSparseNumerics(numerical: n)
        let g = try solver.fromRows([[0: I(point: 1).divided(by: I(point: resistance))]], columns: 1, work: &work)
        let c = try solver.fromRows([[0: I(point: capacitance)]], columns: 1, work: &work)
        let identity = try solver.fromRows([[0: I(point: 1)]], columns: 1, work: &work)
        var forcing = try n.matrix(1, 1)
        forcing[0, 0] = try I(point: capacitance)
        let reduced = NativeSTAConservativeSparseGraph.Reduced(dynamicRows: [0], conductance: g,
            capacitance: c, forcing: forcing, reconstruction: identity, dcIncidence: identity, capBlocks: [[0]])
        var times = [0.0], time = tau / 16
        while time < 48 * tau { times.append(time); time *= 1.125 }
        times.append(48 * tau)
        let checked = try C(numerical: n).prepare(reduced, receiverRows: [0], times: times, work: &work)
        let facts = try R(numerical: n).prepare(checked, work: &work)
        var slopes = try n.matrix(1, 1)
        let rise = try K().thresholdSpan(t, rising: true), fall = try K().thresholdSpan(t, rising: false)
        slopes[0, 0] = try I(point: max(rise.divided(by: I(point: admitted.lowerBound)).upperBound,
            fall.divided(by: I(point: admitted.lowerBound)).upperBound))
        return K.ResidualPrepared(parasitics: inventory,
            sources: [.dynamic(endpoint: driver, sourceIsPort: sourceIsPort, riseSlew: admitted, fallSlew: admitted)],
            receiverLoads: [:], endpointRows: [sink: 0], endpointSource: [driver: 0, sink: 0],
            sourceIndices: [driver: 0], sourceSlopes: slopes, dcIncidence: identity, thresholds: t,
            options: try .init(maximumNodes: 2, maximumBasisSweeps: 8, maximumCertificateAttempts: 8,
                operatingHistory: .boundedOperatingHistory), numerics: n, facts: facts)
    }

    private func response(_ prepared: K.ResidualPrepared, edge: TimingEdge = .rise,
        slew: ClosedRange<Double> = 3e-9...9e-9, work: inout UInt64) throws -> K.Bounds {
        try K().bounds(prepared: .residual(prepared), source: E(name: "driver", ownerNet: "n"),
            sink: E(name: "sink", ownerNet: "n"), edge: edge, sourceSlew: slew, work: &work)
    }

    @Test("real one-pole checker and response enclose analytic crossings over the entire slew interval",
        arguments: [TimingEdge.rise, .fall])
    func physicalOnePole(_ edge: TimingEdge) throws {
        var work: UInt64 = 0
        let prepared = try onePole(work: &work)
        let bound = try response(prepared, edge: edge, work: &work)
        for slew in [3e-9, 6e-9, 9e-9] {
            let duration = slew / 0.6, tau = 1e-12
            func crossing(_ threshold: Double) -> Double {
                var low = 0.0, high = duration
                for _ in 0..<100 {
                    let time = (low + high) / 2
                    let value = (time - tau * (1 - exp(-time / tau))) / duration
                    if value < threshold { low = time } else { high = time }
                }
                return (low + high) / 2
            }
            #expect(bound.delay.contains(crossing(0.5) - duration / 2))
            #expect(bound.slew.contains(crossing(0.8) - crossing(0.2)))
        }
        #expect(bound.minimumCrossingDerivative > 0)
        #expect(bound.admittedSourceSlew == 3e-9...9e-9)
        #expect(bound.voltageErrorUpperBound >= 2e-4)
    }

    @Test("receiver thresholds outside the slew band preserve negative cell-source wire delay")
    func thresholdRoles() throws {
        var work: UInt64 = 0
        let t = TimingCharacterizationThresholds(inputRise: 10, inputFall: 90, outputRise: 70, outputFall: 30,
            slewLowerRise: 20, slewUpperRise: 80, slewLowerFall: 20, slewUpperFall: 80)
        let prepared = try onePole(sourceIsPort: false, admitted: 6e-9...6e-9, thresholds: t, work: &work)
        for edge in [TimingEdge.rise, .fall] {
            let result = try response(prepared, edge: edge, slew: 6e-9...6e-9, work: &work)
            #expect(result.delay.contains(-6e-9 + 1e-12))
            #expect(result.delay.upperBound < 0)
        }
    }

    @Test("a real one-pole response refuses missing crossings and unproved uniqueness")
    func crossingRefusal() throws {
        var work: UInt64 = 0
        let slow = try onePole(tau: 3e-9, admitted: 6e-9...6e-9, work: &work)
        do { _ = try response(slow, slew: 6e-9...6e-9, work: &work); Issue.record("Missing voltage guard passed") }
        catch NativeSTAConservativeCouplingError.unprovedCrossing { }
        let uncertain = try onePole(tau: 1.5e-9, admitted: 6e-9...6e-9, work: &work)
        do { _ = try response(uncertain, slew: 6e-9...6e-9, work: &work); Issue.record("Unproved derivative passed") }
        catch NativeSTAConservativeCouplingError.unprovedUniqueTransition(let source, let sink, let edge, let diagnostic) {
            let context = try #require(diagnostic)
            #expect(source == uncertain.sources[0].endpoint)
            #expect(sink == E(name: "sink", ownerNet: "n") && edge == .rise)
            #expect(context.voltageErrorUpperBound < 0.2)
            #expect(context.querySlope.contains(1e8))
            #expect(context.deltaLowerBound > 0)
            #expect(context.ownTailUpperBound >= context.ownHErrorUpperBound)
            #expect(context.ownTermUpperBound >= context.querySlope.lowerBound)
            #expect(context.aggressorDerivativeUpperBound == 0)
            #expect(context.minimumDerivative.lowerBound <= 0)
            #expect(context.minimumDerivative.lowerBound <= context.querySlope.lowerBound
                - context.ownTermUpperBound - context.aggressorDerivativeUpperBound)
            #expect(context.maximumDerivativeUpperBound > 0)
            #expect(context.horizon == uncertain.facts.hSegments.last?.end)
            #expect(context.segmentCount == uncertain.facts.hSegments.count)
            let contribution = try #require(context.contributions.first)
            #expect(context.contributions.count == uncertain.sources.count)
            #expect(contribution.source == source && !contribution.isAggressor)
            #expect(contribution.slopeUpperBound == context.ownHistorySlopeUpperBound)
            #expect(contribution.directMagnitudeUpperBound == (try uncertain.facts.direct[0, 0].absolute()).upperBound)
            #expect(contribution.hL1UpperBound == uncertain.facts.hL1[0, 0].upperBound)
            #expect(contribution.hErrorUpperBound == context.ownHErrorUpperBound)
            #expect(contribution.derivativeUpperBound <= context.maximumDerivativeUpperBound)
        }
    }

    @Test("comparison refusals preserve the taxonomy without residual diagnostics")
    func comparisonRefusalHasNoResidualContext() throws {
        var work: UInt64 = 0
        let driver = E(name: "driver", ownerNet: "n"), sink = E(name: "sink", ownerNet: "n")
        let aggressor = E(name: "aggressor", ownerNet: "a")
        let id = TimingParasitics.SourceID(declaringNet: "n", identifier: 1, line: 1)
        let couplingID = TimingParasitics.SourceID(declaringNet: "n", identifier: 2, line: 2)
        let inventory = TimingParasitics(networks: [.init(name: "n",
            capacitances: [.init(source: id, first: sink, capacitance: 1e-15),
                           .init(source: couplingID, first: sink, second: aggressor, capacitance: 1e-15)],
            resistances: [.init(source: id, first: driver, second: sink, resistance: 1)], connections: [driver, sink]),
            .init(name: "a", connections: [aggressor])])
        let sources: [K.Source] = [
            .dynamic(endpoint: driver, sourceIsPort: true, riseSlew: 6e-9...6e-9, fallSlew: 6e-9...6e-9),
            .dynamic(endpoint: aggressor, sourceIsPort: true, riseSlew: 6e-11...6e-11, fallSlew: 6e-11...6e-11)]
        let n = try numerical()
        let options = try STAConservativeCoupledRCOptions(maximumNodes: 3, maximumBasisSweeps: 8,
            maximumCertificateAttempts: 8, operatingHistory: .boundedOperatingHistory)
        let prepared = try K().prepare(parasitics: inventory, sources: sources, receiverLoads: [:],
            thresholds: thresholds, options: options, limits: n.limits, stateBudget: n.budget,
            sourceResources: nil, work: &work)
        guard case .comparison(let model) = prepared else { Issue.record("Coupled one pole did not select the comparison certificate"); return }
        #expect(model.voltageError.values.allSatisfy { $0.upperBound < 0.2 })
        do {
            _ = try K().bounds(prepared: prepared, source: E(name: "driver", ownerNet: "n"),
                sink: E(name: "sink", ownerNet: "n"), edge: .rise, sourceSlew: 6e-9...6e-9, work: &work)
            Issue.record("Unproved comparison derivative passed")
        } catch NativeSTAConservativeCouplingError.unprovedUniqueTransition(_, _, _, let diagnostic) {
            #expect(diagnostic == nil)
        }
    }

    @Test("failure diagnostics propagate their storage refusal and cancellation")
    func failureDiagnosticResources() async throws {
        var work: UInt64 = 0
        let physical = try onePole(tau: 1.5e-9, admitted: 6e-9...6e-9, work: &work)
        let capped = try numerical(states: 8)
        var queryWork: UInt64 = 0
        do {
            _ = try R(numerical: capped).bounds(prepared: physical, source: E(name: "driver", ownerNet: "n"),
                sink: E(name: "sink", ownerNet: "n"), edge: .rise, sourceSlew: 6e-9...6e-9, work: &queryWork)
            Issue.record("A diagnostic exceeded its cumulative storage budget")
        } catch STAPathAnalysisError.capacity(let resource, let limit) {
            #expect(resource == "cumulative native state slots" && limit == 8)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var cancelledWork: UInt64 = 0
            return try R(numerical: physical.numerics).bounds(prepared: physical,
                source: E(name: "driver", ownerNet: "n"), sink: E(name: "sink", ownerNet: "n"),
                edge: .rise, sourceSlew: 6e-9...6e-9, work: &cancelledWork)
        }
        do { _ = try await task.value; Issue.record("Cancelled diagnostic query returned bounds") }
        catch is CancellationError { }
    }

    @Test("zero or outside-domain query slew never acquires timing authority")
    func sourceAuthority() throws {
        var work: UInt64 = 0
        let prepared = try onePole(work: &work)
        for invalid in [0.0...0.0, 1e-9...9e-9, 3e-9...10e-9] {
            #expect(throws: NativeSTAConservativeCouplingError.self) {
                try response(prepared, slew: invalid, work: &work)
            }
        }
    }
    #endif
}

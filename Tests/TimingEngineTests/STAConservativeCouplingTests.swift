import Foundation
import Testing
@testable import TimingCore
@testable import STAEngine

@Suite("Certified all-history coupled RC")
struct STAConservativeCouplingTests {
    private typealias K = NativeSTAConservativeCoupling
    private typealias E = TimingParasitics.Endpoint
    private let driver = E(name: "driver", ownerNet: "n")
    private let sink = E(name: "sink", ownerNet: "n")
    private let aggressor = E(name: "aggressor", ownerNet: "a")
    private var thresholds: TimingCharacterizationThresholds {
        .init(inputRise: 50, inputFall: 50, outputRise: 50, outputFall: 50,
              slewLowerRise: 20, slewUpperRise: 80, slewLowerFall: 20, slewUpperFall: 80)
    }
    private func id(_ number: UInt64, net: String = "n") -> TimingParasitics.SourceID {
        .init(declaringNet: net, identifier: number, line: Int(number))
    }
    private func options(nodes: Int = 32, attempts: Int = 12) throws -> STAConservativeCoupledRCOptions {
        try .init(maximumNodes: nodes, maximumBasisSweeps: 8, maximumCertificateAttempts: attempts, operatingHistory: .boundedOperatingHistory)
    }
    private func source(_ endpoint: E, slew: Double = 6e-9) -> K.Source {
        .dynamic(endpoint: endpoint, sourceIsPort: true, riseSlew: slew...slew, fallSlew: slew...slew)
    }
    private func onePole(resistance: Double = 100, capacitance: Double = 1e-14,
                         coupling: Double = 0, mirrored: Bool = false, parallel: Bool = false) -> TimingParasitics {
        var caps = [TimingParasitics.CapacitanceRecord(source: id(1), first: sink, capacitance: capacitance)]
        if coupling > 0 { caps.append(.init(source: id(2), first: sink, second: aggressor, capacitance: coupling)) }
        if parallel { caps.append(.init(source: id(3), first: sink, capacitance: capacitance)) }
        var nets = [TimingParasitics.Network(name: "n", capacitances: caps,
            resistances: [.init(source: id(1), first: driver, second: sink, resistance: resistance)], connections: [driver, sink])]
        if coupling > 0 {
            nets.append(.init(name: "a", capacitances: mirrored ? [.init(source: id(1, net: "a"), first: aggressor, second: sink, capacitance: coupling)] : [], connections: [aggressor]))
        }
        return .init(networks: nets)
    }
    private func prepare(_ inventory: TimingParasitics, sources: [K.Source]? = nil,
                         receiverLoads: [E: Double] = [:],
                         limits: STAExecutionLimits? = nil, options: STAConservativeCoupledRCOptions? = nil,
                         work: inout UInt64) throws -> K.Prepared {
        let limits = try limits ?? .init(maximumPathStates: 1_000_000)
        return try K().prepare(parasitics: inventory, sources: sources ?? [source(driver)], receiverLoads: receiverLoads,
            thresholds: thresholds, options: options ?? self.options(), limits: limits,
            stateBudget: NativeSTAStateBudget(maximum: limits.maximumPathStates), sourceResources: nil, work: &work)
    }
    private func comparison(_ prepared: K.Prepared) throws -> K.ComparisonPrepared {
        let model: K.ComparisonPrepared?
        switch prepared {
        case .comparison(let comparison): model = comparison
        case .residual: model = nil
        }
        return try #require(model)
    }

    private func response(_ prepared: K.Prepared, edge: TimingEdge = .rise, work: inout UInt64) throws -> K.Bounds {
        try K().bounds(prepared: prepared, source: driver, sink: sink, edge: edge, sourceSlew: 6e-9...6e-9, work: &work)
    }

    @Test("one pole encloses independently solved ramp crossings", arguments: [TimingEdge.rise, .fall])
    func onePoleCrossings(_ edge: TimingEdge) throws {
        var work: UInt64 = 0
        let prepared = try prepare(onePole(), work: &work)
        let bounds = try response(prepared, edge: edge, work: &work)
        let tau = 100.0 * 1e-14, duration = 1e-8
        func crossing(_ q: Double) -> Double {
            var low = 0.0, high = duration
            for _ in 0..<100 {
                let t = (low + high) / 2
                let voltage = t / duration - tau / duration * (1 - exp(-t / tau))
                if voltage < q { low = t } else { high = t }
            }
            return (low + high) / 2
        }
        let delay = crossing(0.5) - duration * 0.5
        let slew = crossing(0.8) - crossing(0.2)
        #expect(bounds.delay.contains(delay))
        #expect(bounds.slew.contains(slew))
        #expect(bounds.minimumCrossingDerivative > 0)
        #expect(bounds.maximumAbsoluteDerivative >= 1 / duration)
        #expect(bounds.voltageErrorUpperBound >= tau / duration)
        #expect(bounds.voltageErrorUpperBound < 2.01 * tau / duration)
    }

    @Test("every active aggressor history contributes its global slope")
    func activeAggressor() throws {
        var work: UInt64 = 0
        let r = 100.0, cg = 1e-14, cc = 1e-15
        let prepared = try prepare(onePole(resistance: r, capacitance: cg, coupling: cc),
            sources: [source(driver), source(aggressor, slew: 3e-9)], work: &work)
        let result = try response(prepared, work: &work)
        let independentAllHistoryBound = r * ((cg + cc) * 1e8 + cc * 2e8)
        #expect(result.voltageErrorUpperBound >= independentAllHistoryBound)
        #expect(result.voltageErrorUpperBound < 2.01 * independentAllHistoryBound)
        #expect(result.minimumCrossingDerivative > 0)
        // Opposite aggressor ramps attain the additive forcing sign, with arbitrary shifts.
        let effectiveSlope = ((cg + cc) * 1e8 + cc * 2e8) / (cg + cc)
        for shift in [-3e-9, 0, 3e-9] {
            let elapsed = max(0, 5e-9 - shift)
            let error = r * (cg + cc) * effectiveSlope * (1 - exp(-elapsed / (r * (cg + cc))))
            #expect(error <= result.voltageErrorUpperBound)
        }
    }

    @Test("two active coupled resistive nets retain both analytic modes")
    func twoActiveResistiveNets() throws {
        var work: UInt64 = 0
        let otherSink = E(name: "otherSink", ownerNet: "a")
        let cg = 1e-14, cc = 1e-17, r = 100.0
        let p = TimingParasitics(networks: [
            .init(name: "n", capacitances: [.init(source: id(1), first: sink, capacitance: cg),
                                           .init(source: id(2), first: sink, second: otherSink, capacitance: cc)],
                  resistances: [.init(source: id(1), first: driver, second: sink, resistance: r)], connections: [driver, sink]),
            .init(name: "a", capacitances: [.init(source: id(1, net: "a"), first: otherSink, capacitance: cg)],
                  resistances: [.init(source: id(1, net: "a"), first: aggressor, second: otherSink, resistance: r)],
                  connections: [aggressor, otherSink])])
        let prepared = try prepare(p, sources: [source(driver), source(aggressor)], work: &work)
        let result = try response(prepared, work: &work)
        // Common and differential mode time constants are independent closed forms.
        let commonTau = r * cg, differentialTau = r * (cg + 2 * cc)
        #expect(result.voltageErrorUpperBound >= commonTau * 1e8)
        #expect(result.voltageErrorUpperBound >= differentialTau * 1e8)
        #expect(result.minimumCrossingDerivative > 0)
        #expect((try comparison(prepared)).operatorA.rows == 2)
        #expect((try comparison(prepared)).forcingJ.columns == 2)
    }

    @Test("an aggressor reversal without a unique-crossing proof is refused")
    func noDerivativeCertificate() throws {
        var work: UInt64 = 0
        let p = try prepare(onePole(resistance: 1, capacitance: 1e-15, coupling: 1e-15),
            sources: [source(driver), source(aggressor, slew: 6e-11)], work: &work)
        #expect((try comparison(p)).voltageError.values.allSatisfy { $0.upperBound < 0.2 })
        do {
            _ = try response(p, work: &work)
            Issue.record("Unproved reversal returned a completed bound")
        } catch NativeSTAConservativeCouplingError.unprovedUniqueTransition { }
    }

    @Test("canonical mirrored declarations stamp once; parallel physical IDs stamp twice")
    func physicalIdentity() throws {
        var work: UInt64 = 0
        let sources = [source(driver), source(aggressor)]
        let single = try response(prepare(onePole(coupling: 1e-15), sources: sources, work: &work), work: &work)
        let mirrorPrepared = try prepare(onePole(coupling: 1e-15, mirrored: true), sources: sources, work: &work)
        let mirror = try response(mirrorPrepared, work: &work)
        let parallel = try response(prepare(onePole(parallel: true), work: &work), work: &work)
        let plain = try response(prepare(onePole(), work: &work), work: &work)
        #expect(mirror.voltageErrorUpperBound == single.voltageErrorUpperBound)
        #expect((try comparison(mirrorPrepared)).parasitics.networks[1].capacitances.count == 1)
        #expect(parallel.voltageErrorUpperBound >= 1.99 * plain.voltageErrorUpperBound)
    }

    @Test("zero resistance preserves distinct terminal identity and analytical timing")
    func idealAlias() throws {
        var work: UInt64 = 0
        let prepared = try prepare(onePole(resistance: 0), work: &work)
        let result = try response(prepared, work: &work)
        #expect(result.delay.contains(0))
        #expect(result.slew == 6e-9...6e-9)
        #expect(result.voltageErrorUpperBound == 0)
        #expect((try comparison(prepared)).endpointSource[driver] == (try comparison(prepared)).endpointSource[sink])
        #expect((try comparison(prepared)).parasitics.networks[0].resistances[0].source == id(1))
    }

    @Test("source-to-source capacitance retains evidence without changing prescribed voltages")
    func prescribedSourceCapacitance() throws {
        var work: UInt64 = 0
        let baseline = onePole(coupling: 1e-15)
        var nets = baseline.networks
        let original = nets[0]
        nets[0] = .init(name: original.name,
            capacitances: original.capacitances + [.init(source: id(4), first: driver, second: aggressor, capacitance: 1)],
            resistances: original.resistances, connections: original.connections)
        let sources = [source(driver), source(aggressor)]
        let before = try response(prepare(baseline, sources: sources, work: &work), work: &work)
        let after = try response(prepare(.init(networks: nets), sources: sources, work: &work), work: &work)
        #expect(before.voltageErrorUpperBound == after.voltageErrorUpperBound)
        #expect(before.delay == after.delay)
    }

    @Test("all algebraic rows follow the canonical source exactly")
    func noCapacitance() throws {
        var work: UInt64 = 0
        let p = try prepare(onePole(capacitance: 0), work: &work)
        let result = try response(p, work: &work)
        #expect(result.delay.contains(0))
        #expect(result.slew == 6e-9...6e-9)
        #expect(result.voltageErrorUpperBound == 0)
    }

    @Test("cell source uses output threshold and covers receiver outside the slew band")
    func differentThresholdConventions() throws {
        var work: UInt64 = 0
        let t = TimingCharacterizationThresholds(inputRise: 10, inputFall: 90, outputRise: 70, outputFall: 30,
            slewLowerRise: 20, slewUpperRise: 80, slewLowerFall: 20, slewUpperFall: 80)
        let limits = try STAExecutionLimits(maximumPathStates: 1_000_000)
        let p = try K().prepare(parasitics: onePole(),
            sources: [.dynamic(endpoint: driver, sourceIsPort: false, riseSlew: 6e-9...6e-9, fallSlew: 6e-9...6e-9)],
            receiverLoads: [:], thresholds: t, options: options(), limits: limits,
            stateBudget: .init(maximum: limits.maximumPathStates), sourceResources: nil, work: &work)
        let result = try response(p, work: &work)
        #expect(result.delay.contains(-6e-9 + 1e-12))
        #expect(result.minimumCrossingDerivative > 0)
    }

    @Test("actual zero capacitance row uses Schur reconstruction")
    func algebraicRow() throws {
        var work: UInt64 = 0
        let middle = E(name: "middle", ownerNet: "n")
        let p = TimingParasitics(networks: [.init(name: "n", capacitances: [.init(source: id(1), first: sink, capacitance: 1e-14)],
            resistances: [.init(source: id(1), first: driver, second: middle, resistance: 40),
                          .init(source: id(2), first: middle, second: sink, resistance: 60)], connections: [driver, sink])])
        let result = try response(prepare(p, work: &work), work: &work)
        #expect(result.voltageErrorUpperBound >= 100 * 1e-14 * 1e8)
        #expect(result.voltageErrorUpperBound < 2.01 * 100 * 1e-14 * 1e8)
        #expect(result.minimumCrossingDerivative > 0)
    }

    @Test("differential floating capacitance nullspace is refused")
    func singularCapacitance() throws {
        var work: UInt64 = 0
        let other = E(name: "other", ownerNet: "n")
        let p = TimingParasitics(networks: [.init(name: "n", capacitances: [.init(source: id(1), first: sink, second: other, capacitance: 1e-14)],
            resistances: [.init(source: id(1), first: driver, second: sink, resistance: 100),
                          .init(source: id(2), first: driver, second: other, resistance: 100)], connections: [driver, sink])])
        #expect(throws: NativeSTAConservativeCouplingError.self) { try prepare(p, work: &work) }
    }

    @Test("missing coupled source, zero global slew and out-of-domain query fail")
    func sourceAuthority() throws {
        var work: UInt64 = 0
        #expect(throws: NativeSTAConservativeCouplingError.self) { try prepare(onePole(coupling: 1e-15), work: &work) }
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try prepare(onePole(), sources: [source(driver, slew: 0)], work: &work)
        }
        let p = try prepare(onePole(), work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try K().bounds(prepared: p, source: driver, sink: sink, edge: .rise, sourceSlew: 3e-9...6e-9, work: &work)
        }
    }

    @Test("large all-history error never becomes an optimistic finite result")
    func absentCrossingCertificate() throws {
        var work: UInt64 = 0
        let p = try prepare(onePole(resistance: 1e6, capacitance: 1e-12), work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) { try response(p, work: &work) }
    }

    @Test("false ordinary inverse and indefinite operator cannot grant certificates")
    func numericalProof() throws {
        let limits = try STAExecutionLimits(maximumPathStates: 1_000_000)
        let n = NativeSTAConservativeNumerics(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: nil)
        var work: UInt64 = 0
        var matrix = try n.matrix(2, 2), rhs = try n.matrix(2, 1)
        for i in matrix.values.indices { matrix.values[i] = try .init(point: 1) }
        rhs[0, 0] = try .init(point: 1); rhs[1, 0] = try .init(point: 1)
        #expect(throws: NativeSTAConservativeCouplingError.self) { try n.solve(matrix, rhs, work: &work) }
        matrix[1, 1] = try .init(point: -1)
        #expect(throws: NativeSTAConservativeCouplingError.self) { try n.positiveDefinite(matrix, work: &work) }
    }

    @Test("original node, cumulative storage and cumulative work caps fail")
    func limits() throws {
        var work: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) { try prepare(onePole(), options: options(nodes: 1), work: &work) }
        #expect(throws: STAPathAnalysisError.self) { try prepare(onePole(), limits: .init(maximumPathStates: 1), work: &work) }
        work = 0
        #expect(throws: STAPathAnalysisError.self) { try prepare(onePole(), limits: .init(maximumPathWorkUnits: 1), work: &work) }
    }

    private func ladder(_ count: Int) -> (TimingParasitics, E) {
        var resistors: [TimingParasitics.ResistanceRecord] = []
        var capacitors: [TimingParasitics.CapacitanceRecord] = []
        var previous = driver
        for number in 1...count {
            let node = E(name: "ladder" + String(number), ownerNet: "n")
            resistors.append(.init(source: id(UInt64(number)), first: previous, second: node, resistance: 1))
            capacitors.append(.init(source: id(UInt64(number)), first: node, capacitance: 1e-17))
            previous = node
        }
        return (.init(networks: [.init(name: "n", capacitances: capacitors, resistances: resistors,
                                     connections: [driver, previous])]), previous)
    }

    @Test("sparse and dense preparation enclose the same independent ladder limit")
    func sparseDenseLadder() throws {
        let count = 24
        let (inventory, receiver) = ladder(count)
        var denseWork: UInt64 = 0, sparseWork: UInt64 = 0
        let dense = try prepare(inventory, work: &denseWork)
        let sparse = try prepare(inventory, limits: .init(maximumPathStates: 30_000), work: &sparseWork)
        let denseBounds = try K().bounds(prepared: dense, source: driver, sink: receiver, edge: .rise,
            sourceSlew: 6e-9...6e-9, work: &denseWork)
        let sparseBounds = try K().bounds(prepared: sparse, source: driver, sink: receiver, edge: .rise,
            sourceSlew: 6e-9...6e-9, work: &sparseWork)
        let exactSteadyRampDelay = Double(count * (count + 1) / 2) * 1e-17
        #expect(denseBounds.delay.contains(exactSteadyRampDelay))
        #expect(sparseBounds.delay.contains(exactSteadyRampDelay))
        #expect(denseBounds.slew.contains(6e-9))
        #expect(sparseBounds.slew.contains(6e-9))
        #expect((try comparison(sparse)).sourceCertificates != nil)
        #expect((try comparison(sparse)).operatorA.values.count <= 3 * count)
        #expect(sparseBounds.minimumCrossingDerivative > 0)
    }

    @Test("a sparse ladder executes within storage that cannot admit its dense operator")
    func boundedSparseLadder() throws {
        let count = 128
        let (inventory, receiver) = ladder(count)
        var work: UInt64 = 0
        let p = try prepare(inventory, limits: .init(maximumPathStates: 100_000),
            options: options(nodes: count + 1), work: &work)
        let result = try K().bounds(prepared: p, source: driver, sink: receiver, edge: .fall,
            sourceSlew: 6e-9...6e-9, work: &work)
        #expect(result.delay.contains(Double(count * (count + 1) / 2) * 1e-17))
        #expect(result.slew.contains(6e-9))
        #expect(result.minimumCrossingDerivative > 0)
        #expect((try comparison(p)).operatorA.rows == count)
        #expect((try comparison(p)).operatorA.values.count <= 3 * count)
        #expect((try comparison(p)).sourceCertificates != nil)
    }

    private func localBasisInventory(fallback: Bool = false) -> (TimingParasitics, [E]) {
        let nodes = (0..<64).map { E(name: "block" + String($0), ownerNet: "n") }
        let scale = 1e-18
        let groundC = fallback ? [4.0, 0.04, 12, 10] : [1.0, 1, 1]
        let shuntG = fallback ? [64.0, 0.2, 1, 0.8] : [1.0, 1, 1]
        var caps: [TimingParasitics.CapacitanceRecord] = []
        var resistors: [TimingParasitics.ResistanceRecord] = []
        for (i, node) in nodes.enumerated() {
            caps.append(.init(source: id(UInt64(i + 1)), first: node,
                              capacitance: scale * (i < groundC.count ? groundC[i] : 1)))
            resistors.append(.init(source: id(UInt64(i + 1)), first: driver, second: node,
                                   resistance: 1 / (i < shuntG.count ? shuntG[i] : 1)))
        }
        let coupling: [(Int, Int, Double)] = fallback ? [(0, 1, 0.016), (2, 3, 0.02)] : [(1, 2, 1)]
        for (i, item) in coupling.enumerated() {
            caps.append(.init(source: id(UInt64(100 + i)), first: nodes[item.0], second: nodes[item.1],
                              capacitance: scale * item.2))
        }
        let edges: [(Int, Int, Double)] = fallback
            ? [(0, 2, 0.16), (0, 3, 700), (1, 2, 850), (1, 3, 2), (2, 3, 0.07)] : [(0, 1, 100)]
        for (i, item) in edges.enumerated() {
            resistors.append(.init(source: id(UInt64(100 + i)), first: nodes[item.0], second: nodes[item.1],
                                   resistance: 1 / item.2))
        }
        return (.init(networks: [.init(name: "n", capacitances: caps, resistances: resistors,
                                      connections: [driver] + nodes)]), nodes)
    }

    @Test("local CAP modes restore a physical certificate that identity coordinates cannot prove")
    func localBasisPhysicalReconstruction() throws {
        let (inventory, nodes) = localBasisInventory()
        var work: UInt64 = 0
        // 64*n*n cannot fit this storage limit, selecting the actual sparse preparation branch.
        let prepared = try prepare(inventory, limits: .init(maximumPathStates: 200_000),
            options: options(nodes: 65, attempts: 1), work: &work)
        let certificates = try #require((try comparison(prepared)).sourceCertificates)
        let physical = try NativeSTAConservativeSparseNumerics(numerical: (try comparison(prepared)).numerics)
            .product((try comparison(prepared)).reconstruction, certificates.unitEquilibrium, work: &work)
        for node in nodes.prefix(3) {
            let row = try #require((try comparison(prepared)).endpointRows[node])
            // G*1=1 and C*1=Cg*1 give the independent exact unit-ramp equilibrium -Cg.
            #expect(physical[row, 0].lowerBound <= -1e-18)
            #expect(physical[row, 0].upperBound >= -1e-18)
            let result = try K().bounds(prepared: prepared, source: driver, sink: node, edge: .rise,
                sourceSlew: 6e-9...6e-9, work: &work)
            #expect(result.delay.contains(1e-18))
            #expect(result.slew.contains(6e-9))
            #expect(result.minimumCrossingDerivative > 0)
        }
        #expect((try comparison(prepared)).operatorA.rows == 64)
        #expect((try comparison(prepared)).reconstruction.values.contains { $0.lowerBound < 0 })
    }

    @Test("a rejected local modal certificate advances to whitening while quota failures remain fatal")
    func finiteCandidateFallback() throws {
        let (inventory, nodes) = localBasisInventory(fallback: true)
        let limits = try STAExecutionLimits(maximumPathStates: 200_000)
        var rejectedWork: UInt64 = 0
        do {
            _ = try prepare(inventory, limits: limits, options: options(nodes: 65, attempts: 1), work: &rejectedWork)
            Issue.record("The non-Hurwitz local modal comparison was accepted")
        } catch NativeSTAConservativeCouplingError.invalidCertificate(let reason) {
            #expect(reason.contains("sparse coordinate candidates exhausted"))
            #expect(reason.contains("transformedCoordinateRow="))
            #expect(!reason.contains("endpoint="))
        }
        var work: UInt64 = 0
        let prepared = try prepare(inventory, limits: limits, options: options(nodes: 65, attempts: 2), work: &work)
        let result = try K().bounds(prepared: prepared, source: driver, sink: nodes[0], edge: .rise,
            sourceSlew: 6e-9...6e-9, work: &work)
        #expect(result.minimumCrossingDerivative > 0)
        #expect((try comparison(prepared)).sourceCertificates != nil)
        #expect(work > rejectedWork)
        var cappedWork: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) {
            try prepare(inventory, limits: .init(maximumPathStates: 200_000,
                maximumPathWorkUnits: max(1, rejectedWork)), options: options(nodes: 65, attempts: 2), work: &cappedWork)
        }
    }

    @Test("whitening weight proposals advance on numeric refusal and preserve a quota failure between proposals")
    func weightPortfolioFailureBoundary() throws {
        typealias N = NativeSTAConservativeNumerics
        typealias S = NativeSTAConservativeSparseNumerics
        let limits = try STAExecutionLimits(maximumPathStates: 10_000)
        let n = N(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: nil)
        let solver = S(numerical: n)
        var constructionWork: UInt64 = 0
        let f = try solver.fromRows([[0: TimingNumericInterval(point: -1), 1: TimingNumericInterval(point: 2)],
                                     [1: TimingNumericInterval(point: -1)]], columns: 2, work: &constructionWork)
        var ones = try n.matrix(2, 1)
        ones[0, 0] = try .init(point: 1); ones[1, 0] = try .init(point: 1)
        // Left-Jacobi BiCG has an exact zero initial pivot for this stable triangular F.
        var firstWork: UInt64 = 0
        #expect(try NativeSTAConservativeWeightDiagnostic.principalWitness(comparison: f, numerical: n, work: &firstWork) == nil)
        #expect(throws: NativeSTAConservativeCandidateNotCertified.self) {
            try solver.approximateSolve(solver.negated(f, work: &firstWork), ones, maximumIterations: 8, work: &firstWork)
        }
        var work: UInt64 = 0
        let certificate = try K().certifiedSparseWeight(comparison: f, ones: ones, monotoneWeight: true,
            maximumIterations: 8, numerical: n, work: &work)
        #expect(certificate.weight[0, 0].lowerBound == 3)
        #expect(certificate.weight[1, 0].lowerBound == 1)
        #expect(certificate.alpha > 0)
        #expect(work > firstWork)
        let cappedLimits = try STAExecutionLimits(maximumPathStates: 10_000, maximumPathWorkUnits: firstWork)
        let capped = N(limits: cappedLimits, budget: .init(maximum: cappedLimits.maximumPathStates), resources: nil)
        var cappedWork: UInt64 = 0
        #expect(throws: STAPathAnalysisError.self) {
            try K().certifiedSparseWeight(comparison: f, ones: ones, monotoneWeight: true,
                maximumIterations: 8, numerical: capped, work: &cappedWork)
        }
    }

    @Test("source restriction is immutable and retains conservative comparison certificates")
    func sourceRestrictionSubset() throws {
        var work: UInt64 = 0
        let broad = K.Source.dynamic(endpoint: driver, sourceIsPort: true, riseSlew: 3e-9...9e-9, fallSlew: 3e-9...9e-9)
        let original = try prepare(onePole(), sources: [broad], work: &work)
        let narrowed = try K().restrictSources(prepared: original, to: [source(driver)], work: &work)
        let old = try comparison(original), next = try comparison(narrowed)
        #expect(next.sourceSlopes[0, 0].upperBound < old.sourceSlopes[0, 0].upperBound)
        #expect(next.voltageError[0, 0].upperBound == old.voltageError[0, 0].upperBound)
        #expect(next.radius[0, 0].upperBound == old.radius[0, 0].upperBound)
        #expect(next.numerics.budget === old.numerics.budget)
        guard case .dynamic(_, _, let oldRise, _) = old.sources[0],
              case .dynamic(_, _, let newRise, _) = next.sources[0] else { Issue.record("Source kind changed"); return }
        #expect(oldRise == 3e-9...9e-9)
        #expect(newRise == 6e-9...6e-9)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try K().bounds(prepared: narrowed, source: driver, sink: sink, edge: .rise, sourceSlew: 3e-9...3e-9, work: &work)
        }
    }

    @Test("source restrictions reject widening, identity, role, kind and constant changes")
    func invalidSourceRestrictions() throws {
        var work: UInt64 = 0
        let broad = K.Source.dynamic(endpoint: driver, sourceIsPort: true, riseSlew: 3e-9...9e-9, fallSlew: 3e-9...9e-9)
        let original = try prepare(onePole(), sources: [broad], work: &work)
        let invalid: [[K.Source]] = [[], [source(sink)],
            [.dynamic(endpoint: driver, sourceIsPort: false, riseSlew: 6e-9...6e-9, fallSlew: 6e-9...6e-9)],
            [.constant(endpoint: driver, voltage: 0)],
            [.dynamic(endpoint: driver, sourceIsPort: true, riseSlew: 2e-9...6e-9, fallSlew: 6e-9...6e-9)],
            [.dynamic(endpoint: driver, sourceIsPort: true, riseSlew: 6e-9...6e-9, fallSlew: 6e-9...1e-8)],
            [.dynamic(endpoint: driver, sourceIsPort: true, riseSlew: .infinity...Double.infinity, fallSlew: 6e-9...6e-9)]]
        for proposed in invalid {
            do {
                _ = try K().restrictSources(prepared: original, to: proposed, work: &work)
                Issue.record("An invalid source restriction was accepted")
            } catch NativeSTAConservativeCouplingError.invalidSourceAuthority { }
        }
        let constant = try prepare(onePole(), sources: [.constant(endpoint: driver, voltage: 0.5)], work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try K().restrictSources(prepared: constant, to: [.constant(endpoint: driver, voltage: 0.75)], work: &work)
        }
        let pair = try prepare(onePole(coupling: 1e-15), sources: [source(driver), source(aggressor)], work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try K().restrictSources(prepared: pair, to: [source(aggressor), source(driver)], work: &work)
        }
        var cappedWork = (try comparison(original)).numerics.limits.maximumPathWorkUnits
        #expect(throws: STAPathAnalysisError.self) {
            try K().restrictSources(prepared: original, to: [source(driver)], work: &cappedWork)
        }
    }

    private func receiverProjectionFixture() -> (inventory: TimingParasitics, nodes: [E], alias: E, loads: [E: Double]) {
        let nodes = [E(name: "clockInput", ownerNet: "n"), E(name: "controlInput", ownerNet: "n"),
                     E(name: "outputPort", ownerNet: "n")]
            + (0..<21).map { E(name: "internal\($0)", ownerNet: "n") }
        let alias = E(name: "idealOutputAlias", ownerNet: "n")
        var caps = nodes.enumerated().map {
            TimingParasitics.CapacitanceRecord(source: id(UInt64($0.offset + 1)), first: $0.element, capacitance: 1e-14)
        }
        caps.append(.init(source: id(100), first: nodes[3], second: nodes[2], capacitance: 1e-16))
        var resistors = nodes.enumerated().map {
            TimingParasitics.ResistanceRecord(source: id(UInt64($0.offset + 1)), first: driver, second: $0.element, resistance: 100)
        }
        resistors.append(.init(source: id(100), first: driver, second: alias, resistance: 0))
        let inventory = TimingParasitics(networks: [.init(name: "n", capacitances: caps,
            resistances: resistors, connections: [driver, alias] + nodes)])
        return (inventory, nodes, alias, [nodes[0]: 0, nodes[1]: 1e-15, nodes[2]: 0, alias: 0])
    }

    @Test("residual projection retains every declared receiver and no internal connection row")
    func receiverProjectionAdmission() throws {
        let fixture = receiverProjectionFixture()
        var work: UInt64 = 0
        let model = try comparison(prepare(fixture.inventory, receiverLoads: fixture.loads, work: &work))
        #expect(model.endpointRows.count == fixture.nodes.count)
        #expect(model.operatorA.rows == fixture.nodes.count)
        #expect(model.parasitics.networks[0].capacitances.count == fixture.nodes.count + 1)
        #expect(model.endpointRows[fixture.alias] == nil)
        let limits = try STAExecutionLimits(maximumPathStates: 6)
        let n = NativeSTAConservativeNumerics(limits: limits, budget: .init(maximum: 6), resources: nil)
        let rows = try K().residualReceiverRows(receiverLoads: fixture.loads,
            endpointRows: model.endpointRows, numerical: n, work: &work)
        let expected = try fixture.nodes.prefix(3).map { try #require(model.endpointRows[$0]) }.sorted()
        #expect(rows == expected)
        #expect(rows.count == 3)
        // The actual fine grid needs at least 404 segments; only receiver-sized traces are retained.
        let projectionSlots = 404 * 4 * rows.count * 2
        #expect(projectionSlots == 9_696)
        #expect(projectionSlots < 10_000)
        #expect(404 * 4 * fixture.nodes.count * 2 > 10_000)
    }

    @Test("physical residual projection preserves all internal states and refuses an untraced sink")
    func receiverProjectionPhysicalResponse() throws {
        #if os(macOS)
        if #available(macOS 27, *) {
            let fixture = receiverProjectionFixture()
            var work: UInt64 = 0
            let model = try comparison(prepare(fixture.inventory, receiverLoads: fixture.loads, work: &work))
            let limits = try STAExecutionLimits(maximumPathStates: 16_000_000, maximumPathWorkUnits: 100_000_000)
            let n = NativeSTAConservativeNumerics(limits: limits, budget: .init(maximum: limits.maximumPathStates), resources: nil)
            let endpoints = [driver, fixture.alias] + fixture.nodes
            let index = Dictionary(uniqueKeysWithValues: endpoints.enumerated().map { ($0.element, $0.offset) })
            var ideal = Array(endpoints.indices); ideal[1] = 0
            var incidence = try n.matrix(fixture.nodes.count, 1)
            for row in fixture.nodes.indices { incidence[row, 0] = try .init(point: 1) }
            let reduced = try NativeSTAConservativeSparseGraph(numerical: n).reduce(parasitics: fixture.inventory,
                originalIndex: index, ideal: ideal, idealSource: [0: 0], rows: model.endpointRows,
                sourceIndex: [driver: 0], receiverLoads: fixture.loads, skipped: [], dcIncidence: incidence, work: &work)
            let rows = try K().residualReceiverRows(receiverLoads: fixture.loads,
                endpointRows: model.endpointRows, numerical: n, work: &work)
            #expect(reduced.dynamicRows.count == fixture.nodes.count)
            #expect(reduced.capacitance.rows == fixture.nodes.count)
            #expect(reduced.reconstruction.rows == fixture.nodes.count)
            #expect(reduced.capBlocks.contains { $0.count == 2 })
            var times = [0.0], time = 1e-12 / 16
            while time < 48e-12 { times.append(time); time *= 1.125 }
            times.append(48e-12)
            let checked = try NativeSTAConservativeResidualCertificate(numerical: n)
                .prepare(reduced, receiverRows: rows, times: times, work: &work)
            let retainedSlots = checked.segments.reduce(0) { total, segment in
                total + segment.bernstein.reduce(0) { $0 + $1.values.count }
            }
            #expect(retainedSlots == (times.count - 1) * 4 * rows.count * 2)
            #expect(checked.segments.allSatisfy { $0.bernstein.allSatisfy { $0.rows == 3 && $0.columns == 2 } })
            let facts = try NativeSTAConservativeResidualResponse(numerical: n).prepare(checked, work: &work)
            let prepared = K.Prepared.residual(.init(parasitics: fixture.inventory, sources: model.sources,
                receiverLoads: fixture.loads, endpointRows: model.endpointRows, endpointSource: model.endpointSource,
                sourceIndices: model.sourceIndices, sourceSlopes: model.sourceSlopes, dcIncidence: reduced.dcIncidence,
                thresholds: thresholds, options: model.options, numerics: n, facts: facts))
            let output = try K().bounds(prepared: prepared, source: driver, sink: fixture.nodes[2], edge: .rise,
                sourceSlew: 6e-9...6e-9, work: &work)
            #expect(output.minimumCrossingDerivative > 0)
            let alias = try K().bounds(prepared: prepared, source: driver, sink: fixture.alias, edge: .rise,
                sourceSlew: 6e-9...6e-9, work: &work)
            #expect(alias.voltageErrorUpperBound == 0)
            #expect(alias.slew == 6e-9...6e-9)
            do {
                _ = try K().bounds(prepared: prepared, source: driver, sink: fixture.nodes[3], edge: .rise,
                    sourceSlew: 6e-9...6e-9, work: &work)
                Issue.record("An untraced internal sink returned a completed bound")
            } catch NativeSTAConservativeCouplingError.invalidCertificate(let reason) {
                #expect(reason == "requested physical receiver was not certified")
            }
        }
        #endif
    }

    @Test("request cancellation remains cancellation")
    func cancellation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var work: UInt64 = 0
            return try prepare(onePole(), work: &work)
        }
        do { _ = try await task.value; Issue.record("Cancelled preparation returned a certificate") }
        catch is CancellationError { }
    }
}

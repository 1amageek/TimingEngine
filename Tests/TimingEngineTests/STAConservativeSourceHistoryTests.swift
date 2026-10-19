import Foundation
import Testing
@testable import TimingCore
@testable import STAEngine

@Suite("Staged source history certificates")
struct STAConservativeSourceHistoryTests {
    private typealias N = NativeSTAConservativeNumerics
    private typealias I = TimingNumericInterval
    private typealias C = NativeSTAConservativeResidualCertificate
    private typealias R = NativeSTAConservativeResidualResponse
    private typealias K = NativeSTAConservativeCoupling
    private typealias H = NativeSTAConservativeSourceHistory
    private typealias E = TimingParasitics.Endpoint

    private let own = E(name: "own", ownerNet: "victim")
    private let aggressor = E(name: "other", ownerNet: "aggressor")
    private let sink = E(name: "receiver", ownerNet: "victim")
    private let thresholds = TimingCharacterizationThresholds(inputRise: 50, inputFall: 50,
        outputRise: 50, outputFall: 50, slewLowerRise: 20, slewUpperRise: 80,
        slewLowerFall: 20, slewUpperFall: 80)

    private func numerical(states: Int = 100_000, work: UInt64 = 1_000_000,
        resources: (any LibertySourceResourceAccounting)? = nil) throws -> N {
        N(limits: try .init(maximumPathStates: states, maximumPathWorkUnits: work),
          budget: .init(maximum: states), resources: resources)
    }

    /// Independent polynomial receipts isolate response composition, whose checker is tested separately.
    /// Every cross-source h below has zero signed integral and zero direct/DC incidence.
    private func fixture(pieces: [(end: Double, h: Double)] = [(1, 1), (2, -1)],
        riseSlew: ClosedRange<Double> = 0.6...0.6,
        fallSlew: ClosedRange<Double> = 0.6...0.6, error: Double = 0,
        work: inout UInt64) throws -> K.ResidualPrepared {
        let n = try numerical()
        var segments: [C.Segment] = [], start = 0.0
        for piece in pieces {
            var coefficients: [N.Matrix] = []
            for _ in 0..<4 {
                var coefficient = try n.matrix(1, 4)
                coefficient[0, 3] = try I(point: piece.h)
                coefficients.append(coefficient)
            }
            segments.append(.init(start: start, end: piece.end, bernstein: coefficients))
            start = piece.end
        }
        var errors = try n.matrix(1, 4)
        errors[0, 3] = try I(point: error / 4)
        var direct = try n.matrix(1, 2)
        direct[0, 0] = try I(point: 1)
        let checked = C.Facts(receiverRows: [0], sourceCount: 2, segments: segments,
            errors: .init(initial: errors, solve: errors, interpolation: errors, tail: errors), direct: direct)
        let facts = try R(numerical: n).prepare(checked, work: &work)
        var slopes = try n.matrix(2, 1)
        slopes[0, 0] = try I(point: 0.6).divided(by: I(point: 0.6))
        let sr = try K().thresholdSpan(thresholds, rising: true).divided(by: I(point: riseSlew.lowerBound))
        let sf = try K().thresholdSpan(thresholds, rising: false).divided(by: I(point: fallSlew.lowerBound))
        slopes[1, 0] = try I(point: max(sr.upperBound, sf.upperBound))
        let incidence = try NativeSTAConservativeSparseNumerics(numerical: n)
            .fromRows([[0: I(point: 1)]], columns: 2, work: &work)
        return K.ResidualPrepared(parasitics: TimingParasitics(networks: []), sources: [
            .dynamic(endpoint: own, sourceIsPort: true, riseSlew: 0.6...0.6, fallSlew: 0.6...0.6),
            .dynamic(endpoint: aggressor, sourceIsPort: false, riseSlew: riseSlew, fallSlew: fallSlew)
        ], receiverLoads: [:], endpointRows: [sink: 0], endpointSource: [own: 0, sink: 0, aggressor: 1],
            sourceIndices: [own: 0, aggressor: 1], sourceSlopes: slopes, dcIncidence: incidence,
            thresholds: thresholds, options: try .init(maximumNodes: 3, maximumBasisSweeps: 8,
                maximumCertificateAttempts: 8, operatingHistory: .boundedOperatingHistory),
            numerics: n, facts: facts)
    }

    private func clock(root: String = "root", period: Double = 20.2,
        rise: ClosedRange<Double> = 5...5, fall: ClosedRange<Double> = 15.1...15.1) -> H.Clock {
        .init(rootIdentity: root, period: period, riseReference: rise, fallReference: fall)
    }

    private func adding(_ prepared: K.ResidualPrepared, _ histories: [E: H],
        work: inout UInt64) throws -> K.ResidualPrepared {
        let result = try K().addingSourceHistory(prepared: .residual(prepared), histories: histories, work: &work)
        guard case .residual(let value) = result else {
            throw NativeSTAConservativeCouplingError.invalidPrimitive("history changed the residual backend")
        }
        return value
    }

    private func replacingNumerics(_ prepared: K.ResidualPrepared, with n: N) -> K.ResidualPrepared {
        .init(parasitics: prepared.parasitics, sources: prepared.sources, receiverLoads: prepared.receiverLoads,
            endpointRows: prepared.endpointRows, endpointSource: prepared.endpointSource,
            sourceIndices: prepared.sourceIndices, sourceSlopes: prepared.sourceSlopes,
            dcIncidence: prepared.dcIncidence, thresholds: prepared.thresholds, options: prepared.options,
            numerics: n, facts: prepared.facts, sourceHistories: prepared.sourceHistories)
    }

    private func radius(_ prepared: K.ResidualPrepared, queryClock: H.Clock? = nil,
        band: ClosedRange<Double>? = nil, work: inout UInt64) throws -> Double {
        let interval: I?
        if let band { interval = try I(band) } else { interval = nil }
        return try R(numerical: prepared.numerics).aggressorDerivativeBound(prepared: prepared,
            receiver: 0, source: 1, queryClock: queryClock, queryBand: interval, work: &work).upperBound
    }

    @Test("cross-DC centering uses the average of directional slope limits")
    func directionalCentering() throws {
        var work: UInt64 = 0
        let prepared = try fixture(riseSlew: 0.3...0.3, fallSlew: 1.2...1.2, error: 0.1, work: &work)
        // Sr=2, Sf=1/2, integral |h|=2 and total defect=1/10: radius=21/8.
        let bound = try radius(prepared, work: &work)
        #expect(bound >= 2.625)
        #expect(bound < 2.62500000001)
        #expect(bound < 2 * prepared.facts.hL1[0, 1].upperBound)
        #expect(prepared.dcIncidence.columnIndices == [0])
    }

    @Test("one-event oscillation retains all defects exactly once, including arbitrary phase")
    func plateauOscillation() throws {
        var work: UInt64 = 0
        let original = try fixture(pieces: [(1, 1), (2, -1), (3, 1), (4, -1)], error: 0.25, work: &work)
        let prepared = try adding(original, [aggressor: .minimumPlateau(seconds: 4)], work: &work)
        // Signed primitive repeatedly visits 0 and 1. Its oscillation is 1, not total variation 4.
        let bound = try radius(prepared, work: &work)
        #expect(bound >= 1.25)
        #expect(bound < 1.25000000001)
        #expect(original.facts.hL1[0, 1].upperBound >= 4.25)
        #expect(prepared.facts.hError[0, 1].upperBound >= 0.25)
        #expect(prepared.sourceHistories[own] == nil)
        #expect(original.sourceHistories.isEmpty)
    }

    @Test("a plateau even slightly shorter than the horizon preserves the unconditional radius")
    func insufficientPlateau() throws {
        var work: UInt64 = 0
        let original = try fixture(pieces: [(1, 1), (2, -1), (3, 1), (4, -1)], error: 0.25, work: &work)
        let prepared = try adding(original, [aggressor: .minimumPlateau(seconds: 4.0.nextDown)], work: &work)
        let unconditional = try radius(original, work: &work)
        #expect(try radius(prepared, work: &work) == unconditional)
    }

    @Test("a known ongoing ramp retains the complete infinite-history error beyond the horizon")
    func knownSegmentTail() throws {
        var work: UInt64 = 0
        let original = try fixture(pieces: [(0.1, 1), (0.2, -1), (2, 0)],
            riseSlew: 6...6, fallSlew: 6...6, error: 0.01, work: &work)
        let ownClock = clock(), prepared = try adding(original, [aggressor: .clock(ownClock)], work: &work)
        // Ramp start=0,end=10. The band is strictly inside; delta=3 exceeds T=2.
        // (Smax + Sr) * full hError = (1/10 + 1/10) * 1/100.
        let bound = try radius(prepared, queryClock: ownClock, band: 3...4, work: &work)
        #expect(bound >= 0.002)
        #expect(bound < 0.002000000001)
        #expect(bound < (try radius(original, work: &work)))
        // The short inter-ramp plateaus do not independently qualify for the one-event gain.
        #expect(try radius(prepared, work: &work) == radius(original, work: &work))
    }

    @Test("missing or mismatched roots and periods cannot select a favorable phase")
    func unknownPhaseFallback() throws {
        var work: UInt64 = 0
        let original = try fixture(pieces: [(0.1, 1), (0.2, -1), (2, 0)],
            riseSlew: 6...6, fallSlew: 6...6, error: 0.01, work: &work)
        let prepared = try adding(original, [aggressor: .clock(clock())], work: &work)
        let unconditional = try radius(original, work: &work)
        #expect(try radius(prepared, band: 3...4, work: &work) == unconditional)
        #expect(try radius(prepared, queryClock: clock(root: "unrelated"), band: 3...4, work: &work) == unconditional)
        #expect(try radius(prepared, queryClock: clock(period: 20.3), band: 3...4, work: &work) == unconditional)
    }

    @Test("the complete 20–80 crossing band must be contained, even when 50 percent is inside")
    func wholeBandContainment() throws {
        var work: UInt64 = 0
        let original = try fixture(pieces: [(0.025, 1), (0.05, -1), (2, 0)],
            riseSlew: 6...6, fallSlew: 6...6, work: &work)
        let ownClock = clock(rise: 0.5...0.5, fall: 10.6...10.6)
        let otherClock = clock(rise: 5.4...5.4, fall: 15.5...15.5)
        let prepared = try adding(original, [own: .clock(ownClock), aggressor: .clock(otherClock)], work: &work)
        // The aggressor starts at .4: the 50% crossing .5 is inside, but lower crossing .2 is outside.
        let favorablePoint = try radius(prepared, queryClock: ownClock, band: 0.5...0.5, work: &work)
        let whole = try radius(prepared, queryClock: ownClock, band: 0.2...0.8, work: &work)
        #expect(favorablePoint < 1e-12)
        #expect(whole > 0.0049)
        for edge in [TimingEdge.rise, .fall] {
            let unknown = try K().bounds(prepared: .residual(original), source: own, sink: sink,
                edge: edge, sourceSlew: 0.6...0.6, work: &work)
            let conditional = try K().bounds(prepared: .residual(prepared), source: own, sink: sink,
                edge: edge, sourceSlew: 0.6...0.6, work: &work)
            #expect(conditional.minimumCrossingDerivative == unknown.minimumCrossingDerivative)
        }
    }

    @Test("translating every reference by a common root phase preserves conditional bounds")
    func arbitraryGlobalPhase() throws {
        var work: UInt64 = 0
        let original = try fixture(pieces: [(0.1, 1), (0.2, -1), (2, 0)],
            riseSlew: 6...6, fallSlew: 6...6, error: 0.01, work: &work)
        let base = clock(), shifted = clock(rise: 105...105, fall: 115.1...115.1)
        let first = try adding(original, [aggressor: .clock(base)], work: &work)
        let second = try adding(original, [aggressor: .clock(shifted)], work: &work)
        let a = try radius(first, queryClock: base, band: 3...4, work: &work)
        let b = try radius(second, queryClock: shifted, band: 103...104, work: &work)
        #expect(abs(a - b) < 1e-12)
    }

    @Test("history publication rejects unknown endpoints, malformed clocks and inconsistent roots")
    func publicationAdmission() throws {
        var work: UInt64 = 0
        let prepared = try fixture(work: &work)
        let unknown = E(name: "other", ownerNet: "wrong-net")
        let invalid: [[E: H]] = [
            [unknown: .minimumPlateau(seconds: 2)], [sink: .minimumPlateau(seconds: 2)],
            [aggressor: .minimumPlateau(seconds: 0)], [aggressor: .minimumPlateau(seconds: .infinity)],
            [aggressor: .clock(clock(root: ""))], [aggressor: .clock(clock(period: 0))],
            [aggressor: .clock(clock(rise: 0...Double.infinity))],
            [aggressor: .clock(clock(period: 1, rise: 0...0, fall: 0.5...0.5))],
            [own: .clock(clock(period: 20)), aggressor: .clock(clock(period: 21))]
        ]
        for entry in invalid {
            #expect(throws: NativeSTAConservativeCouplingError.self) {
                try adding(prepared, entry, work: &work)
            }
        }
        #expect(prepared.sourceHistories.isEmpty)
    }

    @Test("only monotone history refinements are admitted and source restriction retains them")
    func refinementMonotonicity() throws {
        var work: UInt64 = 0
        let original = try fixture(riseSlew: 0.6...0.9, fallSlew: 0.6...0.9, work: &work)
        let broad = clock(period: 20, rise: 5...5.1, fall: 15...15.1)
        let narrow = clock(period: 20, rise: 5.02...5.08, fall: 15.02...15.08)
        let first = try adding(original, [aggressor: .clock(broad)], work: &work)
        let refined = try adding(first, [aggressor: .clock(narrow)], work: &work)
        #expect(refined.sourceHistories[aggressor] == .clock(narrow))
        for history in [H.clock(broad), .clock(clock(root: "replacement", period: 20)), .minimumPlateau(seconds: 3)] {
            #expect(throws: NativeSTAConservativeCouplingError.self) {
                try adding(refined, [aggressor: history], work: &work)
            }
        }
        let plateau = try adding(original, [aggressor: .minimumPlateau(seconds: 2)], work: &work)
        let stronger = try adding(plateau, [aggressor: .minimumPlateau(seconds: 3)], work: &work)
        #expect(throws: NativeSTAConservativeCouplingError.self) {
            try adding(stronger, [aggressor: .minimumPlateau(seconds: 2)], work: &work)
        }
        let restricted = try K().restrictSources(prepared: .residual(refined), to: [original.sources[0],
            .dynamic(endpoint: aggressor, sourceIsPort: false, riseSlew: 0.7...0.8, fallSlew: 0.7...0.8)], work: &work)
        guard case .residual(let retained) = restricted else { Issue.record("Restriction changed backend"); return }
        #expect(retained.sourceHistories == refined.sourceHistories)
        #expect(retained.facts.hL1.values == refined.facts.hL1.values)
    }

    private struct RefusingOwner: LibertySourceResourceAccounting {
        enum Failure: Error, Equatable { case refused }
        func check() throws { throw Failure.refused }
        func chargeWork(_ amount: UInt64) throws { throw Failure.refused }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            throw Failure.refused
        }
    }

    @Test("publication and conditional gains retain the request work, storage and source owner")
    func resourceBoundaries() throws {
        var setupWork: UInt64 = 0
        let original = try fixture(work: &setupWork)
        let exhausted = replacingNumerics(original, with: try numerical(work: 1))
        var work: UInt64 = 1
        #expect(throws: STAPathAnalysisError.self) {
            try adding(exhausted, [aggressor: .minimumPlateau(seconds: 2)], work: &work)
        }
        #expect(work == 1)
        let noStorage = replacingNumerics(original, with: try numerical(states: 1))
        work = 0
        #expect(throws: STAPathAnalysisError.self) {
            try adding(noStorage, [aggressor: .minimumPlateau(seconds: 2)], work: &work)
        }
        let refused = replacingNumerics(original, with: try numerical(resources: RefusingOwner()))
        work = 0
        #expect(throws: RefusingOwner.Failure.refused) {
            try adding(refused, [aggressor: .minimumPlateau(seconds: 2)], work: &work)
        }
        #expect(throws: RefusingOwner.Failure.refused) { try radius(refused, work: &work) }
        #expect(original.sourceHistories.isEmpty)
    }

    @Test("cancelled publication and gain evaluation cannot produce a conditional result", .timeLimit(.minutes(1)))
    func cancellationBoundary() async throws {
        var work: UInt64 = 0
        let prepared = try fixture(work: &work)
        let publication = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var localWork: UInt64 = 0
            _ = try adding(prepared, [aggressor: .minimumPlateau(seconds: 2)], work: &localWork)
        }
        do { try await publication.value; Issue.record("Cancelled history publication succeeded") }
        catch is CancellationError { }
        let evaluation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var localWork: UInt64 = 0
            _ = try radius(prepared, work: &localWork)
        }
        do { try await evaluation.value; Issue.record("Cancelled history evaluation succeeded") }
        catch is CancellationError { }
    }

    #if os(macOS)
    @Test("physical coupled RC checker facts remain the authority after history publication", .timeLimit(.minutes(1)))
    func physicalResidualHistory() throws {
        let n = try numerical(states: 16_000_000, work: 1_000_000_000)
        var work: UInt64 = 0
        let otherSink = E(name: "other-receiver", ownerNet: "aggressor")
        func id(_ ordinal: Int) -> TimingParasitics.SourceID {
            .init(declaringNet: "history-physical", identifier: UInt64(ordinal), line: ordinal + 1)
        }
        let inventory = TimingParasitics(networks: [
            .init(name: "victim", capacitances: [
                .init(source: id(0), first: sink, capacitance: 1e-14),
                .init(source: id(1), first: sink, second: otherSink, capacitance: 1e-15)
            ], resistances: [.init(source: id(2), first: own, second: sink, resistance: 100)],
                connections: [own, sink]),
            .init(name: "aggressor", capacitances: [.init(source: id(3), first: otherSink, capacitance: 1e-14)],
                resistances: [.init(source: id(4), first: aggressor, second: otherSink, resistance: 100)],
                connections: [aggressor, otherSink])
        ])
        let incidence = try n.identity(2, work: &work)
        let reduced = try NativeSTAConservativeSparseGraph(numerical: n).reduce(parasitics: inventory,
            originalIndex: [own: 0, sink: 1, aggressor: 2, otherSink: 3], ideal: [0, 1, 2, 3],
            idealSource: [0: 0, 2: 1], rows: [sink: 0, otherSink: 1], sourceIndex: [own: 0, aggressor: 1],
            receiverLoads: [:], skipped: [], dcIncidence: incidence, work: &work)
        var times = [0.0], time = 1e-12 / 16
        while time < 48e-12 { times.append(time); time *= 1.125 }
        times.append(48e-12)
        let checked = try C(numerical: n).prepare(reduced, receiverRows: [0], times: times, work: &work)
        let facts = try R(numerical: n).prepare(checked, work: &work)
        #expect(facts.hL1[0, 1].upperBound > 0)
        var slopes = try n.matrix(2, 1)
        let slope = try K().thresholdSpan(thresholds, rising: true).divided(by: I(point: 0.6))
        slopes[0, 0] = slope; slopes[1, 0] = slope
        let original = K.ResidualPrepared(parasitics: inventory, sources: [
            .dynamic(endpoint: own, sourceIsPort: true, riseSlew: 0.6...0.6, fallSlew: 0.6...0.6),
            .dynamic(endpoint: aggressor, sourceIsPort: false, riseSlew: 0.6...0.6, fallSlew: 0.6...0.6)
        ], receiverLoads: [:], endpointRows: [sink: 0, otherSink: 1],
            endpointSource: [own: 0, sink: 0, aggressor: 1, otherSink: 1], sourceIndices: [own: 0, aggressor: 1],
            sourceSlopes: slopes, dcIncidence: reduced.dcIncidence, thresholds: thresholds,
            options: try .init(maximumNodes: 4, maximumBasisSweeps: 8, maximumCertificateAttempts: 8,
                operatingHistory: .boundedOperatingHistory), numerics: n, facts: facts)
        let conditional = try adding(original, [aggressor: .minimumPlateau(seconds: 48e-12)], work: &work)
        #expect(conditional.facts.hError.values == facts.hError.values)
        #expect(try radius(conditional, work: &work) <= radius(original, work: &work))
        for edge in [TimingEdge.rise, .fall] {
            let unknown = try K().bounds(prepared: .residual(original), source: own, sink: sink,
                edge: edge, sourceSlew: 0.6...0.6, work: &work)
            let bound = try K().bounds(prepared: .residual(conditional), source: own, sink: sink,
                edge: edge, sourceSlew: 0.6...0.6, work: &work)
            #expect(bound.minimumCrossingDerivative > 0)
            #expect(bound.minimumCrossingDerivative >= unknown.minimumCrossingDerivative)
            #expect(bound.voltageErrorUpperBound == unknown.voltageErrorUpperBound)
            #expect(bound.admittedSourceSlew == 0.6...0.6)
        }
    }
    #endif
}

import Foundation
import Synchronization
import Testing
import TimingCore
@testable import STAEngine

@Suite("Joint projections of one checked normalized source family", .timeLimit(.minutes(1)))
struct STAConservativeSourceJointSliceTests {
    private func prepared(resources: Resources) async throws -> (NativeSTAEngine, PreparedSTAExecution) {
        let fixture = try STAPropagatedClockFixture(
            sdc: STAPropagatedClockFixture.sdc + "\nset_output_delay 0ns -clock clk [get_ports out]",
            spef: STAPropagatedClockFixture.spef
                .replacingOccurrences(of: "1000", with: "1").replacingOccurrences(of: "1500", with: "1.5"))
        let r = fixture.request
        let request = try STARequest(runID: r.runID, design: r.design, topDesignName: r.topDesignName,
            canonicalDesignDigest: r.canonicalDesignDigest, libraries: r.libraries, constraints: r.constraints,
            requestedModeIDs: r.requestedModeIDs, requestedCornerIDs: r.requestedCornerIDs, pdkManifest: r.pdkManifest,
            processID: r.processID, pdkVersion: r.pdkVersion, pdkDigest: r.pdkDigest, parasitics: r.parasitics,
            analysisKinds: r.analysisKinds, maxPaths: r.maxPaths, requiresPostLayoutInputs: r.requiresPostLayoutInputs,
            variation: r.variation, characterizationPolicy: r.characterizationPolicy,
            characterizationBindings: r.characterizationBindings,
            conservativeCoupledRC: .init(maximumNodes: 64, maximumBasisSweeps: 32,
                maximumCertificateAttempts: 16, operatingHistory: .boundedOperatingHistory),
            requireStrictSourceEvidence: true, operatingSupplyAssumptions: r.operatingSupplyAssumptions,
            controlPulseSources: r.controlPulseSources)
        let engine = NativeSTAEngine(reader: fixture.reader)
        let owner = try await engine.prepare(request, resources: .init(reader: fixture.reader,
            sourceLimits: .init(maximumNestingDepth: 64), sourceResources: resources, limits: .init()))
        return (engine, owner)
    }

    private func actual(resources: Resources = Resources()) async throws -> STAConservativeSourceContext {
        let (engine, owner) = try await prepared(resources: resources)
        return try #require(engine.initialSourceContexts(owner).first)
    }

    // Analytic normalized-family fixtures, not independent physical-source certificates.
    private func analytic(_ identity: STAConservativeSourceContextRecord, resources: Resources,
        rise: ClosedRange<Double> = 0.6...0.6, fall: ClosedRange<Double> = 0.6...0.6,
        phase: ClosedRange<Double> = 0.5...0.5, period: Double = 10,
        maximumWork: UInt64 = 1_000_000) throws -> STAConservativeSourceContext {
        let thresholds = TimingCharacterizationThresholds(inputRise: 50, inputFall: 50,
            outputRise: 50, outputFall: 50, slewLowerRise: 20, slewUpperRise: 80,
            slewLowerFall: 20, slewUpperFall: 80)
        let clock = STAConservativeSourceAuthority(endpoint: .init(name: "root", ownerNet: "n"),
            sourceIsPort: true, constantVoltage: nil, riseSlew: rise, fallSlew: fall,
            sourceArcs: [], prescribedBoundaryLoad: nil)
        let ac = STAConservativeSourceAuthority(endpoint: .init(name: "ac", ownerNet: "a"),
            sourceIsPort: true, constantVoltage: nil, riseSlew: rise, fallSlew: fall,
            sourceArcs: [], prescribedBoundaryLoad: nil)
        let constant = STAConservativeSourceAuthority(endpoint: .init(name: "constant", ownerNet: "c"),
            sourceIsPort: true, constantVoltage: 0.25, riseSlew: nil, fallSlew: nil,
            sourceArcs: [], prescribedBoundaryLoad: nil)
        let fallPhase = (phase.lowerBound + 5)...(phase.upperBound + 5)
        let record = try STAConservativeSourceContextRecord(input: identity.executionInputIdentity,
            configuration: identity.configurationDigest, library: identity.library,
            mode: identity.modeID, corner: identity.cornerID, thresholds: thresholds, sources: [
                .init(authority: clock, origin: .primaryPort, history: .clock(.init(rootIdentity: "r",
                    period: period, riseReference: phase, fallReference: fallPhase))),
                .init(authority: ac, origin: .primaryPort, history: .unrestricted),
                .init(authority: constant, origin: .primaryPort, history: .unrestricted)])
        try record.validate(checkpoint: {})
        let control = try NativeSTAInitialSourceControl(limits: .init(maximumPathWorkUnits: maximumWork),
            resources: resources, contextCount: 1)
        let lease = try control.reserve(bytes: 1, slots: 1)
        try control.finishBuilder(work: 0)
        return STAConservativeSourceContext(record: record, control: control, lease: lease)
    }

    @Test func actualPreparedSliceRetainsCompleteFamilyAndIdentity() async throws {
        let context = try await actual()
        let clock = try #require(context.record.sources.firstIndex { if case .clock = $0.history { return true }; return false })
        guard case .clock(let history) = context.record.sources[clock].history else { return }
        let start = history.riseReference.lowerBound - history.period
        let slice = try context.jointSlice(sourceAt: clock, initialTime: start...start,
            over: start...(start + history.period))
        #expect(slice.contextRecord == context.record && slice.sourceIndex == clock)
        #expect(slice.contextRecord.stage == .initialRoots && slice.contextRecord.historyGeneration == 0)
        #expect(slice.windowValue == 0...1 && slice.almostEverywhereSlope.contains(0))
        #expect(slice.initialValue.contains(context.record.thresholds.inputRise / 100))
        let internalSource = try #require(context.record.sources.firstIndex { $0.origin == .prescribedCellOutput })
        let assumed = try context.jointSlice(sourceAt: internalSource, initialTime: 0...0, over: -1...1)
        #expect(assumed.contextRecord.sources[internalSource].origin == .prescribedCellOutput)
        #expect(assumed.contextRecord.sources[internalSource].history == .unrestricted)
    }

    @Test func constantAndAllACRemainNonemptyWithoutIndependentJets() async throws {
        let context = try analytic(try await actual().record, resources: Resources())
        let fixed = try context.jointSlice(sourceAt: 2, initialTime: -10 ... -9, over: -100...100)
        #expect(fixed.initialValue == 0.25...0.25 && fixed.windowValue == 0.25...0.25)
        #expect(fixed.almostEverywhereSlope == 0...0)
        let all = try context.jointSlice(sourceAt: 1, initialTime: 0...0, over: -100...100)
        #expect(all.initialValue == 0...1 && all.windowValue == 0...1)
        #expect(all.almostEverywhereSlope.contains(-1) && all.almostEverywhereSlope.contains(1))
        #expect(all.almostEverywhereSlope.contains(0))
        #expect(all.contextRecord.sources[1].history == .unrestricted)
        // Constant members witness nonemptiness; this does not restrict the full AC family.
        for witness in [0.0, 0.25, 1.0] {
            #expect(all.initialValue.contains(witness) && all.windowValue.contains(witness))
        }
    }

    @Test func clockSlicesPreserveNegativeCyclesCornersAndWholePeriods() async throws {
        let context = try analytic(try await actual().record, resources: Resources())
        for cycle in [-3, -1, 0, 2] {
            let shift = Double(cycle) * 10
            let slab = try context.jointSlice(sourceAt: 0, initialTime: shift...shift,
                over: (shift - 0.25)...(shift + 0.5))
            #expect(slab.initialValue.contains(0))
            #expect(slab.windowValue.contains(0) && slab.windowValue.contains(0.5))
            #expect(slab.almostEverywhereSlope.contains(0) && slab.almostEverywhereSlope.contains(1))
            let high = try context.jointSlice(sourceAt: 0, initialTime: (shift + 2)...(shift + 2),
                over: (shift + 2)...(shift + 3))
            #expect(high.windowValue == 1...1 && high.almostEverywhereSlope == 0...0)
        }
        let whole = try context.jointSlice(sourceAt: 0, initialTime: -20 ... -20, over: -20...0)
        #expect(whole.windowValue == 0...1)
        #expect(whole.almostEverywhereSlope.contains(-1) && whole.almostEverywhereSlope.contains(1))
    }

    @Test func intervalPhaseAndSlewChoicesRemainOuterProjections() async throws {
        let identity = try await actual().record
        let context = try analytic(identity, resources: Resources(), rise: 0.3...0.6,
            fall: 0.3...0.6, phase: 0.5...1.5)
        let slice = try context.jointSlice(sourceAt: 0, initialTime: -9.5 ... -8.5, over: -10 ... -8)
        #expect(slice.initialValue.contains(0.5))
        #expect(slice.windowValue.contains(0) && slice.windowValue.contains(1))
        #expect(slice.almostEverywhereSlope.contains(1) && slice.almostEverywhereSlope.contains(2))
        #expect(slice.contextRecord.sources[0].authority.riseSlew == 0.3...0.6)
        // Overlapping ramps cannot produce a checked clock family or a joint slice.
        #expect(throws: TimingError.self) {
            try analytic(identity, resources: Resources(), period: 1)
        }
    }

    @Test func timeHullsAndInvalidRequestsPreserveBoundsBeforeAllocation() async throws {
        let resources = Resources()
        let context = try analytic(try await actual().record, resources: resources)
        let t = 10_000_000_000_000_000.0
        let initial = t...t.nextUp, window = t...t.nextUp.nextUp
        let slice = try context.jointSlice(sourceAt: 2, initialTime: initial, over: window)
        #expect(slice.initialTimeSI == initial && slice.windowSI == window)
        let calls = resources.reservations
        for (index, start, slab) in [(-1, 0.0...0.0, 0.0...1.0),
            (3, 0.0...0.0, 0.0...1.0), (1, -1.0...0.0, 0.0...1.0),
            (1, 0.0...2.0, 0.0...1.0), (1, Double.infinity...Double.infinity, 0.0...1.0),
            (1, 0.0...0.0, -Double.infinity...Double.infinity)] {
            #expect(throws: STAExecutionError.self) {
                try context.jointSlice(sourceAt: index, initialTime: start, over: slab)
            }
            #expect(resources.reservations == calls)
        }
        #expect(throws: STAExecutionError.self) {
            try context.jointSlice(sourceAt: 0, initialTime: Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude,
                over: Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude)
        }
    }

    @Test func storageRefusalAndMidQueryCancellationRefundTheResultLease() async throws {
        let resources = Resources()
        let context = try analytic(try await actual().record, resources: resources)
        let baseline = resources.live
        resources.capLiveStorage(at: baseline)
        do {
            _ = try context.jointSlice(sourceAt: 1, initialTime: 0...0, over: 0...1)
            Issue.record("Storage refusal published a slice")
        } catch STAExecutionError.underlying(let error) {
            #expect(error is StorageRefusal)
        }
        #expect(resources.live == baseline)
        resources.capLiveStorage(at: nil)
        resources.cancelAfterAdditionalWork(20)
        do {
            _ = try context.jointSlice(sourceAt: 1, initialTime: 0...0, over: 0...1)
            Issue.record("Mid-query cancellation published a slice")
        } catch STAExecutionError.cancelled {}
        #expect(resources.live == baseline)
        resources.clearCancellation()
        _ = try context.jointSlice(sourceAt: 1, initialTime: 0...0, over: 0...1)
        #expect(resources.live == baseline)
    }

    @Test func copiesUseTheOriginalCumulativeWorkOwner() async throws {
        let resources = Resources()
        let context = try analytic(try await actual().record, resources: resources, maximumWork: 75)
        let copy = context, baseline = resources.live
        _ = try context.jointSlice(sourceAt: 1, initialTime: 0...0, over: 0...1)
        _ = try copy.jointSlice(sourceAt: 1, initialTime: 0...0, over: 0...1)
        #expect(throws: STAExecutionError.self) {
            try copy.jointSlice(sourceAt: 1, initialTime: 0...0, over: 0...1)
        }
        #expect(resources.live == baseline)
    }

    @Test func finalSliceCopyRetainsTheOriginalPreparedContextAndRefunds() async throws {
        let resources = Resources()
        var retained: STAConservativeSourceJointSlice?
        do {
            let context = try await actual(resources: resources)
            let index = try #require(context.record.sources.firstIndex { $0.history == .unrestricted })
            retained = try context.jointSlice(sourceAt: index, initialTime: 0...0, over: 0...1)
        }
        #expect(resources.live > 0)
        var copy = retained
        let live = resources.live
        retained = nil
        #expect(resources.live == live && copy?.contextRecord.stage == .initialRoots)
        copy = nil
        #expect(resources.live == 0)
    }

    private struct StorageRefusal: Error {}
    private final class Resources: LibertySourceResourceAccounting {
        private struct State {
            var live: UInt64 = 0
            var work: UInt64 = 0
            var reservations = 0
            var maximumLive: UInt64?
            var cancelAtWork: UInt64?
        }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        var reservations: Int { state.withLock { $0.reservations } }
        func capLiveStorage(at limit: UInt64?) { state.withLock { $0.maximumLive = limit } }
        func cancelAfterAdditionalWork(_ amount: UInt64) { state.withLock { $0.cancelAtWork = $0.work + amount } }
        func clearCancellation() { state.withLock { $0.cancelAtWork = nil } }
        func check() throws {
            let cancelled = state.withLock { s in s.cancelAtWork.map { s.work >= $0 } ?? false }
            if cancelled { throw CancellationError() }
        }
        func chargeWork(_ amount: UInt64) throws {
            let cancelled = try state.withLock { s in
                let sum = s.work.addingReportingOverflow(amount)
                guard !sum.overflow else { throw LibertySourceError.arithmeticOverflow }
                s.work = sum.partialValue
                return s.cancelAtWork.map { s.work >= $0 } ?? false
            }
            if cancelled { throw CancellationError() }
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            try check()
            try state.withLock { s in
                s.reservations += 1
                let next = s.live.addingReportingOverflow(byteCount)
                guard !next.overflow else { throw LibertySourceError.arithmeticOverflow }
                if let limit = s.maximumLive, next.partialValue > limit { throw StorageRefusal() }
                s.live = next.partialValue
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { $0.live -= byteCount } }
        }
    }
}

import CircuiteFoundation
import Foundation
import Synchronization
import Testing
import TimingCore
@testable import STAEngine

@Suite("Before-response normalized source contexts", .timeLimit(.minutes(1)))
struct STAInitialSourceContextTests {
    private func selecting(_ r: STARequest, nodes: Int = 64) throws -> STARequest {
        try .init(runID: r.runID, design: r.design, topDesignName: r.topDesignName,
            canonicalDesignDigest: r.canonicalDesignDigest, libraries: r.libraries, constraints: r.constraints,
            requestedModeIDs: r.requestedModeIDs, requestedCornerIDs: r.requestedCornerIDs, pdkManifest: r.pdkManifest,
            processID: r.processID, pdkVersion: r.pdkVersion, pdkDigest: r.pdkDigest, parasitics: r.parasitics,
            analysisKinds: r.analysisKinds, maxPaths: r.maxPaths, requiresPostLayoutInputs: r.requiresPostLayoutInputs,
            variation: r.variation, characterizationPolicy: r.characterizationPolicy,
            characterizationBindings: r.characterizationBindings,
            conservativeCoupledRC: .init(maximumNodes: nodes, maximumBasisSweeps: 32,
                maximumCertificateAttempts: 16, operatingHistory: .boundedOperatingHistory),
            requireStrictSourceEvidence: true, operatingSupplyAssumptions: r.operatingSupplyAssumptions,
            controlPulseSources: r.controlPulseSources)
    }
    private func prepared(nodes: Int = 64, resources: any LibertySourceResourceAccounting = STALibertyResources())
        async throws -> (NativeSTAEngine, PreparedSTAExecution) {
        let fixture = try STAPropagatedClockFixture(
            sdc: STAPropagatedClockFixture.sdc + "\nset_output_delay 0ns -clock clk [get_ports out]",
            spef: STAPropagatedClockFixture.spef
            .replacingOccurrences(of: "1000", with: "1").replacingOccurrences(of: "1500", with: "1.5"))
        let engine = NativeSTAEngine(reader: fixture.reader)
        let owner = try await engine.prepare(selecting(fixture.request, nodes: nodes), resources: .init(
            reader: fixture.reader, sourceLimits: .init(maximumNestingDepth: 64), sourceResources: resources,
            limits: .init()))
        return (engine, owner)
    }

    @Test func contextExistsBeforeAResponseThatCannotPrepareItsNodeBudget() async throws {
        let (engine, prepared) = try await prepared(nodes: 1)
        let contexts = try engine.initialSourceContexts(prepared)
        #expect(contexts.count == prepared.request.requestedCornerIDs.count)
        let first = try #require(contexts.first)
        #expect(first.record.stage == .initialRoots && first.record.historyGeneration == 0)
        #expect(first.record.executionInputIdentity == prepared.executionInputIdentity)
        #expect(first.record.configurationDigest == prepared.configurationDigest)
        #expect(first.record.sources.contains { $0.origin == .prescribedCellOutput && $0.history == .unrestricted })
        await #expect(throws: STAExecutionError.self) { try await engine.execute(prepared) }
    }

    @Test func normalProducerKeepsTheSameCompleteInventoryAndPrimaryDomains() async throws {
        let (engine, owner) = try await prepared()
        let context = try #require(engine.initialSourceContexts(owner).first)
        let result = try await engine.execute(owner)
        let observation = try #require(result.payload.conservativeWireObservations.first)
        #expect(context.record.sources.map { $0.authority.endpoint } == observation.sourceAuthorities.map(\.endpoint))
        for entry in context.record.sources where entry.origin == .primaryPort {
            #expect(observation.sourceAuthorities.contains(entry.authority))
        }
        #expect(context.record.sources.filter { $0.origin == .prescribedCellOutput }.allSatisfy { $0.history == .unrestricted })
    }

    @Test func roundTripNeedsExactPreparedReplayAndNeverDefaultsMissingHistory() async throws {
        let (engine, owner) = try await prepared()
        let original = try #require(engine.initialSourceContexts(owner).first)
        let bytes = try JSONEncoder().encode(original.record)
        let decoded = try JSONDecoder().decode(STAConservativeSourceContextRecord.self, from: bytes)
        let replay = try engine.validateInitialSourceContext(decoded, against: owner)
        #expect(replay.record == original.record)
        var raw = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        raw["modeID"] = "foreign"
        let foreign = try JSONDecoder().decode(STAConservativeSourceContextRecord.self,
            from: JSONSerialization.data(withJSONObject: raw))
        #expect(throws: STAExecutionError.self) { try engine.validateInitialSourceContext(foreign, against: owner) }
        raw = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var sources = try #require(raw["sources"] as? [[String: Any]])
        sources[0].removeValue(forKey: "history"); raw["sources"] = sources
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(STAConservativeSourceContextRecord.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        for version in [0, 2] {
            var bad = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); bad["version"] = version
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(STAConservativeSourceContextRecord.self, from: JSONSerialization.data(withJSONObject: bad))
            }
        }
    }

    @Test func rootClockIncludesNegativeCyclesCornersAndEverySlabPhase() async throws {
        let (engine, owner) = try await prepared()
        let context = try #require(engine.initialSourceContexts(owner).first)
        let root = try #require(context.record.sources.firstIndex { if case .clock = $0.history { return true }; return false })
        guard case .clock(let clock) = context.record.sources[root].history else { Issue.record("Missing root"); return }
        let phase = clock.riseReference.lowerBound
        let positive = try context.enclose(sourceAt: root, over: phase...phase)
        let negativeTime = phase - clock.period
        let negative = try context.enclose(sourceAt: root, over: negativeTime...negativeTime)
        let q = context.record.thresholds.inputRise / 100
        #expect(positive.value.contains(q) && negative.value.contains(q))
        #expect(positive.rightSlope.upperBound > 0 && negative.leftSlope.upperBound > 0)
        let entire = try context.enclose(sourceAt: root, over: -clock.period...clock.period)
        #expect(entire.value == 0...1 && entire.leftSlope.lowerBound < 0 && entire.rightSlope.upperBound > 0)
        let unknown = try #require(context.record.sources.firstIndex { $0.origin == .prescribedCellOutput })
        let jet = try context.enclose(sourceAt: unknown, over: -100.0...100.0)
        #expect(jet.value == 0...1 && jet.leftSlope == jet.rightSlope)
        #expect(jet.leftSlope.lowerBound < 0 && jet.rightSlope.upperBound > 0)
        #expect(throws: STAExecutionError.self) { try context.enclose(sourceAt: -1, over: 0...0) }
        #expect(throws: STAExecutionError.self) { try context.enclose(sourceAt: root, over: .infinity...(.infinity)) }
    }

    @Test func outputAdmissionFailureCancellationAndRecordCopiesRetainTheirLease() async throws {
        let resources = Resources()
        let (engine, owner) = try await prepared(resources: resources)
        let before = resources.live
        do {
            let contexts = try engine.initialSourceContexts(owner)
            #expect(resources.live > before)
            let retained = try #require(contexts.first).record
            #expect(retained.sources.count > 0)
        }
        #expect(resources.live == before)
        var record: STAConservativeSourceContextRecord?
        do { record = try #require(engine.initialSourceContexts(owner).first).record }
        #expect(resources.live > before)
        #expect(record?.sources.isEmpty == false)
        record = nil
        #expect(resources.live == before)
        resources.arm(.storage)
        #expect(throws: STAExecutionError.self) { try engine.initialSourceContexts(owner) }
        #expect(resources.live == before)
        resources.arm(.cancel)
        #expect(throws: STAExecutionError.self) { try engine.initialSourceContexts(owner) }
        #expect(resources.live == before)
    }

    @Test func jetCopiesShareTheSameCumulativeWorkCeiling() async throws {
        let (engine, prepared) = try await prepared()
        let actual = try #require(engine.initialSourceContexts(prepared).first)
        let control = try NativeSTAInitialSourceControl(limits: .init(maximumPathWorkUnits: 20),
            resources: Resources(), contextCount: 1)
        let lease = try control.reserve(bytes: 1, slots: 1)
        try control.finishBuilder(work: 0)
        let a = STAConservativeSourceContext(record: actual.record, control: control, lease: lease), b = a
        let index = try #require(a.record.sources.firstIndex { $0.history == .unrestricted && $0.authority.constantVoltage == nil })
        _ = try a.enclose(sourceAt: index, over: 0...0)
        _ = try b.enclose(sourceAt: index, over: 0...0)
        #expect(throws: STAExecutionError.self) { try a.enclose(sourceAt: index, over: 0...0) }
    }

    @Test func analyticClockAndConstantJetsCoverSlabsAndBothCornerLimits() async throws {
        let (engine, owner) = try await prepared()
        let actual = try #require(engine.initialSourceContexts(owner).first).record
        let thresholds = TimingCharacterizationThresholds(inputRise: 50, inputFall: 50,
            outputRise: 50, outputFall: 50, slewLowerRise: 20, slewUpperRise: 80,
            slewLowerFall: 20, slewUpperFall: 80)
        let dynamic = STAConservativeSourceAuthority(endpoint: .init(name: "root", ownerNet: "n"),
            sourceIsPort: true, constantVoltage: nil, riseSlew: 0.6...0.6, fallSlew: 0.6...0.6,
            sourceArcs: [], prescribedBoundaryLoad: nil)
        let constant = STAConservativeSourceAuthority(endpoint: .init(name: "constant", ownerNet: "c"),
            sourceIsPort: true, constantVoltage: 0.25, riseSlew: nil, fallSlew: nil,
            sourceArcs: [], prescribedBoundaryLoad: nil)
        // Analytic normalized-law fixture, not an actual physical source certificate.
        let record = try STAConservativeSourceContextRecord(input: actual.executionInputIdentity,
            configuration: actual.configurationDigest, library: actual.library, mode: actual.modeID,
            corner: actual.cornerID, thresholds: thresholds, sources: [
                .init(authority: dynamic, origin: .primaryPort, history: .clock(.init(rootIdentity: "r", period: 10,
                    riseReference: 0.5...0.5, fallReference: 5.5...5.5))),
                .init(authority: constant, origin: .primaryPort, history: .unrestricted)])
        try record.validate(checkpoint: {})
        let control = try NativeSTAInitialSourceControl(limits: .init(), resources: Resources(), contextCount: 1)
        let lease = try control.reserve(bytes: 1, slots: 1)
        try control.finishBuilder(work: 0)
        let context = STAConservativeSourceContext(record: record, control: control, lease: lease)
        let high = try context.enclose(sourceAt: 0, over: 2...3)
        #expect(high.value == 1...1 && high.leftSlope == 0...0)
        let low = try context.enclose(sourceAt: 0, over: -3 ... -2)
        #expect(low.value == 0...0 && low.rightSlope == 0...0)
        let slab = try context.enclose(sourceAt: 0, over: -0.25...0.5)
        #expect(slab.value.contains(0) && slab.value.contains(0.5))
        for t in [0.0, 1.0, -10.0, -9.0] {
            let corner = try context.enclose(sourceAt: 0, over: t...t)
            #expect(corner.leftSlope.contains(0) && corner.rightSlope.contains(1))
        }
        let fixed = try context.enclose(sourceAt: 1, over: -100...100)
        #expect(fixed.value == 0.25...0.25 && fixed.leftSlope == 0...0 && fixed.rightSlope == 0...0)
        #expect(throws: STAExecutionError.self) {
            try context.enclose(sourceAt: 0, over: Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude)
        }
    }

    private enum Refusal: Error { case storage }
    private final class Resources: LibertySourceResourceAccounting {
        enum Failure { case storage, cancel }
        private struct State { var live: UInt64 = 0; var failure: Failure? }
        private let state = Mutex(State())
        var live: UInt64 { state.withLock { $0.live } }
        func arm(_ failure: Failure) { state.withLock { $0.failure = failure } }
        func check() throws {
            let cancelled = state.withLock { s -> Bool in
                if case .cancel? = s.failure { s.failure = nil; return true }; return false
            }
            if cancelled { throw CancellationError() }
        }
        func chargeWork(_ amount: UInt64) throws { try check() }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            try check()
            try state.withLock { s in
                if case .storage? = s.failure { s.failure = nil; throw Refusal.storage }
                let n = s.live.addingReportingOverflow(byteCount)
                guard !n.overflow else { throw Refusal.storage }; s.live = n.partialValue
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { $0.live -= byteCount } }
        }
    }
}

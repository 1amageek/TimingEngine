import Foundation
import Synchronization
import Testing
import TimingCore
@testable import STAEngine

@Suite("Strict distributed RC payload ownership", .timeLimit(.minutes(1)))
struct NativeStrictDistributedPayloadTests {
    private enum Refusal: Error, Equatable { case storage, work, cancelled }

    private final class Resources: LibertySourceResourceAccounting {
        struct State {
            var live: UInt64 = 0
            var temporary: UInt64 = 0
            var peakTemporary: UInt64 = 0
            var work: UInt64 = 0
            var maximumLive = UInt64.max
            var maximumTemporary = UInt64.max
            var maximumWork = UInt64.max
            var cancelled = false
            var cancelOnReservation = false
            var cancelOnWork = false
            var cancelOnLiveReservationBytes: UInt64?
            var lastLiveReservationBytes: UInt64 = 0
        }
        private let storage = Mutex(State())
        var state: State { storage.withLock { $0 } }
        func configure(_ body: (inout State) -> Void) { storage.withLock { state in body(&state) } }
        func check() throws { if state.cancelled { throw Refusal.cancelled } }
        func chargeWork(_ amount: UInt64) throws {
            try storage.withLock { state in
                guard amount <= state.maximumWork - state.work else { throw Refusal.work }
                state.work += amount
                if state.cancelOnWork { state.cancelled = true }
            }
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            try storage.withLock { state in
                if kind == .liveOwnedBytes {
                    state.lastLiveReservationBytes = byteCount
                    guard byteCount <= state.maximumLive - state.live else { throw Refusal.storage }
                    state.live += byteCount
                } else {
                    guard byteCount <= state.maximumTemporary - state.temporary else { throw Refusal.storage }
                    state.temporary += byteCount
                    state.peakTemporary = max(state.peakTemporary, state.temporary)
                }
                if state.cancelOnReservation || (kind == .liveOwnedBytes && state.cancelOnLiveReservationBytes == byteCount) { state.cancelled = true }
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                storage.withLock { state in
                    if kind == .liveOwnedBytes { state.live -= byteCount } else { state.temporary -= byteCount }
                }
            }
        }
    }

    private func solver(_ resources: Resources?, resistance: Double = 1000,
                        work: inout UInt64) throws -> NativeSTADistributedRC {
        let bytes = Array("library (rc) { time_unit : \"1ns\"; capacitive_load_unit (1,pf); cell (C) { pin (Y) { direction : output; function : \"0\"; } } }".utf8)
        let source = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 8), resources: STALibertyResources())
        let parasitics = try SPEFParser().parse(Data("""
        *SPEF "IEEE 1481-1998"
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *D_NET n 1
        *CONN
        *P source I
        *P sink O
        *CAP
        1 sink 1
        *RES
        1 source sink \(resistance)
        *END
        """.utf8))
        let limits = try STAExecutionLimits()
        let budget = NativeSTAStateBudget(maximum: limits.maximumPathStates, transformResources: resources)
        return try .init(options: .init(maximumTimeStep: 1e-11, stopTime: 8e-8, crossingTolerance: 1e-12,
            maximumRefinements: 10, maximumNodes: 4, maximumSteps: 1_000_000), limits: limits,
            parasitics: parasitics, design: .init(topDesignName: "top", ports: [
                .init(name: "source", direction: .input, net: "n"), .init(name: "sink", direction: .output, net: "n")],
                instances: [], nets: [.init(name: "n")]), cells: [], source: source, stateBudget: budget,
            mode: "functional", corner: "exact", initialSteps: 0, work: &work)
    }

    @Test(arguments: [TimingEdge.rise, .fall])
    func actualOnePoleMatchesLegacyAndIndependentCrossings(_ edge: TimingEdge) throws {
        let resources = Resources()
        do {
            var strictWork: UInt64 = 0, legacyWork: UInt64 = 0
            var strict = try solver(resources, work: &strictWork)
            var legacy = try solver(nil, work: &legacyWork)
            resources.configure { $0.peakTemporary = 0 }
            let actual = try strict.response(net: "n", sink: "sink", sourceSlew: 0, edge: edge, work: &strictWork)
            let expected = try legacy.response(net: "n", sink: "sink", sourceSlew: 0, edge: edge, work: &legacyWork)
            #expect(actual.delay.bitPattern == expected.delay.bitPattern)
            #expect(actual.slew.bitPattern == expected.slew.bitPattern)
            #expect(strictWork == legacyWork && strict.steps == legacy.steps)
            #expect(strict.observations == legacy.observations)
            #expect(abs(actual.delay - log(2) * 1e-9) < 2e-12)
            #expect(abs(actual.slew - log(4) * 1e-9) < 2e-12)
            // Three levels, operator, factor, two voltages, three optional crossings,
            // and the returned three crossings coexist at the final solve return.
            let expectedPeak = UInt64(10 * MemoryLayout<Double>.stride + 3 * MemoryLayout<Double?>.stride)
            #expect(resources.state.peakTemporary == expectedPeak)
            #expect(resources.state.temporary == 0 && resources.state.live > 0)
            let retainedBytes = resources.state.live
            let steps = strict.steps
            let cached = try strict.response(net: "n", sink: "sink", sourceSlew: 0, edge: edge, work: &strictWork)
            #expect(cached.delay.bitPattern == actual.delay.bitPattern)
            #expect(resources.state.live == retainedBytes && strict.steps == steps)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func actualPeriodicWorkspaceAndCachePreserveLegacyBits() throws {
        let resources = Resources()
        do {
            var strictWork: UInt64 = 0, legacyWork: UInt64 = 0
            var strict = try solver(resources, work: &strictWork)
            var legacy = try solver(nil, work: &legacyWork)
            let source = STAPeriodicRCSource(period: 4e-9, risePhase: 0.5e-9, fallPhase: 2.5e-9,
                riseSlew: 0.06e-9, fallSlew: 0.06e-9)
            let actual = try strict.periodicResponse(net: "n", sink: "sink", source: source, work: &strictWork)
            let expected = try legacy.periodicResponse(net: "n", sink: "sink", source: source, work: &legacyWork)
            #expect(actual.riseDelay.bitPattern == expected.riseDelay.bitPattern)
            #expect(actual.fallDelay.bitPattern == expected.fallDelay.bitPattern)
            #expect(actual.riseSlew.bitPattern == expected.riseSlew.bitPattern)
            #expect(actual.fallSlew.bitPattern == expected.fallSlew.bitPattern)
            #expect(strictWork == legacyWork && strict.steps == legacy.steps)
            #expect(strict.observations == legacy.observations && strict.observations.count == 2)
            #expect(resources.state.temporary == 0)
            let retained = resources.state.live, steps = strict.steps
            _ = try strict.periodicResponse(net: "n", sink: "sink", source: source, work: &strictWork)
            #expect(resources.state.live == retained && strict.steps == steps)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func immutableScenarioCopiesAndResultAnchorsRefundAtLastOwner() throws {
        let resources = Resources()
        var work: UInt64 = 0
        var original: NativeSTADistributedRC? = try solver(resources, work: &work)
        _ = try original!.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
        var copy = original
        _ = try copy!.response(net: "n", sink: "sink", sourceSlew: 0, edge: .fall, work: &work)
        #expect(original!.observations.count == 1 && copy!.observations.count == 2)
        var result: NativeSTATransformRetention? = try copy!.transformRetention
        var finalCopy = result
        original = nil; copy = nil; result = nil
        #expect(resources.state.live > 0 && resources.state.temporary == 0)
        withExtendedLifetime(finalCopy) {}
        finalCopy = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test(arguments: [false, true])
    func constructorRefusesBeforeGrowthAndPostAdmissionCancellationRefunds(cancel: Bool) throws {
        let resources = Resources()
        resources.configure {
            if cancel { $0.cancelOnReservation = true } else { $0.maximumLive = 0 }
        }
        var work: UInt64 = 0
        if cancel {
            #expect(throws: Refusal.cancelled) { _ = try solver(resources, work: &work) }
        } else {
            #expect(throws: Refusal.storage) { _ = try solver(resources, work: &work) }
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func actualSolveRefusalsReleaseScratchAndCachePublicationIsAtomic() throws {
        let resources = Resources()
        do {
            var work: UInt64 = 0
            var rc = try solver(resources, work: &work)
            let networkBytes = resources.state.live
            resources.configure { $0.maximumTemporary = 64 }
            #expect(throws: Refusal.storage) {
                _ = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
            }
            #expect(resources.state.temporary == 0 && resources.state.live == networkBytes)
            #expect(rc.observations.isEmpty)
            resources.configure { $0.maximumTemporary = .max; $0.maximumWork = $0.work }
            #expect(throws: Refusal.work) {
                _ = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
            }
            #expect(resources.state.temporary == 0 && resources.state.live == networkBytes)
            resources.configure { $0.maximumWork = .max }
            _ = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
            let publishedBytes = resources.state.live
            resources.configure { $0.maximumLive = $0.live }
            #expect(throws: Refusal.storage) {
                _ = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .fall, work: &work)
            }
            #expect(rc.observations.count == 1 && rc.observations[0].edge == .rise)
            #expect(resources.state.live == publishedBytes && resources.state.temporary == 0)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func callbackCancellationLeavesNetworkAndPreviousResultsUsable() throws {
        let resources = Resources()
        do {
            var work: UInt64 = 0
            var rc = try solver(resources, work: &work)
            let before = resources.state.live
            resources.configure { $0.cancelOnWork = true }
            #expect(throws: Refusal.cancelled) {
                _ = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
            }
            #expect(resources.state.work > 0 && resources.state.temporary == 0 && resources.state.live == before)
            #expect(rc.observations.isEmpty)
            resources.configure { $0.cancelOnWork = false; $0.cancelled = false }
            _ = try rc.response(net: "n", sink: "sink", sourceSlew: 0, edge: .rise, work: &work)
            #expect(rc.observations.count == 1)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test func idealConstraintUsesSameRetainedPublicationOwner() throws {
        let resources = Resources()
        do {
            var work: UInt64 = 0
            var rc = try solver(resources, resistance: 0, work: &work)
            let result = try rc.response(net: "n", sink: "sink", sourceSlew: 1e-10, edge: .rise, work: &work)
            #expect(result.delay == 0 && result.slew == 1e-10 && rc.steps == 0)
            #expect(rc.observations.first?.method == .idealConstraint)
            #expect(resources.state.temporary == 0 && resources.state.live > 0)
        }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    private func refuseCapOnly(_ net: String, resources: Resources?, liberty: String? = nil) throws {
        let bytes = Array((liberty ?? "library (rc) { time_unit : \"1ns\"; capacitive_load_unit (1,pf); cell (C) { pin (Y) { direction : output; function : \"0\"; } } }").utf8)
        let source = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 8), resources: STALibertyResources())
        let parasitics = try SPEFParser().parse(Data("""
        *SPEF "IEEE 1481-1998"
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *D_NET \(net) 1
        *CONN
        *P source I
        *P sink O
        *CAP
        1 sink 1
        *END
        """.utf8))
        #expect(parasitics.hasDistributedTopology && parasitics.networks.count == 1)
        #expect(parasitics.networks[0].resistances.isEmpty)
        let limits = try STAExecutionLimits()
        let budget = NativeSTAStateBudget(maximum: limits.maximumPathStates, transformResources: resources)
        var work: UInt64 = 0
        _ = try NativeSTADistributedRC(options: .init(maximumTimeStep: 1e-11, stopTime: 8e-8, crossingTolerance: 1e-12,
            maximumRefinements: 10, maximumNodes: 4, maximumSteps: 1_000_000), limits: limits,
            parasitics: parasitics, design: .init(topDesignName: "top", ports: [
                .init(name: "source", direction: .input, net: net), .init(name: "sink", direction: .output, net: net)],
                instances: [], nets: [.init(name: net)]), cells: [], source: source, stateBudget: budget,
            mode: "functional", corner: "exact", initialSteps: 0, work: &work)
    }

    @Test func capOnlySourceRichFailureRetainsOriginalCauseUntilFinalErrorCopy() throws {
        let net = "long_net_" + String(repeating: "x", count: 8192)
        let expected = TimingError.unsupportedSemantic(format: "distributed RC STA",
            semantic: "resistance inventory without topology: " + net)
        #expect(throws: expected) { try refuseCapOnly(net, resources: nil) }
        let resources = Resources()
        resources.configure { $0.maximumTemporary = 0 }
        var original: TimingControlledTransformFailure?
        do {
            try refuseCapOnly(net, resources: resources)
            Issue.record("CAP-only topology unexpectedly completed")
        } catch let failure as TimingControlledTransformFailure {
            original = failure
        } catch { Issue.record("The controlled source-name refusal lost its retained failure owner: \(error)") }
        #expect((original?.cause as? TimingError) == expected)
        let textBytes = UInt64("resistance inventory without topology: ".utf8.count + net.utf8.count)
        #expect(resources.state.live >= textBytes && resources.state.temporary == 0)
        var copied = original
        original = nil
        #expect(resources.state.live >= textBytes && (copied?.cause as? TimingError) == expected)
        withExtendedLifetime(copied) {}
        copied = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test(arguments: [Refusal.storage, .work, .cancelled])
    private func capOnlySourceNameRefusesBeforeDiagnosticConstruction(_ refusal: Refusal) throws {
        let net = "long_net_" + String(repeating: "x", count: 8192)
        let textBytes = UInt64("resistance inventory without topology: ".utf8.count + net.utf8.count)
        let resources = Resources()
        resources.configure {
            $0.maximumTemporary = 0
            switch refusal {
            case .storage: $0.maximumLive = textBytes - 1
            case .work: $0.maximumWork = textBytes - 1
            case .cancelled: $0.cancelOnLiveReservationBytes = textBytes
            }
        }
        #expect(throws: refusal) { try refuseCapOnly(net, resources: resources) }
        #expect(resources.state.lastLiveReservationBytes == textBytes)
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test(arguments: [("input_threshold_pct_rise : 0;", TimingCharacterizationError.invalidValue("input_threshold_pct_rise")),
                      ("slew_derate_from_library : 2;", TimingCharacterizationError.unsupportedSemantic("slew_derate_from_library"))])
    func invalidOwnedThresholdFailureKeepsCanonicalCauseAndErrorCopy(_ attribute: String, _ issue: TimingCharacterizationError) throws {
        let liberty = "library (rc) { time_unit : \"1ns\"; capacitive_load_unit (1,pf); " + attribute
            + " cell (C) { pin (Y) { direction : output; function : \"0\"; } } }"
        var expected: TimingError?
        do {
            try refuseCapOnly("n", resources: nil, liberty: liberty)
            Issue.record("Invalid source thresholds unexpectedly completed")
        } catch let error as TimingError { expected = error }
        let cause = try #require(expected)
        guard case .unsupportedSemantic(let format, let semantic) = cause else {
            Issue.record("The legacy source-threshold failure changed category")
            return
        }
        #expect(format == "distributed RC STA" && semantic == "unavailable source threshold convention: " + String(describing: Optional(issue)))
        let description = try #require(issue.errorDescription)
        let canonicalSemantic = "unavailable source threshold convention: " + description
        let canonicalCause = TimingError.unsupportedSemantic(format: format, semantic: canonicalSemantic)
        let resources = Resources()
        var original: TimingControlledTransformFailure?
        do {
            try refuseCapOnly("n", resources: resources, liberty: liberty)
            Issue.record("Invalid controlled source thresholds unexpectedly completed")
        } catch let error as TimingControlledTransformFailure { original = error }
        catch { Issue.record("Source-threshold failure has no controlled retention owner: \(error)") }
        #expect((original?.cause as? TimingError) == canonicalCause)
        #expect(resources.state.live >= UInt64(canonicalSemantic.utf8.count) && resources.state.temporary == 0)
        var copied = original
        original = nil
        #expect((copied?.cause as? TimingError) == canonicalCause && resources.state.live > 0)
        withExtendedLifetime(copied) {}
        copied = nil
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }

    @Test(arguments: [Refusal.storage, .work, .cancelled])
    private func invalidOwnedThresholdFormattingRefusesBeforeConstruction(_ refusal: Refusal) throws {
        let liberty = "library (rc) { time_unit : \"1ns\"; capacitive_load_unit (1,pf); input_threshold_pct_rise : 0; cell (C) { pin (Y) { direction : output; function : \"0\"; } } }"
        let resources = Resources()
        resources.configure {
            switch refusal {
            case .storage: $0.maximumTemporary = 0
            case .work: $0.maximumWork = 0
            case .cancelled: $0.cancelOnWork = true
            }
        }
        #expect(throws: refusal) { try refuseCapOnly("n", resources: resources, liberty: liberty) }
        #expect(resources.state.live == 0 && resources.state.temporary == 0)
    }
}

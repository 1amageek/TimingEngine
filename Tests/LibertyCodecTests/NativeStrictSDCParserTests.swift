import Foundation
import Synchronization
import Testing
@testable import TimingCore

@Suite("Controlled SDC source construction", .timeLimit(.minutes(1)))
struct NativeStrictSDCParserTests {
    private let script = """
    # The original parser's quote/brace/collection grammar remains authoritative.
    create_clock -name 主 -period "2NS" -waveform {0 1} [get_ports clk]
    create_clock -name 副 -period 4ns [get_ports clk2]
    create_generated_clock -name divided -source [get_ports clk] -divide_by 2 [get_ports gclk]
    set_input_delay -clock [get_clocks 主] 0.3 [get_ports {a b}]
    set_input_delay -clock [get_clocks 主] -max 0.5 [get_ports a]
    set_output_delay -clock [get_clocks 主] -min -0.2 [get_ports out]
    set_input_transition 100PS [all_inputs]
    set_clock_transition -rise 0.12 [get_clocks 主]
    set_clock_transition -fall 0.15 [get_clocks 主]
    set_propagated_clock [get_clocks 主]
    set_clock_uncertainty 0.01 [get_clocks 主]
    set_false_path -from [get_ports a] -through [get_pins U:A] -to [get_pins U:Z]
    set_multicycle_path 2 -setup -end -from [get_clocks 主] -to [get_clocks 副]
    set_max_delay 0.7 -from [get_ports a] -to [get_ports out]
    set_min_delay 0.1 -from [get_ports b] -to [get_ports out]
    group_path -from [get_ports a] -to [get_ports out] -weight 2
    set_clock_groups -asynchronous -group [get_clocks 主] -group [get_clocks 副]
    set_case_analysis 1 [get_ports {選択 enable}]
    set_case_analysis 1 [get_ports 選択]
    """

    @Test func actualGrammarUnicodeOverwriteAndRoundTripMatchLegacy() throws {
        let bytes = Data(script.utf8)
        let parser = SDCParser()
        let expected = try parser.parse(bytes, modeID: "mode")
        let resources = LibertyCodecTestResources()
        do {
            let result = try parser.parse(bytes, modeID: "mode", resources: resources)
            #expect(result.value == expected)
            #expect(result.value.clocks.count == 2)
            #expect(result.value.clocks[0].hasValidPropagatedSource)
            #expect(result.value.inputDelays.count == 4)
            #expect(result.value.inputDelays.last?.port == "a")
            #expect(result.value.inputDelays.last?.isMax == true)
            #expect(result.value.inputDelays.last?.rise == 0.5e-9)
            #expect(result.value.caseAnalyses.count == 2)
            #expect(result.value.pathGroups.first?.name.hasPrefix("group_") == true)
            let decoded = try JSONDecoder().decode(TimingConstraintSet.self, from: JSONEncoder().encode(result.value))
            #expect(decoded == expected)
            #expect(resources.liveBytes > 0 && resources.temporaryBytes == 0)
        }
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func copiedWholeHandleKeepsCurrentOutputUntilFinalRelease() throws {
        let resources = LibertyCodecTestResources()
        var original: TimingTransformValue<TimingConstraintSet>? = try SDCParser().parse(Data(script.utf8), resources: resources)
        let retained = resources.liveBytes
        var copied = original
        original = nil
        #expect(resources.liveBytes == retained && resources.temporaryBytes == 0)
        #expect(copied?.value.exceptions.count == 4)
        withExtendedLifetime(copied) {}
        copied = nil
        #expect(resources.liveBytes == 0 && resources.reservationCount == resources.releaseCount)
    }

    @Test(arguments: [
        "create_clock -period bad [get_ports clk]",
        "create_clock -name x [get_ports clk]",
        "set_case_analysis wrong [get_ports a]",
        "set_case_analysis 0 [get_ports a]\nset_case_analysis 1 [get_ports a]",
        "set_false_path -through",
        "set_false_path -setup -setup -from [get_ports a]",
        "set_false_path -from [unknown a]",
        "set_false_path -from $a",
        "set_clock_transition 1 [get_clocks 未定義]",
        "create_clock -period 2 [get_ports clk]\nset_clock_uncertainty 1 [get_clocks clk clk]",
        "unsupported_命令 x"
    ])
    func originalTypedRichDiagnosticsArePreserved(source: String) throws {
        let data = Data(source.utf8), parser = SDCParser()
        var expected: TimingError?
        do { _ = try parser.parse(data); Issue.record("Legacy malformed source succeeded") }
        catch let error as TimingError { expected = error }
        let resources = LibertyCodecTestResources()
        var held: TimingControlledTransformFailure?
        do { _ = try parser.parse(data, resources: resources); Issue.record("Controlled malformed source succeeded") }
        catch let error as TimingControlledTransformFailure {
            #expect(error.cause as? TimingError == expected)
            held = error
        }
        #expect(held != nil && resources.liveBytes > 0)
        var copy = held; held = nil
        #expect(copy?.cause as? TimingError == expected)
        #expect(resources.liveBytes > 0)
        withExtendedLifetime(copy) {}
        copy = nil
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func invalidUTF8RetainsOriginalTypedCauseAndReleasesFailureOwner() throws {
        let resources = LibertyCodecTestResources()
        do {
            _ = try SDCParser().parse(Data([0xff, 0xfe]), resources: resources)
            Issue.record("Invalid UTF-8 succeeded")
        } catch let error as TimingControlledTransformFailure {
            #expect(error.cause as? TimingError == .parseFailure(format: "SDC", line: 1, message: "Input is not UTF-8."))
            #expect(resources.liveBytes > 0)
        }
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
    }

    @Test(arguments: ["source", "slots", "work"])
    func finiteCallerLimitsRefuseInsteadOfUncontrolledFallback(kind: String) throws {
        let resources: LibertyCodecTestResources
        if kind == "source" {
            resources = .init(maximumTemporaryBytes: 1)
        } else if kind == "slots" {
            resources = .init(maximumLiveBytes: 1)
        } else {
            resources = .init(maximumWork: 1)
        }
        do {
            _ = try SDCParser().parse(Data(script.utf8), resources: resources)
            Issue.record("Finite caller limit was bypassed")
        } catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            if kind == "source" { #expect(cause as? LibertyCodecTestResources.Failure == .quota(.temporaryBytes)) }
            else if kind == "slots" { #expect(cause as? LibertyCodecTestResources.Failure == .quota(.liveOwnedBytes)) }
            else { #expect(cause as? LibertyCodecTestResources.Failure == .work) }
        }
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test(arguments: [false, true])
    func postCallbackCancelIsObservedBeforeConstructionAndCleanupCannotCancel(onWork: Bool) throws {
        let resources = CallbackCancellation(onWork: onWork)
        do {
            _ = try SDCParser().parse(Data(script.utf8), resources: resources)
            Issue.record("Callback cancellation was ignored")
        } catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            #expect(cause as? CallbackCancellation.Failure == .cancelled)
        }
        #expect(resources.live == 0)
        #expect(resources.calls == 1)
    }

    @Test(arguments: ["-divide_by nonsense", "-multiply_by nonsense", "-divide_by", "-multiply_by"])
    func presentMalformedGeneratedRatioCannotBecomeDefault(option: String) throws {
        let parser = SDCParser()
        let data = Data("create_generated_clock -name g -source [get_ports clk] \(option)".utf8)
        var expected: TimingError?
        do { _ = try parser.parse(data); Issue.record("Present malformed ratio became the absent-option default") }
        catch let error as TimingError { expected = error }
        let resources = LibertyCodecTestResources()
        do {
            _ = try parser.parse(data, resources: resources)
            Issue.record("Controlled malformed ratio became the absent-option default")
        } catch let error as TimingControlledTransformFailure {
            #expect(error.cause as? TimingError == expected)
        }
        #expect(expected != nil)
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
    }

    @Test(arguments: [false, true])
    func absentAndPositiveGeneratedRatiosKeepOriginalValues(explicit: Bool) throws {
        let options = explicit ? "-divide_by +2 -multiply_by 3" : ""
        let data = Data("create_generated_clock -name g -source [get_ports clk] \(options) [get_ports gclk]".utf8)
        let parser = SDCParser(), resources = LibertyCodecTestResources()
        do {
            let result = try parser.parse(data, resources: resources)
            #expect(result.value == (try parser.parse(data)))
            #expect(result.value.generatedClocks.first?.divideBy == (explicit ? 2 : 1))
            #expect(result.value.generatedClocks.first?.multiplyBy == (explicit ? 3 : 1))
        }
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
    }

    private final class CallbackCancellation: LibertySourceResourceAccounting {
        enum Failure: Error, Sendable, Equatable { case cancelled }
        private struct State { var cancelled = false; var live: UInt64 = 0; var calls = 0 }
        private let state = Mutex(State())
        private let onWork: Bool
        init(onWork: Bool) { self.onWork = onWork }
        var live: UInt64 { state.withLock { $0.live } }
        var calls: Int { state.withLock { $0.calls } }
        func check() throws { if state.withLock({ $0.cancelled }) { throw Failure.cancelled } }
        func chargeWork(_ amount: UInt64) throws {
            if onWork { state.withLock { $0.calls += 1; $0.cancelled = true } }
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            state.withLock { state in
                state.live += byteCount
                if !onWork { state.calls += 1; state.cancelled = true }
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { $0.live -= byteCount } }
        }
    }
}

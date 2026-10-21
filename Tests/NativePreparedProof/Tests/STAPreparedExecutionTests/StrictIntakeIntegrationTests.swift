import Foundation
import CircuiteFoundation
import PDKCore
import PDKDiscovery
import Synchronization
import Testing
import TimingCore
@testable import STAEngine

@Suite("Strict Timing intake integration")
struct StrictIntakeIntegrationTests {
    private final class Resources: LibertySourceResourceAccounting {
        enum Failure: Error, Sendable { case capacity, work, cancelled }
        private struct State {
            var live: UInt64 = 0; var temporary: UInt64 = 0; var work: UInt64 = 0
            var cancelled = false; var peak: UInt64 = 0; var reservations = 0
        }
        private let state = Mutex(State())
        let maximumBytes: UInt64
        let maximumWork: UInt64
        let cancelOnFirstReservation: Bool
        let cancelAtReservation: Int?
        init(maximumBytes: UInt64 = 536_870_912, maximumWork: UInt64 = 2_000_000_000,
            cancelOnFirstReservation: Bool = false, cancelAtReservation: Int? = nil) {
            self.maximumBytes = maximumBytes; self.maximumWork = maximumWork
            self.cancelOnFirstReservation = cancelOnFirstReservation
            self.cancelAtReservation = cancelAtReservation
        }
        var live: UInt64 { state.withLock { $0.live } }
        var temporary: UInt64 { state.withLock { $0.temporary } }
        var work: UInt64 { state.withLock { $0.work } }
        var peak: UInt64 { state.withLock { $0.peak } }
        var reservations: Int { state.withLock { $0.reservations } }
        func check() throws { if state.withLock({ $0.cancelled }) { throw Failure.cancelled } }
        func chargeWork(_ amount: UInt64) throws {
            try check()
            try state.withLock { value in
                let next = value.work.addingReportingOverflow(amount)
                guard !next.overflow, next.partialValue <= maximumWork else { throw Failure.work }
                value.work = next.partialValue
            }
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
            try check()
            try state.withLock { value in
                let current = kind == .liveOwnedBytes ? value.live : value.temporary
                let next = current.addingReportingOverflow(byteCount)
                let total = next.partialValue.addingReportingOverflow(kind == .liveOwnedBytes ? value.temporary : value.live)
                guard !next.overflow, !total.overflow, total.partialValue <= maximumBytes else { throw Failure.capacity }
                if kind == .liveOwnedBytes { value.live = next.partialValue } else { value.temporary = next.partialValue }
                value.peak = max(value.peak, total.partialValue)
                value.reservations += 1
                if cancelOnFirstReservation || value.reservations == cancelAtReservation { value.cancelled = true }
            }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                state.withLock { value in
                    if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                }
            }
        }
    }

    private func strict(_ fixture: PreparedFixture, _ ledger: Resources) throws -> STAExecutionResources {
        .init(reader: fixture.reader, sourceLimits: try .init(maximumNestingDepth: 64),
            sourceResources: ledger, limits: try .init(), requiresStrictTransformAccounting: true)
    }

    private struct OriginalConstruction: Decodable, Sendable {
        init(from decoder: any Decoder) throws {}
    }

    /// The former real audited construction path is a comparison of resource
    /// work only; it creates no alternate parser, DTO or success certificate.
    private func savedWithoutDigestContext(_ data: Data, fixture: PreparedFixture,
        ledger: Resources) throws -> TimingTransformValue<STAExecutionResult> {
        let accounting = try NativeSTAPDKAccounting(resources: ledger, maximumNesting: 64)
        var value: STAExecutionResult?
        var original: (any Error)?
        do {
            let document = try data.withUnsafeBytes { raw in
                try NativePDKBoundedDocumentDecoder().decodeAudited(OriginalConstruction.self,
                    bytes: raw.bindMemory(to: UInt8.self).span, accounting: accounting,
                    rejectUnknownFields: false) { decoder in
                        do { value = try STAExecutionResult(from: decoder) }
                        catch { original = error; throw error }
                    }
            }
            let actual = try #require(value)
            return try TimingTransformValue(value: actual, retaining: document, resources: ledger)
        } catch { throw accounting.preservingCause(error, domainCause: original) }
    }

    private func savedResult(_ fixture: PreparedFixture) async throws -> (STAExecutionResult, Data) {
        let engine = NativeSTAEngine(reader: fixture.reader)
        let prepared = try await engine.prepare(fixture.request(), resources: fixture.resources())
        let value = try await engine.execute(prepared)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (value, try encoder.encode(value))
    }

    private func digestText(_ data: Data, replacingFirstWith replacement: String? = nil)
        throws -> (data: Data, count: Int) {
        // Read only String metadata from Foundation's fixture tree. Never
        // reserialize NSNumber values: every original numerical token stays intact.
        var digests: [String] = []
        var digestPaths: Set<String> = []
        func collect(_ object: Any, path: String) {
            if let fields = object as? [String: Any] {
                for (key, value) in fields {
                    let childPath = path + "." + key
                    if key == "hexadecimalValue", let text = value as? String {
                        digests.append(text)
                        digestPaths.insert(childPath)
                    } else { collect(value, path: childPath) }
                }
            } else if let values = object as? [Any] {
                for (index, value) in values.enumerated() {
                    collect(value, path: path + "[" + String(index) + "]")
                }
            }
        }
        collect(try JSONSerialization.jsonObject(with: data), path: "$")
        #expect(digests.count == 2)
        #expect(digestPaths == [
            "$.payload.effectiveConfiguration.digest.hexadecimalValue",
            "$.evidence.provenance.environment.environmentDigest.hexadecimalValue"
        ])
        var text = String(decoding: data, as: UTF8.self)
        if let replacement {
            let selected = try #require(digests.first)
            let token = "\"hexadecimalValue\":\"" + selected + "\""
            let range = try #require(text.range(of: token))
            text.replaceSubrange(range, with: "\"hexadecimalValue\":\"" + replacement + "\"")
        } else {
            for value in Set(digests) {
                text = text.replacingOccurrences(of: "\"hexadecimalValue\":\"" + value + "\"",
                    with: "\"hexadecimalValue\":\"" + value.uppercased() + "\"")
            }
        }
        return (Data(text.utf8), digests.count)
    }

    @Test(.timeLimit(.minutes(1)))
    func savedUppercaseDigestIntakeUsesSameWorkAndLastCopyOwner() async throws {
        guard #available(macOS 15.0, *) else { Issue.record("Digest ledger fixture requires Mutex support"); return }
        let fixture = try PreparedFixture()
        defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let (expected, encoded) = try await savedResult(fixture)
        let input = try digestText(encoded)
        let former = Resources()
        do {
            let baseline = try savedWithoutDigestContext(input.data, fixture: fixture, ledger: former)
            #expect(baseline.value == expected)
        }
        #expect(former.live == 0 && former.temporary == 0)
        let ledger = Resources()
        var first: TimingTransformValue<STAExecutionResult>? = try STAExecutionResult.decodeBounded(
            input.data, resources: strict(fixture, ledger))
        var second = first
        #expect(second?.value == expected)
        // For each real 64-byte digest CF charges 64 scalar + 64 byte planning
        // visits, then the original 64 lowercase + 64 validation visits.
        let required = UInt64(input.count) * 256
        #expect(ledger.work >= former.work + required)
        let live = ledger.live
        #expect(live >= UInt64(input.count) * 64)
        first = nil
        #expect(second?.value == expected)
        #expect(ledger.live == live)
        second = nil
        #expect(ledger.live == 0 && ledger.temporary == 0)
    }

    @Test(arguments: [false, true])
    func savedDigestWorkAndIndependentCallbackCancellationRefuse(cancel: Bool) async throws {
        guard #available(macOS 15.0, *) else { Issue.record("Digest ledger fixture requires Mutex support"); return }
        let fixture = try PreparedFixture()
        defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let (_, encoded) = try await savedResult(fixture)
        let input = try digestText(encoded)
        let reference = Resources()
        let ledger: Resources
        if cancel {
            do { _ = try STAExecutionResult.decodeBounded(input.data, resources: strict(fixture, reference)) }
            #expect(reference.live == 0 && reference.temporary == 0)
            ledger = Resources(cancelAtReservation: reference.reservations)
        } else {
            do { _ = try savedWithoutDigestContext(input.data, fixture: fixture, ledger: reference) }
            ledger = Resources(maximumWork: reference.work + UInt64(input.count) * 256 - 1)
        }
        var first: TimingControlledTransformFailure?
        do {
            _ = try STAExecutionResult.decodeBounded(input.data, resources: strict(fixture, ledger))
            Issue.record("Saved digest work/cancellation admission was bypassed")
        } catch let error as TimingControlledTransformFailure { first = error }
        var second = first
        first = nil
        let cause = try #require(second?.cause as? Resources.Failure)
        switch cause {
        case .cancelled: #expect(cancel)
        case .work: #expect(!cancel)
        case .capacity: Issue.record("Unexpected capacity refusal")
        }
        #expect(ledger.live > 0)
        withExtendedLifetime(second) {}
        second = nil
        #expect(ledger.live == 0 && ledger.temporary == 0)
    }

    @Test(arguments: [String(repeating: "A", count: 4096), String(repeating: "İ", count: 256)])
    func savedInvalidDigestKeepsOriginalDomainAndWholePDKFailure(text: String) async throws {
        guard #available(macOS 15.0, *) else { Issue.record("Digest ledger fixture requires Mutex support"); return }
        let fixture = try PreparedFixture()
        defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let (_, encoded) = try await savedResult(fixture)
        let input = try digestText(encoded, replacingFirstWith: text)
        let expected: ContentDigestError
        do {
            _ = try JSONDecoder().decode(STAExecutionResult.self, from: input.data)
            Issue.record("Invalid CF digest decoded"); return
        } catch let error as ContentDigestError { expected = error }
        let pdkLedger = Resources()
        do {
            let accounting = try NativeSTAPDKAccounting(resources: pdkLedger, maximumNesting: 64)
            do {
                _ = try input.data.withUnsafeBytes { raw in
                    try NativePDKBoundedDocumentDecoder().decodeAudited(STAExecutionResult.self,
                        bytes: raw.bindMemory(to: UInt8.self).span, accounting: accounting,
                        rejectUnknownFields: false, validate: { _ in })
                }
                Issue.record("Invalid digest accepted by original PDK audit")
            } catch let failure as PDKControlledDecodeFailure {
                guard case .unsupportedValue = failure.cause else { throw failure }
                #expect(pdkLedger.live > 0)
            }
        }
        #expect(pdkLedger.live == 0 && pdkLedger.temporary == 0)
        let ledger = Resources()
        var first: TimingControlledTransformFailure?
        do {
            _ = try STAExecutionResult.decodeBounded(input.data, resources: strict(fixture, ledger))
            Issue.record("Invalid controlled saved digest decoded")
        } catch let failure as TimingControlledTransformFailure { first = failure }
        var second = first
        first = nil
        #expect(second?.cause as? ContentDigestError == expected)
        #expect(ledger.live >= UInt64(text.utf8.count))
        #expect(ledger.temporary == 0)
        withExtendedLifetime(second) {}
        second = nil
        #expect(ledger.live == 0 && ledger.temporary == 0)
    }

    @Test func savedDigestExactAndBelowObservedLogicalStorageCeiling() async throws {
        guard #available(macOS 15.0, *) else { Issue.record("Digest ledger fixture requires Mutex support"); return }
        let fixture = try PreparedFixture()
        defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let (_, encoded) = try await savedResult(fixture)
        let input = try digestText(encoded)
        let reference = Resources()
        do { _ = try STAExecutionResult.decodeBounded(input.data, resources: strict(fixture, reference)) }
        #expect(reference.live == 0 && reference.temporary == 0)
        let peak = reference.peak
        #expect(peak > 0)
        let exact = Resources(maximumBytes: peak)
        do { _ = try STAExecutionResult.decodeBounded(input.data, resources: strict(fixture, exact)) }
        #expect(exact.live == 0 && exact.temporary == 0)
        let below = Resources(maximumBytes: peak - 1)
        do {
            _ = try STAExecutionResult.decodeBounded(input.data, resources: strict(fixture, below))
            Issue.record("Below observed logical capacity was accepted")
        } catch let failure as TimingControlledTransformFailure {
            guard let cause = failure.cause as? Resources.Failure,
                  case .capacity = cause else { throw failure }
        }
        #expect(below.live == 0 && below.temporary == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func actualStrictPrepareExecuteSavedDecodeMatchesLegacyAndLastCopyRefunds() async throws {
        let fixture = try PreparedFixture()
        defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let engine = NativeSTAEngine(reader: fixture.reader)
        let baseline = try await engine.prepare(fixture.request(), resources: fixture.resources())
        let expected = try await engine.execute(baseline)
        let ledger = Resources()
        var retained: TimingTransformValue<STAExecutionResult>?
        do {
            let resources = try strict(fixture, ledger)
            let prepared = try await engine.prepare(fixture.request(), resources: resources)
            #expect(prepared.effectiveConfiguration == baseline.effectiveConfiguration)
            let result = try await engine.execute(prepared)
            #expect(result.status == .completed)
            #expect(result.payload == expected.payload)
            let encoded = try TimingJSONEncoding.encode(result, formatting: [.sortedKeys], resources: ledger)
            let decoded = try STAExecutionResult.decodeBounded(encoded.value, resources: resources)
            #expect(decoded.value == result)
            retained = decoded
            #expect(ledger.live > 0)
            #expect(ledger.work > 0)
        }
        #expect(retained?.value.status == .completed)
        #expect(ledger.live > 0)
        retained = nil
        #expect(ledger.live == 0)
        #expect(ledger.temporary == 0)
    }

    @Test(arguments: [false, true])
    func strictIntakeRefusesOriginalCallerCapacityOrIndependentCancellation(cancel: Bool) async throws {
        let fixture = try PreparedFixture()
        defer { do { try fixture.remove() } catch { Issue.record(error) } }
        let engine = NativeSTAEngine(reader: fixture.reader)
        let ledger = Resources(maximumBytes: cancel ? 536_870_912 : 1, cancelOnFirstReservation: cancel)
        do {
            _ = try await engine.prepare(fixture.request(), resources: strict(fixture, ledger))
            Issue.record("Strict intake accepted a refused caller ledger")
        } catch STAPreparationError.underlying(let cause) {
            let original = (cause as? TimingControlledTransformFailure)?.cause ?? cause
            guard let failure = original as? Resources.Failure else { throw cause }
            switch failure {
            case .cancelled: #expect(cancel)
            case .capacity: #expect(!cancel)
            case .work: Issue.record("Wrong refusal dimension")
            }
        }
        #expect(ledger.live == 0)
        #expect(ledger.temporary == 0)
    }

    @Test func controlledReplayTextPreservesDetailedWireBitsAndFinalOwner() throws {
        let sink = TimingParasitics.Endpoint(name: "u/Y", ownerNet: "a")
        let source = TimingParasitics.Endpoint(name: "a", ownerNet: "a")
        func wire(_ derivative: Double, net: String) -> STAConservativeWireObservation {
            .init(modeID: "default", cornerID: "typical", net: net, source: source, sink: sink,
                edge: .rise, sourceAuthorities: [], sourceSlew: 1...2, admittedSourceSlew: 1...2,
                delay: 3...4, slew: 5...6, voltageErrorUpperBound: .leastNonzeroMagnitude,
                minimumCrossingDerivative: derivative, maximumAbsoluteDerivative: 8)
        }
        let actual = STAPayload(worstSetupSlack: nil, worstHoldSlack: nil, analyzedCorners: ["typical"],
            conservativeWireObservations: [wire(7, net: "a")])
        let observed = STAPayload(worstSetupSlack: -0.0, worstHoldSlack: nil, analyzedCorners: ["typical"],
            conservativeWireObservations: [wire(Double(7).nextDown, net: String(repeating: "é😀", count: 100))])
        let expected = try NativeSTAEngine.boundedReplayMismatch(observed: observed, actual: actual, resources: STALibertyResources())
        let ledger = Resources()
        var last: TimingTransformValue<String>?
        do {
            let message = try NativeSTAEngine.controlledReplayMismatch(observed: observed, actual: actual, resources: ledger)
            #expect(message.value == expected)
            #expect(message.value.contains("derivativeMin="))
            last = message
        }
        #expect(last?.value == expected)
        #expect(ledger.live > 0)
        last = nil
        #expect(ledger.live == 0)
        #expect(ledger.temporary == 0)
        #expect(throws: Resources.Failure.self) {
            _ = try NativeSTAEngine.controlledReplayMismatch(observed: observed, actual: actual,
                resources: Resources(maximumBytes: 1))
        }
    }
}

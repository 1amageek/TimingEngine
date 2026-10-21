import Foundation
import Synchronization
import Testing
@testable import TimingCore

@Suite("Controlled canonical rule construction", .timeLimit(.minutes(1)))
struct NativeStrictCanonicalValidatorTests {
    private struct Inputs {
        var design: TimingDesign
        var constraints: TimingConstraintSet
        var libraries: [TimingLibrary]
        var parasitics: TimingParasitics
    }

    private func inputs(malformed: Bool = false, bidirectional: Bool = false) -> Inputs {
        var design = TimingDesign(topDesignName: "top", ports: [
            .init(name: "a", direction: .input, net: "a"), .init(name: "z", direction: .output, net: "z")],
            instances: [.init(name: "U", cell: "C", connections: ["A": "a", "Y": "z"])],
            nets: [.init(name: "a"), .init(name: "z")])
        var constraints = TimingConstraintSet(clocks: [.init(name: "clk", source: "a", period: 1e-9)])
        let direction: TimingPin.Direction = bidirectional ? .bidirectional : .output
        var libraries = [TimingLibrary(name: "library", cells: ["C": TimingCell(name: "C", pins: [
            .init(name: "A", direction: .input), .init(name: "Y", direction: direction)])])]
        let source = TimingParasitics.SourceID(declaringNet: "z", identifier: 1, line: 1)
        let first = TimingParasitics.Endpoint(name: "U:Y", ownerNet: "z")
        let second = TimingParasitics.Endpoint(name: "z", ownerNet: "z")
        var caps = [TimingParasitics.CapacitanceRecord(source: source, first: second, capacitance: 1e-12)]
        if malformed {
            design.ports.append(.init(name: "a", direction: .input, net: "a"))
            design.nets[1].capacitance = -1
            design.instances[0].connections["UNKNOWN"] = "z"
            constraints.generatedClocks = [.init(name: "g", source: "z", masterClock: "missing", divideBy: 0, multiplyBy: 1)]
            libraries[0].cells["C"]!.pins[0].capacitance = -1
            caps.append(.init(source: source, first: .init(name: "z", ownerNet: "foreign"), capacitance: -1))
        }
        let parasitics = TimingParasitics(networks: [.init(name: "z", declaredCapacitance: 1e-12,
            resistanceInventory: 1000, capacitances: caps,
            resistances: [.init(source: source, first: first, second: second, resistance: 1000)],
            connections: [first, second])])
        return .init(design: design, constraints: constraints, libraries: libraries, parasitics: parasitics)
    }

    private func legacy(_ value: Inputs, entry: String) -> TimingCanonicalValidationReport {
        let validator = TimingCanonicalValidator()
        switch entry {
        case "SI": return validator.validateSignalIntegrity(design: value.design, constraints: value.constraints, parasitics: value.parasitics)
        case "parasitics": return validator.validateSignalIntegrityParasitics(value.parasitics)
        default: return validator.validate(design: value.design, constraints: value.constraints, libraries: value.libraries, parasitics: value.parasitics)
        }
    }

    private func controlled(_ value: Inputs, entry: String = "normal", resources: any LibertySourceResourceAccounting) throws
        -> TimingTransformValue<TimingCanonicalValidationReport> {
        let validator = TimingCanonicalValidator()
        switch entry {
        case "SI": return try validator.validateSignalIntegrity(design: value.design, constraints: value.constraints,
            parasitics: value.parasitics, resources: resources)
        case "parasitics": return try validator.validateSignalIntegrityParasitics(value.parasitics, resources: resources)
        default: return try validator.validate(design: value.design, constraints: value.constraints, libraries: value.libraries,
            parasitics: value.parasitics, resources: resources)
        }
    }

    @Test(arguments: ["normal", "SI", "parasitics"], [false, true])
    func actualValidInputPreservesAllThreeLegacyEntryPoints(entry: String, generated: Bool) throws {
        var value = inputs()
        if generated {
            value.constraints.generatedClocks = [.init(name: "generated", source: "z", masterClock: "clk", divideBy: 2)]
        }
        let resources = LibertyCodecTestResources()
        do {
            let result = try controlled(value, entry: entry, resources: resources)
            #expect(result.value == legacy(value, entry: entry))
            #expect(result.value.isValid)
            #expect(resources.temporaryBytes == 0 && resources.liveBytes > 0)
        }
        #expect(resources.liveBytes == 0 && resources.reservationCount == resources.releaseCount)
    }

    @Test(arguments: ["normal", "SI", "parasitics"])
    func actualMalformedSourcePreservesEveryOriginalFinding(entry: String) throws {
        let value = inputs(malformed: true), resources = LibertyCodecTestResources()
        do {
            let result = try controlled(value, entry: entry, resources: resources)
            let expected = legacy(value, entry: entry)
            #expect(result.value == expected)
            #expect(!result.value.isValid)
            #expect(result.value.findings.contains { $0.code == "timing.parasitic.capacitance-invalid" })
            if entry == "normal" {
                #expect(result.value.findings.contains { $0.code == "timing.port.duplicate" })
                #expect(result.value.findings.contains { $0.code == "timing.library.pin-invalid" && $0.entity == "C/A" })
                #expect(result.value.findings.contains { $0.code == "timing.design.pin-invalid" && $0.entity == "U/UNKNOWN" })
                #expect(result.value.findings.contains { $0.code == "timing.constraint.generated-clock-invalid" })
            }
            #expect(resources.temporaryBytes == 0)
        }
        #expect(resources.liveBytes == 0 && resources.reservationCount == resources.releaseCount)
    }

    @Test func bidirectionalCellOutputsRemainActualDrivers() throws {
        var value = inputs(bidirectional: true)
        // One additional external input aliases the cell's actual inout output net.
        value.design.ports.append(.init(name: "external", direction: .input, net: "z"))
        let resources = LibertyCodecTestResources()
        do {
            let result = try controlled(value, resources: resources)
            #expect(result.value == legacy(value, entry: "normal"))
            #expect(result.value.findings.contains { $0.code == "timing.design.multiple-drivers" && $0.entity == "z" })
        }
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
    }

    @Test func findingAndDerivedTextCopiesKeepOnlyThePublishedOwner() throws {
        let resources = LibertyCodecTestResources()
        var first: TimingTransformValue<TimingCanonicalValidationReport>? = try controlled(inputs(malformed: true), resources: resources)
        let live = resources.liveBytes
        var copied = first
        first = nil
        #expect(resources.liveBytes == live && resources.temporaryBytes == 0)
        #expect(copied?.value.findings.contains { $0.entity == "C/A" } == true)
        withExtendedLifetime(copied) {}
        copied = nil
        #expect(resources.liveBytes == 0 && resources.reservationCount == resources.releaseCount)
    }

    @Test(arguments: ["live", "temporary", "work"])
    func refusalPrecedesConstructionAndKeepsOriginalCallerCause(dimension: String) throws {
        let resources: LibertyCodecTestResources
        if dimension == "live" { resources = .init(maximumLiveBytes: 1) }
        else if dimension == "temporary" { resources = .init(maximumTemporaryBytes: 1) }
        else { resources = .init(maximumWork: 1) }
        do { _ = try controlled(inputs(malformed: true), resources: resources); Issue.record("Caller limit was bypassed") }
        catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            if dimension == "work" { #expect(cause as? LibertyCodecTestResources.Failure == .work) }
            else { #expect(cause as? LibertyCodecTestResources.Failure == .quota(dimension == "live" ? .liveOwnedBytes : .temporaryBytes)) }
        }
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func retainedFailureCopiesRefundWithoutConsultingExhaustedAccountant() throws {
        let resources = LibertyCodecTestResources(maximumWork: 8)
        var first: TimingControlledTransformFailure?
        do { _ = try controlled(inputs(malformed: true), resources: resources); Issue.record("Tiny work limit admitted validation") }
        catch let error as TimingControlledTransformFailure {
            #expect(error.cause as? LibertyCodecTestResources.Failure == .work)
            first = error
        }
        #expect(first != nil && resources.liveBytes > 0)
        var copied = first; first = nil
        withExtendedLifetime(copied) {}
        copied = nil
        #expect(resources.liveBytes == 0 && resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test(arguments: [false, true])
    func callbackCancellationIsCheckedBeforeOwnedGrowth(onWork: Bool) throws {
        let resources = CancellingResources(onWork: onWork)
        do { _ = try controlled(inputs(), resources: resources); Issue.record("Callback cancellation was ignored") }
        catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            #expect(cause as? CancellingResources.Failure == .cancelled)
        }
        #expect(resources.live == 0 && resources.calls == 1)
    }

    private final class CancellingResources: LibertySourceResourceAccounting {
        enum Failure: Error, Sendable, Equatable { case cancelled }
        private struct State { var live: UInt64 = 0; var calls = 0; var cancelled = false }
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
            state.withLock { $0.live += byteCount; if !onWork { $0.calls += 1; $0.cancelled = true } }
            return .init(kind: kind, byteCount: byteCount) { [self] in state.withLock { $0.live -= byteCount } }
        }
    }
}

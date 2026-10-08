import Testing
import Synchronization
@testable import TimingCore

@Suite(.timeLimit(.minutes(1)))
struct LibertyOwnedResourceTests {
    private let source = "library(L) { cell(C) { pin(A) { direction : input; } } }"

    @Test func checkedCapacityAndLimitsRejectOverflow() throws {
        #expect(throws: LibertySourceError.self) { try LibertySourceCapacity.byteCount(of: UInt64.self, capacity: Int.max) }
        #expect(throws: LibertySourceError.self) { try LibertySourceCapacity.byteCount(of: UInt8.self, capacity: -1) }
        #expect(throws: LibertySourceError.self) { try LibertySourceParseLimits(maximumNestingDepth: 0) }
        #expect(try LibertySourceCapacity.byteCount(of: Double.self, capacity: 3) == UInt64(3 * MemoryLayout<Double>.stride))
    }

    @Test func externallyMintedReceiptReleasesAfterLastCopy() {
        let released = Mutex(0)
        var first: LibertySourceStorageReservation? = .init(kind: .liveOwnedBytes, byteCount: 41) {
            released.withLock { $0 += 1 }
        }
        var second = first
        first = nil
        #expect(released.withLock { $0 } == 0)
        #expect(second?.byteCount == 41)
        second = nil
        #expect(released.withLock { $0 } == 1)
    }

    @Test func sourceCapacityRefusesBeforeCopyAndReleasesMetadata() throws {
        let probe = LibertyCodecTestResources()
        var storage: LibertyParseStorage? = try LibertyParseStorage.make(resources: probe)
        let metadataBytes = probe.liveBytes
        #expect(storage != nil)
        storage = nil
        #expect(probe.liveBytes == 0)
        let resources = LibertyCodecTestResources(maximumLiveBytes: metadataBytes + UInt64(source.utf8.count) - 1)
        let bytes = Array(source.utf8)
        do throws(LibertySourceError) {
            _ = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 8), resources: resources)
            Issue.record("Source copy exceeded its admitted capacity")
        } catch {
            guard case .resource(let cause) = error else { Issue.record("Expected original resource failure"); return }
            #expect(cause as? LibertyCodecTestResources.Failure == .quota(.liveOwnedBytes))
        }
        #expect(resources.reservationCount == 1)
        #expect(resources.releaseCount == 1)
        #expect(resources.liveBytes == 0)
    }

    @Test func malformedUTF8AndUnsupportedUnicodeFailBeforeAllocation() throws {
        let malformed: [[UInt8]] = [[0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]]
        for bytes in malformed {
            let resources = LibertyCodecTestResources()
            do throws(LibertySourceError) {
                _ = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 8), resources: resources)
                Issue.record("Invalid UTF-8 was accepted")
            } catch { guard case .invalidUTF8 = error else { Issue.record("Expected UTF-8 error"); continue } }
            #expect(resources.reservationCount == 0)
        }
        let bytes = Array("library(é) {}".utf8)
        let resources = LibertyCodecTestResources()
        do throws(LibertySourceError) {
            _ = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 8), resources: resources)
            Issue.record("Unsupported Unicode grammar was accepted")
        } catch { guard case .unsupportedSemantics = error else { Issue.record("Expected capability refusal"); return } }
        #expect(resources.reservationCount == 0)
        let invalid = Array("library(L) { cell(C) { pin(A) {\ncapacitance\n: bogus; } } }".utf8)
        do throws(LibertySourceError) {
            _ = try LibertyParser().parseSource(invalid.span, limits: .init(maximumNestingDepth: 8), resources: LibertyCodecTestResources())
            Issue.record("Invalid capacitance was accepted")
        } catch { guard case .syntax(line: 2) = error else { Issue.record("Expected original physical attribute line"); return } }
    }

    @Test func cumulativeWorkAndTypedCancellationDeadlinePropagate() throws {
        let bytes = Array(source.utf8)
        let limited = LibertyCodecTestResources(maximumWork: UInt64(bytes.count - 1))
        do throws(LibertySourceError) {
            _ = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 8), resources: limited)
            Issue.record("Cumulative work limit was bypassed")
        } catch {
            guard case .resource(let cause) = error else { Issue.record("Expected resource error"); return }
            #expect(cause as? LibertyCodecTestResources.Failure == .work)
        }
        #expect(limited.reservationCount == 0)
        for failure in [LibertyCodecTestResources.Failure.cancelled, .deadline] {
            let resources = LibertyCodecTestResources(refuseAfterChecks: bytes.count + 25, checkFailure: failure)
            do throws(LibertySourceError) {
                _ = try LibertyParser().parseSource(bytes.span, limits: .init(maximumNestingDepth: 8), resources: resources)
                Issue.record("Terminal resource check was bypassed")
            } catch {
                guard case .resource(let cause) = error else { Issue.record("Expected resource error"); continue }
                #expect(cause as? LibertyCodecTestResources.Failure == failure)
            }
            #expect(resources.liveBytes == 0)
            #expect(resources.temporaryBytes == 0)
            #expect(resources.reservationCount == resources.releaseCount)
        }
    }

    @Test func longTokenPublicationAndFinalCopiedOwnerRelease() throws {
        let name = String(repeating: "n", count: 4096)
        let bytes = Array("library(L) { cell(\(name)) { pin(A) { direction : input; } } }".utf8)
        let resources = LibertyCodecTestResources()
        var owner: OwnedLibertySource? = try LibertyParser().parseSource(bytes.span,
            limits: .init(maximumNestingDepth: 8), resources: resources)
        #expect(owner?.library.cells[name]?.name == name)
        #expect(owner?.cells.first?.name == name)
        #expect(owner?.withBytes { $0.count } == bytes.count)
        #expect(resources.liveBytes > UInt64(bytes.count))
        #expect(resources.temporaryBytes == 0)
        let retainedBytes = resources.liveBytes
        var copied = owner
        owner = nil
        #expect(resources.liveBytes == retainedBytes)
        #expect(copied?.byteCount == bytes.count)
        copied = nil
        #expect(resources.liveBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func sameCapacityBufferAndMapCopiesAreChargedBeforeMutation() throws {
        let resources = LibertyCodecTestResources()
        let storage = try LibertyParseStorage.make(resources: resources)
        var first: LibertyBuffer<Int>? = .init()
        for value in 0..<3 { try first!.append(value, storage: storage) }
        let baseline = resources.temporaryBytes
        #expect(first?.managedCapacity == 4)
        var copied = first
        try copied!.append(3, storage: storage)
        #expect(resources.temporaryBytes == baseline * 2)
        #expect(first?.count == 3)
        try first!.replace(at: 1, with: 9, storage: storage)
        #expect(resources.temporaryBytes == baseline * 2)
        first = nil
        #expect(resources.temporaryBytes == baseline)
        #expect(copied?[1] == 1)
        copied = nil
        #expect(resources.temporaryBytes == 0)

        var map: LibertyMap<Int>? = .init()
        for value in 0..<3 { try map!.set(value, for: "k\(value)", storage: storage) }
        let mapBaseline = resources.temporaryBytes
        var mapCopy = map
        try mapCopy!.set(3, for: "k3", storage: storage)
        #expect(resources.temporaryBytes == mapBaseline * 2)
        try map!.set(8, for: "k1", storage: storage)
        #expect(resources.temporaryBytes == mapBaseline * 2)
        #expect(try mapCopy!.value(for: "k1", storage: storage) == 1)
        map = nil
        #expect(resources.temporaryBytes == mapBaseline)
        mapCopy = nil
        #expect(resources.temporaryBytes == 0)
    }

    @Test func sameCapacityRefusalLeavesOriginalSnapshotUnchanged() throws {
        let slots = try LibertySourceCapacity.byteCount(of: Optional<Int>.self, capacity: 6)
        let resources = LibertyCodecTestResources(maximumTemporaryBytes: slots)
        let storage = try LibertyParseStorage.make(resources: resources)
        var source = LibertyBuffer<Int>()
        for value in 0..<3 { try source.append(value, storage: storage) }
        var copy = source
        do {
            try copy.append(3, storage: storage)
            Issue.record("Shared spare capacity was written without a new reservation")
        } catch { #expect(error as? LibertyCodecTestResources.Failure == .quota(.temporaryBytes)) }
        #expect(source.count == 3)
        #expect(copy.count == 3)
        #expect(copy[2] == 2)
        do {
            try copy.replace(at: 1, with: 9, storage: storage)
            Issue.record("Shared replacement bypassed capacity admission")
        } catch { #expect(error as? LibertyCodecTestResources.Failure == .quota(.temporaryBytes)) }
        #expect(source[1] == 1)
        #expect(copy[1] == 1)
    }

    @Test func nestedLUTValidationChecksBeforeElementWork() throws {
        let resources = LibertyCodecTestResources(maximumWork: 3)
        do {
            _ = try TimingLUT(inputSlews: [0, 1], outputLoads: [0, 1], values: [[1, 2], [3, 4]],
                checking: { try resources.chargeWork(1) })
            Issue.record("Validation ignored its callback refusal")
        } catch { #expect(error as? LibertyCodecTestResources.Failure == .work) }
        #expect(resources.work == 3)
        #expect(throws: TimingError.self) {
            try TimingLUT(inputSlews: [0, 1], outputLoads: [0, 1], values: [[1, 2], [3, .infinity]])
        }
    }
}

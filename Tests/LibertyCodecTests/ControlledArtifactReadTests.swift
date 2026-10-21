import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import Foundation
import Synchronization
import Testing
@testable import TimingCore

@Suite(.timeLimit(.minutes(1)))
struct ControlledArtifactReadTests {
    private func binding(_ bytes: Data, name: String = "design.json") throws -> TimingArtifactBinding {
        let reference = try ArtifactReference(
            digest: SHA256ContentDigester().digest(data: bytes, using: .sha256),
            byteCount: UInt64(bytes.count),
            descriptor: .init(role: .input, kind: .netlist, format: .json))
        return try .init(reference: reference, availability: .local(artifactID: reference.id,
            rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier),
            relativePath: .init(segments: [name])))
    }

    @Test func exactFilesystemBytesAndLastCopiedAnchorRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        // A multi-page actual source also exercises CF's separately admitted
        // contiguous borrowing before the final owned Data publication.
        let bytes = Data(repeating: 0x20, count: 1_048_577)
        try bytes.write(to: root.appending(path: "design.json"))
        let input = try binding(bytes)
        let resources = LibertyCodecTestResources(maximumLiveBytes: 8_388_608,
            maximumTemporaryBytes: 4_194_304, maximumWork: 16_777_216)
        var first: TimingArtifactRead? = try await FileSystemTimingArtifactReader(workspaceRoot: root)
            .read(input, resources: resources)
        #expect(first?.reference == input.reference)
        #expect(first?.data == bytes)
        #expect(resources.temporaryBytes == 0)
        let held = resources.liveBytes
        #expect(held >= UInt64(bytes.count))
        var copied = first
        first = nil
        #expect(resources.liveBytes == held)
        #expect(copied?.data.count == bytes.count)
        copied = nil
        #expect(resources.liveBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func filesystemCallerFailureSurvivesCFControlSentinelAndClose() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let bytes = Data("{}".utf8)
        try bytes.write(to: root.appending(path: "design.json"))
        let input = try binding(bytes)
        let resources = LibertyCodecTestResources(maximumLiveBytes: 1,
            maximumTemporaryBytes: 4096, maximumWork: 4096)
        do {
            _ = try await FileSystemTimingArtifactReader(workspaceRoot: root).read(input, resources: resources)
            Issue.record("CF source page bypassed the caller's tiny capacity")
        } catch { #expect(error as? LibertyCodecTestResources.Failure == .quota(.liveOwnedBytes)) }
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func firstReservationCancellationPreventsSecondAdmission() async throws {
        let bytes = Data("{}".utf8)
        let input = try binding(bytes)
        let resources = CancellingResources()
        do {
            _ = try await InMemoryTimingArtifactReader(artifacts: [input.id: bytes])
                .read(input, resources: resources)
            Issue.record("Cancelled first reservation published bytes")
        } catch { #expect(error as? CancellingResources.Failure == .cancelled) }
        #expect(resources.reservations == 1)
        #expect(resources.liveBytes == 0)
    }

    @Test func callerQuotaAndCumulativeWorkRemainOriginalFailures() async throws {
        let bytes = Data("{}".utf8)
        let input = try binding(bytes)
        let reader = InMemoryTimingArtifactReader(artifacts: [input.id: bytes])
        let quota = LibertyCodecTestResources(maximumLiveBytes: 1,
            maximumTemporaryBytes: 1024, maximumWork: 1024)
        do {
            _ = try await reader.read(input, resources: quota)
            Issue.record("Tiny capacity admitted source bytes")
        } catch { #expect(error as? LibertyCodecTestResources.Failure == .quota(.liveOwnedBytes)) }
        #expect(quota.liveBytes == 0)
        let work = LibertyCodecTestResources(maximumLiveBytes: 4096,
            maximumTemporaryBytes: 4096, maximumWork: 3)
        do {
            let first = try await reader.read(input, resources: work)
            withExtendedLifetime(first) {}
            _ = try await reader.read(input, resources: work)
            Issue.record("Second read reset the caller work counter")
        } catch { #expect(error as? LibertyCodecTestResources.Failure == .work) }
        #expect(work.work == 2)
        #expect(work.liveBytes == 0)
        #expect(work.temporaryBytes == 0)
    }

    @Test func legacyReaderIsNotSilentlyGrantedControlledCapability() async throws {
        let bytes = Data("{}".utf8)
        let input = try binding(bytes)
        let reader: any TimingArtifactReading = LegacyReader(bytes: bytes)
        #expect(try await reader.read(input) == bytes)
        do {
            _ = try await reader.read(input, resources: LibertyCodecTestResources())
            Issue.record("Legacy reader gained uncontrolled strict success")
        } catch {
            guard case TimingTransformError.unsupportedCapability = error else {
                Issue.record("Expected controlled capability refusal: \(error)"); return
            }
        }
    }

    @Test func t1InMemoryHashRequiresTemporaryAdmission() async throws {
        let bytes = Data(repeating: 0x31, count: 4096)
        let input = try binding(bytes)
        let resources = LibertyCodecTestResources(maximumLiveBytes: 1_000_000,
            maximumTemporaryBytes: 0, maximumWork: 1_000_000)
        do {
            _ = try await InMemoryTimingArtifactReader(artifacts: [input.id: bytes])
                .read(input, resources: resources)
            Issue.record("In-memory identity hashing bypassed zero temporary capacity")
        } catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            #expect(cause as? LibertyCodecTestResources.Failure == .quota(.temporaryBytes))
        }
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func t1InMemoryHashWorkExceedsPayloadOnlyCharge() async throws {
        let bytes = Data(repeating: 0x32, count: 4096)
        let input = try binding(bytes)
        let resources = LibertyCodecTestResources(maximumLiveBytes: 1_000_000,
            maximumTemporaryBytes: 1_000_000, maximumWork: UInt64(bytes.count))
        do {
            _ = try await InMemoryTimingArtifactReader(artifacts: [input.id: bytes])
                .read(input, resources: resources)
            Issue.record("Payload-only work admitted an uncharged digest")
        } catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            #expect(cause as? LibertyCodecTestResources.Failure == .work)
        }
        #expect(resources.work <= UInt64(bytes.count))
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func t1InMemoryHashWorkAndCopiedReadLifetime() async throws {
        let bytes = Data(repeating: 0x33, count: 4096)
        let input = try binding(bytes)
        let reader = InMemoryTimingArtifactReader(artifacts: [input.id: bytes])
        let count = UInt64(bytes.count)
        let copyCost = try SHA256ContentDigester().foundationDataCopyCost(byteCount: count)
        let hashCost = try SHA256ContentDigester.managedCost(byteCount: count)
        let oneReadWork = count + copyCost.workUnits + hashCost.workUnits
        let resources = LibertyCodecTestResources(maximumLiveBytes: 1_000_000,
            maximumTemporaryBytes: 1_000_000, maximumWork: oneReadWork)
        var first: TimingArtifactRead? = try await reader.read(input, resources: resources)
        #expect(first?.data == bytes)
        #expect(first?.reference == input.reference)
        #expect(resources.work == oneReadWork)
        #expect(resources.temporaryBytes == 0)
        let retained = count + (try TimingArtifactRead.metadataBytes())
        #expect(resources.liveBytes == retained)
        var copied = first
        first = nil
        #expect(copied?.data == bytes)
        #expect(resources.liveBytes == retained)
        do {
            _ = try await reader.read(input, resources: resources)
            Issue.record("A second digest reset cumulative work")
        } catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            #expect(cause as? LibertyCodecTestResources.Failure == .work)
        }
        #expect(resources.work == oneReadWork)
        #expect(resources.liveBytes == retained)
        copied = nil
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test func t1InMemoryCancellationAtHashReservation() async throws {
        let bytes = Data(repeating: 0x34, count: 4096)
        let input = try binding(bytes)
        let resources = HashCancellingResources()
        do {
            _ = try await InMemoryTimingArtifactReader(artifacts: [input.id: bytes])
                .read(input, resources: resources)
            Issue.record("Cancellation at hash scratch reservation published bytes")
        } catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            #expect(cause as? HashCancellingResources.Failure == .cancelled)
        }
        #expect(resources.temporaryReservations == 1)
        #expect(resources.backing.liveBytes == 0)
        #expect(resources.backing.temporaryBytes == 0)
        #expect(resources.backing.reservationCount == resources.backing.releaseCount)
    }

    @Test(arguments: [false, true])
    func t1InMemoryDynamicFailureKeepsCauseAndCopiedOwner(mismatch: Bool) async throws {
        let bytes = Data("{}".utf8)
        let input = try longPathBinding(bytes)
        let reader = InMemoryTimingArtifactReader(artifacts:
            mismatch ? [input.id: Data("[]".utf8)] : [:])
        let expected = try await legacyFailure(reader, input: input)
        let resources = LibertyCodecTestResources(maximumLiveBytes: 1_000_000,
            maximumTemporaryBytes: 1_000_000, maximumWork: 1_000_000)
        var held: TimingControlledTransformFailure?
        do {
            _ = try await reader.read(input, resources: resources)
            Issue.record("Expected exact in-memory source failure")
        } catch let failure as TimingControlledTransformFailure {
            held = failure
        } catch {
            Issue.record("Dynamic source failure has no retained diagnostic owner: \(error)")
        }
        #expect(held?.cause as? TimingError == expected)
        let retained = resources.liveBytes
        #expect(retained >= UInt64(input.materializationDescription.utf8.count))
        #expect(resources.temporaryBytes == 0)
        var copied = held
        held = nil
        #expect(copied?.cause as? TimingError == expected)
        #expect(resources.liveBytes == retained)
        copied = nil
        #expect(resources.liveBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test(arguments: [false, true])
    func t1InMemoryDynamicFailurePathRequiresAdmission(mismatch: Bool) async throws {
        let bytes = Data("{}".utf8)
        let input = try longPathBinding(bytes)
        #expect(input.materializationDescription.utf8.count > 4096)
        let reader = InMemoryTimingArtifactReader(artifacts:
            mismatch ? [input.id: Data("[]".utf8)] : [:])
        let resources = LibertyCodecTestResources(maximumLiveBytes: 4096,
            maximumTemporaryBytes: 1_000_000, maximumWork: 1_000_000)
        do {
            _ = try await reader.read(input, resources: resources)
            Issue.record("Unadmitted diagnostic text produced a successful read")
        } catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            #expect(cause as? LibertyCodecTestResources.Failure == .quota(.liveOwnedBytes))
        }
        #expect(resources.liveBytes == 0)
        #expect(resources.temporaryBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    @Test(arguments: [false, true])
    func t1InMemoryServiceFailureOwnsCanonicalText(mismatch: Bool) async throws {
        let bytes = Data("{}".utf8)
        let local = try binding(bytes)
        let service = String(repeating: "service", count: 300)
        let namespace = String(repeating: "namespace", count: 300)
        let resource = String(repeating: "resource", count: 300)
        let input = try TimingArtifactBinding(reference: local.reference, availability: .service(
            artifactID: local.id, resource: .init(serviceID: .init(rawValue: service),
                namespaceID: .init(rawValue: namespace), resourceID: .init(rawValue: resource),
                generation: UInt64.max)))
        let path = "service:\(service)/\(namespace)/\(resource)@18446744073709551615"
        let expected: TimingError = mismatch ? .artifactDigestMismatch(path: path)
            : .artifactReadFailed(path: path,
                message: "No in-memory artifact was registered for the exact content identity.")
        let reader = InMemoryTimingArtifactReader(artifacts:
            mismatch ? [input.id: Data("[]".utf8)] : [:])
        let resources = LibertyCodecTestResources(maximumLiveBytes: 1_000_000,
            maximumTemporaryBytes: 1_000_000, maximumWork: 1_000_000)
        var held: TimingControlledTransformFailure?
        do {
            _ = try await reader.read(input, resources: resources)
            Issue.record("Expected canonical service source failure")
        } catch let failure as TimingControlledTransformFailure { held = failure }
        #expect(held?.cause as? TimingError == expected)
        let retained = resources.liveBytes
        #expect(retained >= UInt64(path.utf8.count))
        #expect(resources.temporaryBytes == 0)
        var copied = held
        held = nil
        #expect(copied?.cause as? TimingError == expected)
        #expect(resources.liveBytes == retained)
        copied = nil
        #expect(resources.liveBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)

        let quota = LibertyCodecTestResources(maximumLiveBytes: 4096,
            maximumTemporaryBytes: 1_000_000, maximumWork: 1_000_000)
        #expect(path.utf8.count > 4096)
        do {
            _ = try await reader.read(input, resources: quota)
            Issue.record("Service diagnostic text bypassed the live-byte quota")
        } catch {
            let cause = (error as? TimingControlledTransformFailure)?.cause ?? error
            #expect(cause as? LibertyCodecTestResources.Failure == .quota(.liveOwnedBytes))
        }
        #expect(quota.liveBytes == 0)
        #expect(quota.temporaryBytes == 0)
        #expect(quota.reservationCount == quota.releaseCount)

        if mismatch {
            let success = LibertyCodecTestResources()
            var result: TimingArtifactRead? = try await InMemoryTimingArtifactReader(artifacts: [input.id: bytes])
                .read(input, resources: success)
            let count = UInt64(bytes.count)
            let copyCost = try SHA256ContentDigester().foundationDataCopyCost(byteCount: count)
            let hashCost = try SHA256ContentDigester.managedCost(byteCount: count)
            #expect(result?.data == bytes)
            #expect(result?.reference == input.reference)
            #expect(success.work == count + copyCost.workUnits + hashCost.workUnits)
            #expect(success.liveBytes == count + (try TimingArtifactRead.metadataBytes()))
            #expect(success.temporaryBytes == 0)
            result = nil
            #expect(success.liveBytes == 0)
            #expect(success.reservationCount == success.releaseCount)
        }
    }

    @Test func t1InMemoryOversizedReferenceIsAnAnchoredTypedFailure() async throws {
        let bytes = Data([0x31])
        let ordinary = try binding(bytes)
        // The public CF constructors permit all UInt64 content byte counts.
        let reference = try ArtifactReference(digest: ordinary.digest, byteCount: UInt64.max,
            descriptor: ordinary.descriptor)
        let input = try TimingArtifactBinding(reference: reference, availability: .local(
            artifactID: reference.id,
            rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier),
            relativePath: .init(segments: ["oversized.json"])))
        let resources = LibertyCodecTestResources()
        var held: TimingControlledTransformFailure?
        do {
            _ = try await InMemoryTimingArtifactReader(artifacts: [input.id: bytes])
                .read(input, resources: resources)
            Issue.record("An unrepresentable source size must produce a typed failure")
        } catch let failure as TimingControlledTransformFailure { held = failure }
        let expected = TimingError.invalidInput("Controlled in-memory artifact byte counts must fit Int64.")
        #expect(held?.cause as? TimingError == expected)
        let retained = resources.liveBytes
        #expect(retained > 0)
        #expect(resources.temporaryBytes == 0)
        var copied = held
        held = nil
        #expect(copied?.cause as? TimingError == expected)
        #expect(resources.liveBytes == retained)
        copied = nil
        #expect(resources.liveBytes == 0)
        #expect(resources.reservationCount == resources.releaseCount)
    }

    private func longPathBinding(_ bytes: Data) throws -> TimingArtifactBinding {
        let input = try binding(bytes)
        return try .init(reference: input.reference, availability: .local(artifactID: input.id,
            rootID: .init(rawValue: TimingArtifactBinding.workspaceRootIdentifier),
            relativePath: .init(segments: (0..<4).map { String($0) + String(repeating: "part", count: 512) })))
    }

    private func legacyFailure(_ reader: InMemoryTimingArtifactReader,
        input: TimingArtifactBinding) async throws -> TimingError {
        var cause: TimingError?
        do {
            _ = try await reader.read(input)
            Issue.record("Fixture must fail through the legacy identity check")
        } catch let error as TimingError { cause = error }
        return try #require(cause)
    }

    private struct LegacyReader: TimingArtifactReading {
        let bytes: Data
        func read(_ artifact: TimingArtifactBinding) async throws -> Data { bytes }
    }

    private final class HashCancellingResources: LibertySourceResourceAccounting {
        enum Failure: Error, Sendable, Equatable { case cancelled }
        private struct State { var cancelled = false; var temporaryReservations = 0 }
        private let state = Mutex(State())
        let backing = LibertyCodecTestResources()
        var temporaryReservations: Int { state.withLock { $0.temporaryReservations } }
        func check() throws {
            if state.withLock({ $0.cancelled }) { throw Failure.cancelled }
            try backing.check()
        }
        func chargeWork(_ amount: UInt64) throws {
            try check()
            try backing.chargeWork(amount)
        }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws
            -> LibertySourceStorageReservation {
            try check()
            let lease = try backing.reserveStorage(kind: kind, byteCount: byteCount)
            if kind == .temporaryBytes {
                state.withLock { $0.temporaryReservations += 1; $0.cancelled = true }
            }
            return lease
        }
    }

    private final class CancellingResources: LibertySourceResourceAccounting {
        enum Failure: Error, Sendable, Equatable { case cancelled }
        private struct State { var cancelled = false; var live: UInt64 = 0; var reservations = 0 }
        private let state = Mutex(State())
        var liveBytes: UInt64 { state.withLock { $0.live } }
        var reservations: Int { state.withLock { $0.reservations } }
        func check() throws {
            if state.withLock({ $0.cancelled }) { throw Failure.cancelled }
        }
        func chargeWork(_ amount: UInt64) throws { try check() }
        func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws
            -> LibertySourceStorageReservation {
            try check()
            state.withLock { $0.live += byteCount; $0.reservations += 1; $0.cancelled = true }
            return .init(kind: kind, byteCount: byteCount) { [self] in
                state.withLock { $0.live -= byteCount }
            }
        }
    }
}

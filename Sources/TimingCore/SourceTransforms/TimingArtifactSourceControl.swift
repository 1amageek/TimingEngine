import CircuiteFoundationFileSystem
import Synchronization

/// One read invocation; callbacks are never invoked under the first-error lock.
internal final class TimingArtifactSourceControl: ArtifactSourceControl, Sendable {
    private let resources: any LibertySourceResourceAccounting
    private let first = Mutex<(any Error)?>(nil)
    private let metadata: LibertySourceStorageReservation
    private static let sentinel = "Timing caller resource admission failed"

    init(resources: any LibertySourceResourceAccounting) throws {
        self.resources = resources
        try resources.check()
        let bytes = try LibertySourceCapacity.byteCount(of:
            (any LibertySourceResourceAccounting, LibertySourceStorageReservation).self, capacity: 1)
        let lockBytes = UInt64(MemoryLayout<Mutex<(any Error)?>>.stride)
        let total = bytes.addingReportingOverflow(lockBytes)
        guard !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        metadata = try resources.reserveStorage(kind: .temporaryBytes, byteCount: total.partialValue)
        try resources.check()
    }

    func check() throws(ArtifactSourceControlError) {
        do { try resources.check() }
        catch { throw record(error) }
    }

    func charge(_ work: ArtifactSourceWork) throws(ArtifactSourceControlError) {
        do {
            try resources.check()
            // Byte reads and digest bytes are explicit operations in addition
            // to CF traversal/page bookkeeping. Never infer a byte cost from
            // a page-count multiplier.
            let read = work.workUnits.addingReportingOverflow(work.readBytes)
            let total = read.partialValue.addingReportingOverflow(work.hashedBytes)
            guard !read.overflow, !total.overflow else { throw LibertySourceError.arithmeticOverflow }
            if total.partialValue > 0 { try resources.chargeWork(total.partialValue) }
            try resources.check()
        } catch { throw record(error) }
    }

    func retain(_ extent: ArtifactSourceExtent) throws(ArtifactSourceControlError)
        -> any ArtifactSourceRetention {
        do {
            try resources.check()
            let kind: LibertySourceStorageKind
            let bytes: UInt64
            switch extent {
            case .ownedBytes(let count): kind = .liveOwnedBytes; bytes = count
            case .temporaryBytes(let count): kind = .temporaryBytes; bytes = count
            case .openResources(let count):
                kind = .temporaryBytes
                let product = count.multipliedReportingOverflow(by: UInt64(MemoryLayout<Int32>.stride))
                guard !product.overflow else { throw LibertySourceError.arithmeticOverflow }
                bytes = product.partialValue
            }
            let reservation = try resources.reserveStorage(kind: kind, byteCount: bytes)
            try resources.check()
            let metadata = try resources.reserveStorage(kind: kind, byteCount:
                LibertySourceCapacity.byteCount(of: (LibertySourceStorageReservation,
                    LibertySourceStorageReservation).self, capacity: 1))
            try resources.check()
            return Retention(reservation: reservation, metadata: metadata)
        } catch { throw record(error) }
    }

    func preservingCause(_ error: any Error) -> any Error {
        guard let cause = first.withLock({ $0 }) else { return error }
        if let discovery = error as? ArtifactSourceDiscoveryError {
            switch discovery {
            case .cleanupFailed, .digestAbortFailed:
                return TimingTransformError.cleanupFailed(primary: cause, secondary: discovery)
            default: break
            }
        }
        return cause
    }

    private func record(_ error: any Error) -> ArtifactSourceControlError {
        first.withLock { if $0 == nil { $0 = error } }
        return .unsupportedCapability(reason: Self.sentinel)
    }

    private final class Retention: ArtifactSourceRetention, Sendable {
        let reservation: LibertySourceStorageReservation
        let metadata: LibertySourceStorageReservation
        init(reservation: LibertySourceStorageReservation, metadata: LibertySourceStorageReservation) {
            self.reservation = reservation; self.metadata = metadata
        }
    }
}

import PDKCore
import Synchronization
import TimingCore

/// Adapts the existing invocation owner; no new work/storage/deadline budget.
internal final class NativeSTAPDKAccounting: PDKAdmissionResourceAccounting, Sendable {
    private struct State { var first: (any Error)?; var nesting: UInt64 = 0 }
    private let state = Mutex(State())
    private let resources: any LibertySourceResourceAccounting
    private let maximumNesting: UInt64
    private let metadata: LibertySourceStorageReservation
    private let failureMetadata: LibertySourceStorageReservation
    private static let sentinel = "Timing caller resource admission failed"

    init(resources: any LibertySourceResourceAccounting, maximumNesting: Int) throws {
        guard maximumNesting > 0 else { throw LibertySourceError.invalidLimit }
        self.resources = resources
        self.maximumNesting = UInt64(maximumNesting)
        try resources.check()
        let fields = UInt64(MemoryLayout<(any LibertySourceResourceAccounting,
            UInt64, LibertySourceStorageReservation, LibertySourceStorageReservation)>.stride)
        let bytes = fields.addingReportingOverflow(UInt64(MemoryLayout<Mutex<State>>.stride))
        guard !bytes.overflow else { throw LibertySourceError.arithmeticOverflow }
        metadata = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes.partialValue)
        try resources.check()
        failureMetadata = try resources.reserveStorage(kind: .liveOwnedBytes,
            byteCount: TimingControlledTransformFailure.storageByteCount())
        try resources.check()
    }

    func check() throws(PDKAdmissionResourceError) {
        do { try resources.check() }
        catch { throw record(error) }
    }

    func charge(_ cost: PDKAdmissionCost) throws(PDKAdmissionResourceError) {
        guard !cost.dimension.isLiveCapacity else { throw .invalidCost }
        switch cost.dimension {
        case .parserWork, .decodedElements, .scalarBytes, .diagnosticEntries, .diagnosticBytes:
            do {
                try resources.check()
                try resources.chargeWork(cost.amount)
                try resources.check()
            } catch { throw record(error) }
        default: throw .unsupportedBudgetCapability("Dimension is outside raw Timing JSON decoding")
        }
    }

    func reserve(_ cost: PDKAdmissionCost) throws(PDKAdmissionResourceError) -> PDKAdmissionReservation {
        guard cost.accountingVersion == PDKAdmissionCost.currentAccountingVersion else {
            throw .unsupportedAccountingVersion(cost.accountingVersion)
        }
        guard cost.amount > 0 else { throw .invalidCost }
        if !cost.dimension.isLiveCapacity {
            try charge(cost)
            return .init(cost: cost, onRelease: {})
        }
        if cost.dimension == .decodeNesting {
            try check()
            try state.withLock { state throws(PDKAdmissionResourceError) in
                let next = state.nesting.addingReportingOverflow(cost.amount)
                guard !next.overflow else { throw .arithmeticOverflow(.decodeNesting) }
                guard next.partialValue <= maximumNesting else {
                    throw .exhausted(dimension: .decodeNesting, limit: maximumNesting,
                        attempted: next.partialValue)
                }
                state.nesting = next.partialValue
            }
            do {
                let lease = try bridgeMetadata(kind: .temporaryBytes)
                try check()
                return .init(cost: cost) { [self] in
                    state.withLock { $0.nesting -= cost.amount }
                    withExtendedLifetime(lease) {}
                }
            } catch {
                state.withLock { $0.nesting -= cost.amount }
                throw error
            }
        }
        let kind: LibertySourceStorageKind
        switch cost.dimension {
        case .liveOwnedBytes: kind = .liveOwnedBytes
        case .temporaryBytes: kind = .temporaryBytes
        default: throw .unsupportedBudgetCapability("Capacity is outside raw Timing JSON decoding")
        }
        do {
            try resources.check()
            let lease = try resources.reserveStorage(kind: kind, byteCount: cost.amount)
            try resources.check()
            let metadata = try bridgeMetadata(kind: kind)
            try resources.check()
            return .init(cost: cost) { withExtendedLifetime((lease, metadata)) {} }
        } catch let error as PDKAdmissionResourceError { throw error }
        catch { throw record(error) }
    }

    func preservingCause(_ error: any Error, domainCause: (any Error)? = nil) -> any Error {
        guard let cause = state.withLock({ $0.first }) ?? domainCause else { return error }
        // The complete PDKControlledDecodeFailure owns source-derived error
        // strings/reservations. Never unwrap its cause and discard those anchors.
        return TimingControlledTransformFailure(cause: cause, retaining: error,
            metadata: failureMetadata)
    }

    /// The saved-decode control already holds the complete lower error in its
    /// prepaid fixed slot. This path transfers that owner without new callbacks.
    func preservingCause(_ error: any Error, domainCause: (any Error)?,
        retaining control: NativeSTAContentDigestControl) -> TimingControlledTransformFailure {
        let cause = state.withLock({ $0.first }) ?? domainCause ?? error
        return TimingControlledTransformFailure(cause: cause, retaining: control,
            metadata: failureMetadata)
    }

    private func bridgeMetadata(kind: LibertySourceStorageKind) throws(PDKAdmissionResourceError)
        -> LibertySourceStorageReservation {
        do {
            try resources.check()
            let bytes = try LibertySourceCapacity.byteCount(of:
                (PDKAdmissionCost, LibertySourceStorageReservation,
                    LibertySourceStorageReservation, NativeSTAPDKAccounting).self, capacity: 1)
            let result = try resources.reserveStorage(kind: kind, byteCount: bytes)
            try resources.check()
            return result
        } catch { throw record(error) }
    }

    private func record(_ error: any Error) -> PDKAdmissionResourceError {
        state.withLock { if $0.first == nil { $0.first = error } }
        return .unsupportedBudgetCapability(Self.sentinel)
    }
}

import CircuiteFoundation
import PDKCore
import Synchronization

/// One saved-decode retention owner forwarding the existing invocation accountant.
internal final class NativeSTAContentDigestControl: ContentDigestConstructionControl {
    private struct State {
        var receipts: [PDKAdmissionReservation] = []
        var backing: PDKAdmissionReservation?
        var failure: (any Error)?
    }
    private struct TemporaryLease: Sendable {
        let receipt: PDKAdmissionReservation
        let metadata: PDKAdmissionReservation
    }
    private struct Storage: ~Copyable, Sendable {
        let accounting: NativeSTAPDKAccounting
        let metadata: PDKAdmissionReservation
        let state = Mutex(State())
    }
    private let storage: Storage
    private var accounting: NativeSTAPDKAccounting { storage.accounting }

    static func make(accounting: NativeSTAPDKAccounting) throws(PDKAdmissionResourceError)
        -> NativeSTAContentDigestControl {
        try accounting.check()
        let metadata = try accounting.reserve(.init(dimension: .liveOwnedBytes,
            amount: UInt64(MemoryLayout<Storage>.stride)))
        try accounting.check()
        return NativeSTAContentDigestControl(accounting: accounting, metadata: metadata)
    }

    private init(accounting: NativeSTAPDKAccounting, metadata: PDKAdmissionReservation) {
        self.storage = Storage(accounting: accounting, metadata: metadata)
    }

    func check() throws(PDKAdmissionResourceError) { try accounting.check() }

    func charge(workUnits: UInt64) throws(PDKAdmissionResourceError) {
        try accounting.check()
        if workUnits > 0 { try accounting.charge(.init(dimension: .parserWork, amount: workUnits)) }
        try accounting.check()
    }

    func reserveTemporary(byteCount: UInt64) throws(PDKAdmissionResourceError) -> any Sendable {
        try accounting.check()
        let metadata = try accounting.reserve(.init(dimension: .temporaryBytes,
            amount: UInt64(MemoryLayout<TemporaryLease>.stride)))
        try accounting.check()
        let receipt = try accounting.reserve(.init(dimension: .temporaryBytes, amount: byteCount))
        try accounting.check()
        // Include the concrete payload of the opaque returned owner, rather
        // than treating existential storage as a free pointer-only conversion.
        return TemporaryLease(receipt: receipt, metadata: metadata)
    }

    func reserveRetained(byteCount: UInt64) throws(PDKAdmissionResourceError) {
        try accounting.check()
        let receipt = try accounting.reserve(.init(dimension: .liveOwnedBytes, amount: byteCount))
        try accounting.check()
        while true {
            try charge(workUnits: 1)
            let required = try storage.state.withLock { value throws(PDKAdmissionResourceError) in
                let next = value.receipts.count.addingReportingOverflow(1)
                guard !next.overflow else { throw .arithmeticOverflow(.liveOwnedBytes) }
                return next.partialValue > value.receipts.capacity ? next.partialValue : 0
            }
            let capacity: Int
            let backing: PDKAdmissionReservation?
            if required > 0 {
                let doubled = required.multipliedReportingOverflow(by: 2)
                guard !doubled.overflow else { throw .arithmeticOverflow(.liveOwnedBytes) }
                capacity = doubled.partialValue
                let bytes = UInt64(capacity).multipliedReportingOverflow(
                    by: UInt64(MemoryLayout<PDKAdmissionReservation>.stride))
                guard !bytes.overflow else { throw .arithmeticOverflow(.liveOwnedBytes) }
                backing = try accounting.reserve(.init(dimension: .liveOwnedBytes, amount: bytes.partialValue))
                try accounting.check()
            } else { capacity = 0; backing = nil }
            let published = storage.state.withLock { value -> (Bool, PDKAdmissionReservation?) in
                let next = value.receipts.count.addingReportingOverflow(1)
                guard !next.overflow else { return (false, nil) }
                if next.partialValue > value.receipts.capacity {
                    guard let backing, capacity >= next.partialValue else { return (false, nil) }
                    let previous = value.backing
                    value.receipts.reserveCapacity(capacity)
                    value.backing = backing
                    value.receipts.append(receipt)
                    return (true, previous)
                }
                value.receipts.append(receipt)
                return (true, nil)
            }
            // Old or raced/rejected backing can release caller capacity only
            // outside the state lock. No caller callback runs in that lock.
            withExtendedLifetime(published.1) {}
            if published.0 { return }
        }
    }

    func retainFailure(_ failure: any Error) {
        // The single terminal failure was already boxed by its throwing owner.
        // This fixed slot was admitted before decoding; no post-error callbacks.
        storage.state.withLock { $0.failure = failure }
    }
}

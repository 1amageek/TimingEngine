import Foundation
import Synchronization
import TimingCore
#if os(macOS) && canImport(Darwin)
import Darwin
#endif

/// One synchronous native lease owns bounded raw allocation accounting.
/// The gate owns one active route until every native allocation is released.
/// Routing state stores integer identities only; each native pointer has one matching malloc/free.
/// Checked byte counts and 16-byte alignment precede use. Routing performs only synchronized
/// memory operations and never retains a borrowed matrix/RHS pointer.
internal enum NativeSTAConservativeNativeAllocation {
    typealias N = NativeSTAConservativeNumerics
    struct Policy {
        var quotaBytes: Int? = nil
        var recordCapacity: Int? = nil
        var failAfterAllocations: Int? = nil
    }
    struct Statistics: Sendable {
        let cumulativeBytes: Int
        let peakLiveBytes: Int
        let allocations: Int
        let outstandingAllocations: Int
    }
    private struct Record: Sendable {
        var address: UInt = 0
        var bytes: Int = 0
    }
    private enum FailureKind: Sendable, Equatable { case backend, quota, records }
    private struct Routing: Sendable {
        var active = false
        var quota = 0
        var metadataBytes = 0
        var cumulative = 0
        var live = 0
        var peak = 0
        var nextRecord = 0
        var failure: String? = nil
        var failureKind = FailureKind.backend
        var failAfter: Int? = nil
        var requestedBytes = 0
        var records: [Record] = []
        var diagnostics: TimingControlledDiagnostics<NativeSTAStateBudget>?
    }
    private struct PermitState: Sendable {
        var owner: ObjectIdentifier?
    }
    private static let gate = Mutex(PermitState())
    // NSCondition supplies blocking wake/wait only. The canonical owner is in gate.
    private static let wake = NSCondition()

    private static func acquire() throws {
        let identity = ObjectIdentifier(Thread.current)
        wake.lock()
        defer { wake.unlock() }
        while true {
            let acquired = try gate.withLock { state in
                guard state.owner != identity else { throw invalid("recursive native allocation lease") }
                guard state.owner == nil else { return false }
                state.owner = identity
                return true
            }
            if acquired { return }
            wake.wait()
        }
    }

    private static func releasePermit() {
        wake.lock()
        gate.withLock { $0.owner = nil }
        wake.broadcast()
        wake.unlock()
    }
    private static let routing = Mutex(Routing())

    static func withLease<R>(dimension: Int, nonzeros: Int, numerical: N,
                             policy: Policy = .init(), work: inout UInt64,
                             body: (inout UInt64) throws -> R) throws -> (R, Statistics) {
        try numerical.tick(&work, 0)
        let diagnostics = try numerical.diagnostics(retaining: numerical.budget)
        // Routing may drop its copy under its lock; this frame keeps the final owner outside it.
        defer { withExtendedLifetime(diagnostics) {} }
        let count = dimension.addingReportingOverflow(nonzeros)
        guard dimension > 0, nonzeros >= 0, !count.overflow else { throw invalid("native quota dimensions") }
        let reservedSlots = numerical.limits.maximumPathStates / 4
        let computed = reservedSlots.multipliedReportingOverflow(by: 8)
        guard !computed.overflow else { throw self.capacity("native quota bytes overflow", limit: numerical.limits.maximumPathStates) }
        let quota = policy.quotaBytes ?? computed.partialValue
        let capacity = policy.recordCapacity ?? (quota / (16 * MemoryLayout<Record>.stride))
        let metadata = capacity.multipliedReportingOverflow(by: MemoryLayout<Record>.stride)
        guard quota > 0 else { throw self.capacity("native quota bytes", limit: max(quota, 0)) }
        guard capacity > 0, !metadata.overflow, metadata.partialValue <= quota else {
            throw self.capacity("native callback allocation records", limit: max(capacity, 0))
        }
        let rounded = quota.addingReportingOverflow(7)
        guard !rounded.overflow else { throw self.capacity("native quota slot overflow", limit: quota) }
        try numerical.slots(rounded.partialValue / 8)
        let metadataPayload = try numerical.budget.reservePayload(Record.self, capacity: capacity, kind: .temporaryBytes)
        defer { withExtendedLifetime(metadataPayload) {} }
        try acquire()
        defer { releasePermit() }
        // Resource callbacks are deliberately outside both synchronization locks.
        try numerical.tick(&work, 0)
        try numerical.budget.chargeScheduledWork(UInt64(capacity))
        var records = Array(repeating: Record(), count: capacity)
        routing.withLock { state in
                state = Routing()
                swap(&state.records, &records)
                state.quota = quota; state.metadataBytes = metadata.partialValue
                state.cumulative = metadata.partialValue; state.live = metadata.partialValue
                state.peak = metadata.partialValue; state.failAfter = policy.failAfterAllocations
                state.diagnostics = diagnostics
                state.active = true
            }
            do {
                let result = try body(&work)
                try check()
                let statistics = finish()
                guard statistics.outstandingAllocations == 0 else { throw invalid("native allocation escaped cleanup") }
                try numerical.tick(&work, 0)
                return (result, statistics)
            } catch {
                _ = finish()
                throw error
            }
    }

    static func check() throws {
        let snapshot = routing.withLock { state in
            (state.active, state.failure, state.requestedBytes, state.cumulative, state.live,
             state.peak, state.quota, state.nextRecord, state.records.count, state.failureKind, state.diagnostics)
        }
        guard snapshot.0 else { throw invalid("native operation outside allocation lease") }
        if let failure = snapshot.1 {
            func construct() -> any Error {
                let detail = "\(failure); requested=\(snapshot.2), cumulative=\(snapshot.3), live=\(snapshot.4), peak=\(snapshot.5), quota=\(snapshot.6), allocations=\(snapshot.7), records=\(snapshot.8)"
                switch snapshot.9 {
                case .backend: return invalid(detail)
                case .quota: return capacity("native quota bytes: " + detail, limit: snapshot.6)
                case .records: return capacity("native callback allocation records: " + detail, limit: snapshot.8)
                }
            }
            if let diagnostics = snapshot.10 {
                let detail = try TimingDiagnosticTextCapacity.description(literal: "; requested=, cumulative=, live=, peak=, quota=, allocations=, records=",
                    ints: 7, doubles: 0, booleans: 0, additionalUTF8: UInt64(failure.utf8.count))
                let bytes: UInt64
                switch snapshot.9 {
                case .backend: bytes = detail
                case .quota, .records:
                    let three = detail.multipliedReportingOverflow(by: 3)
                    guard !three.overflow else { throw LibertySourceError.arithmeticOverflow }
                    let prefix: UInt64 = snapshot.9 == .quota
                        ? UInt64("native quota bytes: native quota bytes: conservative RC ".utf8.count)
                        : UInt64("native callback allocation records: native callback allocation records: conservative RC ".utf8.count)
                    let sum = three.partialValue.addingReportingOverflow(prefix)
                    guard !sum.overflow else { throw LibertySourceError.arithmeticOverflow }
                    bytes = sum.partialValue
                }
                throw try diagnostics.sourceFailure(utf8ByteCount: bytes, construct)
            }
            throw construct()
        }
    }

    /// The pointer is owned by this lease; only its integer identity enters shared accounting.
    static func allocate(_ bytes: Int) throws -> UnsafeMutableRawPointer {
        #if os(macOS) && canImport(Darwin)
        guard bytes >= 0, let pointer = allocateFromC(bytes) else {
            try check()
            throw invalid("native allocation failed")
        }
        return pointer
        #else
        throw NativeSTAConservativeCouplingError.unsupportedNativeCapability("Native macOS allocation unavailable")
        #endif
    }

    static func release(_ pointer: UnsafeMutableRawPointer?) {
        #if os(macOS) && canImport(Darwin)
        releaseFromC(pointer)
        #endif
    }

    #if os(macOS) && canImport(Darwin)
    private static func allocateFromC(_ requested: Int) -> UnsafeMutableRawPointer? {
        routing.withLock { state in
            guard state.active, state.failure == nil else { return nil }
            state.requestedBytes = requested
            let bytes = max(requested, 1)
            let total = state.cumulative.addingReportingOverflow(bytes)
            let live = state.live.addingReportingOverflow(bytes)
            guard requested >= 0 else { state.failure = "native allocator received negative bytes"; return nil }
            guard !total.overflow, !live.overflow, total.partialValue <= state.quota, live.partialValue <= state.quota else {
                state.failureKind = .quota; state.failure = "native allocation quota exceeded"; return nil
            }
            guard state.nextRecord < state.records.count else {
                state.failureKind = .records; state.failure = "native allocation record capacity exceeded"; return nil
            }
            if let failAfter = state.failAfter, state.nextRecord >= failAfter {
                state.failure = "injected native allocation failure"; return nil
            }
            guard let pointer = Darwin.malloc(bytes) else { state.failure = "native malloc failed"; return nil }
            guard UInt(bitPattern: pointer) & 15 == 0 else {
                Darwin.free(pointer); state.failure = "native allocation is not 16-byte aligned"; return nil
            }
            state.records[state.nextRecord] = Record(address: UInt(bitPattern: pointer), bytes: bytes)
            state.nextRecord += 1; state.cumulative = total.partialValue
            state.live = live.partialValue; state.peak = max(state.peak, state.live)
            return pointer
        }
    }

    private static func releaseFromC(_ pointer: UnsafeMutableRawPointer?) {
        guard let pointer else { return }
        routing.withLock { state in
            guard state.active else { return }
            let address = UInt(bitPattern: pointer)
            for i in 0..<state.nextRecord where state.records[i].address == address {
                state.live -= state.records[i].bytes
                state.records[i] = Record()
                Darwin.free(pointer)
                return
            }
            state.failure = state.failure ?? "native cleanup returned an unknown allocation"
        }
    }

    #endif

    /// All factor owners have already released their storage before this final ownership sweep.
    private static func finish() -> Statistics {
        routing.withLock { state in
            var outstanding = 0
            for i in 0..<state.nextRecord where state.records[i].address != 0 {
                outstanding += 1
                #if os(macOS) && canImport(Darwin)
                Darwin.free(UnsafeMutableRawPointer(bitPattern: state.records[i].address))
                #endif
                state.records[i] = Record()
            }
            let result = Statistics(cumulativeBytes: state.cumulative, peakLiveBytes: state.peak,
                allocations: state.nextRecord, outstandingAllocations: outstanding)
            state = Routing()
            return result
        }
    }

    private static func capacity(_ resource: String, limit: Int) -> STAPathAnalysisError {
        .capacity(resource: "conservative RC " + resource, limit: UInt64(max(limit, 0)))
    }

    private static func invalid(_ detail: String) -> NativeSTAConservativeCouplingError {
        .nativeBackendFailure(detail)
    }
}

import TimingCore

/// Construction-only sparse rows. Each growing hash buffer owns its actual payload lease.
internal struct NativeSTAConservativeRowStorage: RandomAccessCollection {
    typealias I = TimingNumericInterval
    typealias N = NativeSTAConservativeNumerics
    private var rows: [[Int: I]]
    private var payloads: [LibertySourceStorageReservation?]?
    private let rowMetadata: LibertySourceStorageReservation?
    private let payloadMetadata: LibertySourceStorageReservation?
    private let numerical: N
    var startIndex: Int { rows.startIndex }
    var endIndex: Int { rows.endIndex }
    subscript(index: Int) -> [Int: I] { rows[index] }

    init(count: Int, numerical: N) throws {
        self.numerical = numerical
        rowMetadata = try numerical.budget.reservePayload([Int: I].self, capacity: count, kind: .temporaryBytes)
        payloadMetadata = try numerical.budget.reservePayload(LibertySourceStorageReservation?.self, capacity: count, kind: .temporaryBytes)
        if numerical.budget.transformResources != nil { try Task.checkCancellation() }
        try numerical.budget.chargeScheduledWork(UInt64(count))
        rows = Array(repeating: [:], count: count)
        try numerical.budget.chargeScheduledWork(UInt64(count))
        payloads = numerical.budget.transformResources == nil ? nil : Array(repeating: nil, count: count)
    }

    mutating func set(_ value: I, row: Int, column: Int) throws {
        guard numerical.budget.transformResources != nil else { rows[row][column] = value; return }
        if rows[row][column] == nil, rows[row].count == rows[row].capacity {
            let old = rows[row]
            let oldPayload = payloads?[row]
            defer { withExtendedLifetime((old, oldPayload)) {} }
            let doubled = Swift.max(1, old.capacity).multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { throw LibertySourceError.arithmeticOverflow }
            let capacity = doubled.partialValue
            let bytes = try TimingTransformCapacity.dictionary(Int.self, I.self, minimumCapacity: capacity)
            guard let resources = numerical.budget.transformResources else { throw LibertySourceError.invalidCapacity }
            try resources.check()
            let payload = try resources.reserveStorage(kind: .temporaryBytes, byteCount: bytes)
            try resources.check()
            var replacement: [Int: I] = [:]
            replacement.reserveCapacity(capacity)
            for (key, entry) in old {
                try Task.checkCancellation(); try numerical.budget.chargeScheduledWork(1)
                replacement[key] = entry
            }
            rows[row] = replacement
            payloads?[row] = payload
        }
        try Task.checkCancellation(); try numerical.budget.chargeScheduledWork(1)
        rows[row][column] = value
    }

    mutating func add(_ value: I, row: Int, column: Int) throws {
        if let old = rows[row][column] { try set(old.adding(value), row: row, column: column) }
        else { try set(value, row: row, column: column) }
    }
}

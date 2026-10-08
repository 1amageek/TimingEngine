/// String-keyed logical entry capacity, with reserved same-capacity COW migration.
struct LibertyMap<Value: Sendable>: Sendable {
    private var values: [String: Value] = [:]
    private var capacity = 0
    private var receipt: LibertySourceStorageReservation?
    private var identity = Identity()
    var isEmpty: Bool { values.isEmpty }
    var count: Int { values.count }

    func value(for key: String, storage: LibertyParseStorage?) throws -> Value? {
        try Self.key(key, storage: storage); return values[key]
    }
    mutating func set(_ value: Value, for key: String, storage: LibertyParseStorage?) throws {
        try Self.key(key, storage: storage)
        let additional = values[key] == nil ? 1 : 0
        let needed = try LibertyParseStorage.add(count, additional)
        if needed > capacity || !isKnownUniquelyReferenced(&identity) {
            let next: Int
            if needed > capacity {
                let (doubled, overflow) = capacity.multipliedReportingOverflow(by: 2)
                guard !overflow else { throw LibertySourceError.arithmeticOverflow }
                next = Swift.max(needed, doubled)
            } else { next = capacity }
            let reservation = try storage?.reserve((String, Value).self, capacity: next, kind: .temporaryBytes)
            var copy = Dictionary<String, Value>(minimumCapacity: next)
            for (key, value) in values { try Self.key(key, storage: storage); copy[key] = value }
            values = copy; capacity = next; receipt = reservation; identity = Identity()
        }
        values[key] = value
    }
    func dictionary(storage: LibertyParseStorage?) throws -> [String: Value] {
        let reservation = try storage?.reserve((String, Value).self, capacity: count)
        var result = Dictionary<String, Value>(minimumCapacity: count)
        for (key, value) in values { try Self.key(key, storage: storage); result[key] = value }
        if let storage, let reservation { try storage.hold(result, receipt: reservation) }
        return result
    }
    private static func key(_ key: String, storage: LibertyParseStorage?) throws {
        try storage?.step(); for _ in key.utf8 { try storage?.step() }
    }
    private final class Identity: Sendable {}
}

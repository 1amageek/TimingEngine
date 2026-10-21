import TimingCore

/// Concrete buffer admission for the run-local distributed operator.
internal enum NativeSTADistributedRCPayload {
    static func dictionary<Key: Hashable, Value>(_ key: Key.Type, _ value: Value.Type,
        capacity: Int, storage: NativeSTATransformStorage) throws -> [Key: Value] {
        try storage.reserveDictionary(key, value, capacity: capacity)
        var result: [Key: Value] = [:]
        if storage.budget.transformResources != nil { result.reserveCapacity(capacity) }
        return result
    }

    static func set<Element: Hashable>(_ type: Element.Type, capacity: Int,
        storage: NativeSTATransformStorage) throws -> Set<Element> {
        try storage.reserveSet(type, capacity: capacity)
        var result = Set<Element>()
        if storage.budget.transformResources != nil { result.reserveCapacity(capacity) }
        return result
    }

    static func array<Element>(_ type: Element.Type, capacity: Int,
        storage: NativeSTATransformStorage) throws -> [Element] {
        try storage.reserve(type, capacity: capacity)
        var result: [Element] = []
        if storage.budget.transformResources != nil { result.reserveCapacity(capacity) }
        return result
    }

    static func count(_ left: Int, _ right: Int) throws -> Int {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw LibertySourceError.arithmeticOverflow }
        return result.partialValue
    }

    static func dictionaryLease<Key, Value>(_ key: Key.Type, _ value: Value.Type,
        capacity: Int, budget: NativeSTAStateBudget) throws -> LibertySourceStorageReservation? {
        guard let resources = budget.transformResources else { return nil }
        let bytes = try TimingTransformCapacity.dictionary(key, value, minimumCapacity: capacity)
        try resources.check()
        let result = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        try resources.check()
        return result
    }
    static func inserting<Key: Hashable, Value>(_ value: Value, for key: Key,
        into original: [Key: Value], budget: NativeSTAStateBudget) throws
        -> (value: [Key: Value], lease: LibertySourceStorageReservation?) {
        let newCount = try count(original.count, original[key] == nil ? 1 : 0)
        let lease = try dictionaryLease(Key.self, Value.self, capacity: newCount, budget: budget)
        try budget.chargeScheduledWork(UInt64(original.count) + 1)
        var result: [Key: Value] = [:]; result.reserveCapacity(newCount)
        for (key, value) in original { result[key] = value }
        result[key] = value
        try budget.transformResources?.check()
        return (result, lease)
    }

    static func appending<C: Collection>(_ values: C, to original: [C.Element],
        budget: NativeSTAStateBudget) throws
        -> (value: [C.Element], lease: LibertySourceStorageReservation?) {
        let newCount = try count(original.count, values.count)
        let lease = try budget.reservePayload(C.Element.self, capacity: newCount, kind: .liveOwnedBytes)
        try budget.chargeScheduledWork(UInt64(newCount))
        var result: [C.Element] = []; result.reserveCapacity(newCount)
        result.append(contentsOf: original); result.append(contentsOf: values)
        try budget.transformResources?.check()
        return (result, lease)
    }

}

/// Private concrete slot capacity; immutable identity tracks array COW copies.
struct LibertyBuffer<Element: Sendable>: Sendable, RandomAccessCollection {
    private var slots: [Element?] = []
    private var receipt: LibertySourceStorageReservation?
    private var identity = Identity()
    let kind: LibertySourceStorageKind
    private(set) var endIndex = 0
    var startIndex: Int { 0 }
    var indices: Range<Int> { 0..<endIndex }
    var managedCapacity: Int { slots.count }
    init(kind: LibertySourceStorageKind = .temporaryBytes) { self.kind = kind }
    subscript(index: Int) -> Element {
        precondition(indices.contains(index)); return slots[index]!
    }
    func index(after i: Int) -> Int { i + 1 }
    func index(before i: Int) -> Int { i - 1 }

    mutating func append(_ value: Element, storage: LibertyParseStorage?) throws {
        try storage?.step()
        if endIndex == slots.count {
            let (doubled, overflow) = slots.count.multipliedReportingOverflow(by: 2)
            guard !overflow else { throw LibertySourceError.arithmeticOverflow }
            try migrate(Swift.max(1, doubled), storage: storage)
        } else if !isKnownUniquelyReferenced(&identity) {
            try migrate(slots.count, storage: storage)
        }
        slots[endIndex] = value; endIndex += 1
    }

    mutating func replace(at index: Int, with value: Element, storage: LibertyParseStorage?) throws {
        precondition(indices.contains(index)); try storage?.step()
        if !isKnownUniquelyReferenced(&identity) { try migrate(slots.count, storage: storage) }
        slots[index] = value
    }

    mutating func removeLast() -> Element {
        precondition(endIndex > 0)
        // A frame stack is invocation-local; callers remove only a unique snapshot.
        precondition(isKnownUniquelyReferenced(&identity))
        endIndex -= 1; let value = slots[endIndex]!; slots[endIndex] = nil; return value
    }

    func array(storage: LibertyParseStorage?, kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> [Element] {
        let lease = try storage?.reserve(Element.self, capacity: count, kind: kind)
        var result: [Element] = []; result.reserveCapacity(count)
        for value in self { try storage?.step(); result.append(value) }
        if let storage, let lease { try storage.hold(result, receipt: lease, kind: kind) }
        return result
    }

    private mutating func migrate(_ capacity: Int, storage: LibertyParseStorage?) throws {
        let lease = try storage?.reserve(Optional<Element>.self, capacity: capacity, kind: kind)
        try storage?.step(UInt64(capacity))
        var result = [Element?](repeating: nil, count: capacity)
        for index in indices { try storage?.step(); result[index] = slots[index] }
        slots = result; receipt = lease; identity = Identity()
    }
    private final class Identity: Sendable {}
}

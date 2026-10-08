/// Accounted mutable ASCII text on the owned path; ordinary Unicode behavior is preserved.
struct LibertyText: Sendable {
    private var value = ""
    private var capacity = 0
    private var receipt: LibertySourceStorageReservation?
    private var identity = Identity()
    var isEmpty: Bool { value.isEmpty }

    mutating func append(_ text: String, storage: LibertyParseStorage?) throws {
        guard let storage else { value += text; return }
        var additional = 0
        for _ in text.utf8 { try storage.step(); additional = try LibertyParseStorage.add(additional, 1) }
        let needed = try LibertyParseStorage.add(value.utf8.count, additional)
        if needed > capacity || !isKnownUniquelyReferenced(&identity) {
            let (doubled, overflow) = capacity.multipliedReportingOverflow(by: 2)
            guard !overflow else { throw LibertySourceError.arithmeticOverflow }
            let next = needed > capacity ? Swift.max(needed, Swift.max(1, doubled)) : capacity
            let reservation = try storage.reserve(UInt8.self, capacity: next, kind: .temporaryBytes)
            for _ in value.utf8 { try storage.step() }
            var copy = String(decoding: value.utf8, as: UTF8.self)
            copy.reserveCapacity(next)
            value = copy; receipt = reservation; capacity = next; identity = Identity()
        }
        try storage.step(UInt64(additional)); value += text
    }

    mutating func append(_ character: Character, storage: LibertyParseStorage?) throws {
        // Grammar punctuation/ASCII source bytes are constant-sized here.
        try append(String(character), storage: storage)
    }

    func string(storage: LibertyParseStorage?, kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> String {
        if let storage { return try storage.text(value, kind: kind) }; return value
    }
    private final class Identity: Sendable {}
}

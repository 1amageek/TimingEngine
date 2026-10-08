import Synchronization

/// Retains actual immutable payloads with their logical capacity receipts.
final class LibertyParseStorage: Sendable {
    let resources: any LibertySourceResourceAccounting
    private let state = Mutex(State())
    private let metadata: LibertySourceStorageReservation

    private struct Held: Sendable {
        var slots: [(any Sendable)?] = []
        var count = 0
        var version: UInt64 = 0
        var receipt: LibertySourceStorageReservation?
    }
    private struct State: Sendable { var live = Held(); var temporary = Held() }

    static func make(resources: any LibertySourceResourceAccounting) throws -> LibertyParseStorage {
        try resources.check()
        let bytes = try LibertySourceCapacity.byteCount(of: (State, any LibertySourceResourceAccounting,
            LibertySourceStorageReservation).self, capacity: 1)
        let metadata = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        return LibertyParseStorage(resources: resources, metadata: metadata)
    }
    private init(resources: any LibertySourceResourceAccounting, metadata: LibertySourceStorageReservation) {
        self.resources = resources; self.metadata = metadata
    }

    func step(_ amount: UInt64 = 1) throws { try resources.check(); try resources.chargeWork(amount) }
    func reserve<Element>(_ type: Element.Type, capacity: Int,
                          kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> LibertySourceStorageReservation {
        try resources.check()
        return try resources.reserveStorage(kind: kind,
            byteCount: LibertySourceCapacity.byteCount(of: type, capacity: capacity))
    }

    func hold<Value: Sendable>(_ value: Value, receipt: LibertySourceStorageReservation,
                              kind: LibertySourceStorageKind = .liveOwnedBytes) throws {
        // Admit concrete value storage before the generic value crosses an existential boundary.
        let metadata = try reserve((Value, LibertySourceStorageReservation, LibertySourceStorageReservation).self,
            capacity: 1, kind: kind)
        let payload = Payload(value: value, receipt: receipt, metadata: metadata)
        try holdReference(payload, kind: kind)
    }

    private func holdReference(_ value: any Sendable, kind: LibertySourceStorageKind) throws {
        let path: WritableKeyPath<State, Held> = kind == .liveOwnedBytes ? \.live : \.temporary
        while true {
            try resources.check()
            let snapshot = state.withLock { ($0[keyPath: path].count, $0[keyPath: path].slots.count, $0[keyPath: path].version) }
            if snapshot.0 < snapshot.1 {
                let appended = state.withLock { state -> Bool in
                    guard state[keyPath: path].version == snapshot.2 else { return false }
                    state[keyPath: path].slots[snapshot.0] = value
                    state[keyPath: path].count += 1; state[keyPath: path].version += 1
                    return true
                }
                if appended { return }; continue
            }
            let (doubled, overflow) = snapshot.1.multipliedReportingOverflow(by: 2)
            guard !overflow else { throw LibertySourceError.arithmeticOverflow }
            let capacity = Swift.max(1, doubled)
            let receipt = try reserve(Optional<any Sendable>.self, capacity: capacity, kind: kind)
            try step(UInt64(capacity))
            var slots = [(any Sendable)?](repeating: nil, count: capacity)
            var stable = true
            for index in 0..<snapshot.0 {
                try step()
                let item = state.withLock { state -> (Bool, (any Sendable)?) in
                    (state[keyPath: path].version == snapshot.2, state[keyPath: path].slots[index])
                }
                if !item.0 { stable = false; break }; slots[index] = item.1
            }
            guard stable else { continue }
            try resources.check()
            let installed = state.withLock { state -> Held? in
                guard state[keyPath: path].version == snapshot.2 else { return nil }
                let old = state[keyPath: path]
                state[keyPath: path] = Held(slots: slots, count: snapshot.0, version: snapshot.2 + 1, receipt: receipt)
                return old
            }
            guard let old = installed else { continue }
            withExtendedLifetime(old) {}
        }
    }

    func releaseTemporary() {
        let old = state.withLock { state -> Held in
            let old = state.temporary; state.temporary = Held(); return old
        }
        withExtendedLifetime(old) {}
    }

    func text(_ input: String, kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> String {
        var count = 0
        for _ in input.utf8 { try step(); count = try Self.add(count, 1) }
        let receipt = try reserve(UInt8.self, capacity: count, kind: kind)
        try step(UInt64(count))
        let output = String(decoding: input.utf8, as: UTF8.self)
        try hold(output, receipt: receipt, kind: kind); try resources.check(); return output
    }

    func bytes(_ input: borrowing Span<UInt8>, kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> [UInt8] {
        let receipt = try reserve(UInt8.self, capacity: input.count, kind: kind)
        var output = [UInt8](); output.reserveCapacity(input.count)
        for index in 0..<input.count { try step(); output.append(input[index]) }
        try hold(output, receipt: receipt, kind: kind); return output
    }

    func array<Element: Sendable>(_ values: [Element],
        kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> [Element] {
        let receipt = try reserve(Element.self, capacity: values.count, kind: kind)
        var output = [Element](); output.reserveCapacity(values.count)
        for value in values { try step(); output.append(value) }
        try hold(output, receipt: receipt, kind: kind); return output
    }

    static func add(_ a: Int, _ b: Int) throws -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw LibertySourceError.arithmeticOverflow }; return sum
    }

    private final class Payload<Value: Sendable>: Sendable {
        let value: Value
        let receipt: LibertySourceStorageReservation
        let metadata: LibertySourceStorageReservation
        init(value: Value, receipt: LibertySourceStorageReservation, metadata: LibertySourceStorageReservation) {
            self.value = value; self.receipt = receipt; self.metadata = metadata
        }
    }
}

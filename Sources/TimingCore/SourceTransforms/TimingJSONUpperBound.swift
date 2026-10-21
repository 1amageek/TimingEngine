import Foundation

/// Reuses the qualified Core CLI grammar visitor; slash escaping is included
/// for the existing Foundation default formatting as well as pretty printing.
/// The synchronous visitor does not retain state beyond this encoding traversal.
internal struct TimingJSONUpperBound {
    static func count<T: Encodable>(_ value: T, maximumBytes: UInt64,
                                    resources: any LibertySourceResourceAccounting) throws -> UInt64 {
        let counter = Counter(maximum: maximumBytes, resources: resources)
        try value.encode(to: Visitor(counter: counter, depth: 0))
        try counter.check()
        return counter.bytes
    }

    private final class Counter {
        let maximum: UInt64
        let resources: any LibertySourceResourceAccounting
        var bytes: UInt64 = 0
        var failure: (any Error)?
        init(maximum: UInt64, resources: any LibertySourceResourceAccounting) {
            self.maximum = maximum; self.resources = resources
        }
        func check() throws {
            if let failure { throw failure }
            try resources.check()
        }
        func add(_ amount: UInt64) throws {
            try check()
            guard amount <= maximum - bytes else { throw LibertySourceError.arithmeticOverflow }
            try resources.chargeWork(1)
            bytes += amount
        }
        func indented(_ base: UInt64, depth: UInt64) throws {
            let (spaces, overflow) = depth.multipliedReportingOverflow(by: 2)
            let (amount, sumOverflow) = spaces.addingReportingOverflow(base)
            guard !overflow, !sumOverflow else { throw LibertySourceError.arithmeticOverflow }
            try add(amount)
        }
        func deferIndented(_ base: UInt64, depth: UInt64) {
            do { try indented(base, depth: depth) } catch { if failure == nil { failure = error } }
        }
        func text(_ value: String) throws {
            try check()
            
            var encoded: UInt64 = 2
            for byte in value.utf8 {
                try check(); try resources.chargeWork(1); try check()
                let width: UInt64
                switch byte {
                case 0...31, 128...255: width = 6
                case 34, 47, 92: width = 2
                default: width = 1
                }
                let (next, overflow) = encoded.addingReportingOverflow(width)
                guard !overflow else { throw LibertySourceError.arithmeticOverflow }
                encoded = next
            }
            try add(encoded)
        }
    }

    private struct Visitor: Encoder {
        let counter: Counter
        /// The actual JSON value depth; Codable generic forwarding does not change it.
        let depth: UInt64
        var codingPath: [any CodingKey] { [] }
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        func child() -> Self {
            let (next, overflow) = depth.addingReportingOverflow(1)
            if overflow, counter.failure == nil { counter.failure = LibertySourceError.arithmeticOverflow }
            return Self(counter: counter, depth: overflow ? depth : next)
        }
        func field(_ name: String) throws {
            try counter.text(name)
            // Comma, newline, member indentation, colon and up to two surrounding spaces.
            try counter.indented(7, depth: depth)
        }
        func element() throws {
            // Comma, newline and element indentation.
            try counter.indented(4, depth: depth)
        }
        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            // Opening/closing delimiter, closing newline/indentation and one spare byte.
            counter.deferIndented(4, depth: depth)
            return KeyedEncodingContainer(Keyed<Key>(visitor: self))
        }
        func unkeyedContainer() -> any UnkeyedEncodingContainer {
            counter.deferIndented(4, depth: depth)
            return Unkeyed(visitor: self)
        }
        func singleValueContainer() -> any SingleValueEncodingContainer { Single(visitor: self) }
    }

    private struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let visitor: Visitor
        var codingPath: [any CodingKey] { [] }
        mutating func encodeNil(forKey key: Key) throws { try visitor.field(key.stringValue); try visitor.counter.add(4) }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            try visitor.field(key.stringValue); try value.encode(to: visitor.child())
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            do { try visitor.field(key.stringValue) } catch { if visitor.counter.failure == nil { visitor.counter.failure = error } }
            return visitor.child().container(keyedBy: type)
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            do { try visitor.field(key.stringValue) } catch { if visitor.counter.failure == nil { visitor.counter.failure = error } }
            return visitor.child().unkeyedContainer()
        }
        mutating func superEncoder() -> any Encoder {
            do { try visitor.field("super") } catch { if visitor.counter.failure == nil { visitor.counter.failure = error } }
            return visitor.child()
        }
        mutating func superEncoder(forKey key: Key) -> any Encoder {
            do { try visitor.field(key.stringValue) } catch { if visitor.counter.failure == nil { visitor.counter.failure = error } }
            return visitor.child()
        }
    }

    private struct Unkeyed: UnkeyedEncodingContainer {
        let visitor: Visitor
        var count = 0
        var codingPath: [any CodingKey] { [] }
        mutating func increment() {
            let next = count.addingReportingOverflow(1)
            if next.overflow {
                if visitor.counter.failure == nil { visitor.counter.failure = LibertySourceError.arithmeticOverflow }
            } else { count = next.partialValue }
        }
        mutating func encodeNil() throws { increment(); try visitor.element(); try visitor.counter.add(4) }
        mutating func encode<T: Encodable>(_ value: T) throws {
            increment(); try visitor.element(); try value.encode(to: visitor.child())
        }
        mutating func nestedContainer<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            increment()
            do { try visitor.element() } catch { if visitor.counter.failure == nil { visitor.counter.failure = error } }
            return visitor.child().container(keyedBy: type)
        }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
            increment()
            do { try visitor.element() } catch { if visitor.counter.failure == nil { visitor.counter.failure = error } }
            return visitor.child().unkeyedContainer()
        }
        mutating func superEncoder() -> any Encoder {
            increment()
            do { try visitor.element() } catch { if visitor.counter.failure == nil { visitor.counter.failure = error } }
            return visitor.child()
        }
    }

    private struct Single: SingleValueEncodingContainer {
        let visitor: Visitor
        var codingPath: [any CodingKey] { [] }
        func encodeNil() throws { try visitor.counter.add(4) }
        func encode(_ value: Bool) throws { try visitor.counter.add(5) }
        func encode(_ value: String) throws { try visitor.counter.text(value) }
        func encode(_ value: Double) throws { try visitor.counter.add(64) }
        func encode(_ value: Float) throws { try visitor.counter.add(64) }
        func encode(_ value: Int) throws { try visitor.counter.add(64) }
        func encode(_ value: Int8) throws { try visitor.counter.add(64) }
        func encode(_ value: Int16) throws { try visitor.counter.add(64) }
        func encode(_ value: Int32) throws { try visitor.counter.add(64) }
        func encode(_ value: Int64) throws { try visitor.counter.add(64) }
        func encode(_ value: UInt) throws { try visitor.counter.add(64) }
        func encode(_ value: UInt8) throws { try visitor.counter.add(64) }
        func encode(_ value: UInt16) throws { try visitor.counter.add(64) }
        func encode(_ value: UInt32) throws { try visitor.counter.add(64) }
        func encode(_ value: UInt64) throws { try visitor.counter.add(64) }
        func encode<T: Encodable>(_ value: T) throws { try value.encode(to: visitor) }
    }
}

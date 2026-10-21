import Foundation

/// Operation-local counted text/collection construction on the existing codec
/// storage owner. It introduces no parser, quota, deadline or source semantics.
internal final class TimingTextTransform: Sendable {
    let storage: LibertyParseStorage
    let resources: any LibertySourceResourceAccounting
    private let diagnostics: TimingControlledDiagnostics<LibertyParseStorage>

    init(resources: any LibertySourceResourceAccounting) throws {
        let checked = try TimingCheckedSourceResources(resources)
        self.resources = checked
        self.storage = try LibertyParseStorage.make(resources: checked)
        self.diagnostics = try TimingControlledDiagnostics(resources: checked, retaining: storage)
    }

    func failure(_ cause: any Error) -> TimingControlledTransformFailure {
        diagnostics.failure(cause)
    }

    func sourceFailure(utf8ByteCount: UInt64,
        _ construct: () -> any Error) throws -> TimingControlledTransformFailure {
        try diagnostics.sourceFailure(utf8ByteCount: utf8ByteCount, construct)
    }

    func source(_ data: Data, format: String) throws -> String {
        let lease = try storage.reserve(UInt8.self, capacity: data.count, kind: .temporaryBytes)
        try storage.step(UInt64(data.count))
        guard let source = String(data: data, encoding: .utf8) else {
            throw TimingError.parseFailure(format: format, line: 1, message: "Input is not UTF-8.")
        }
        try storage.hold(source, receipt: lease, kind: .temporaryBytes)
        try resources.check()
        return source
    }

    func text<S: StringProtocol>(_ input: S, kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> String {
        var count = 0
        for _ in input.utf8 { try storage.step(); count = try LibertyParseStorage.add(count, 1) }
        let lease = try storage.reserve(UInt8.self, capacity: count, kind: kind)
        try storage.step(UInt64(count))
        let value = String(decoding: input.utf8, as: UTF8.self)
        try storage.hold(value, receipt: lease, kind: kind)
        try resources.check()
        return value
    }

    func segments(_ source: String, omittingEmpty: Bool,
        separatedBy predicate: (Character) -> Bool) throws -> [Substring] {
        var segments = LibertyBuffer<Substring>(kind: .temporaryBytes)
        var beginning = source.startIndex
        for index in source.indices {
            try storage.step(UInt64(source[index].utf8.count))
            if predicate(source[index]) {
                if !omittingEmpty || beginning != index {
                    try segments.append(source[beginning..<index], storage: storage)
                }
                beginning = source.index(after: index)
            }
        }
        if !omittingEmpty || beginning != source.endIndex {
            try segments.append(source[beginning..<source.endIndex], storage: storage)
        }
        return try segments.array(storage: storage, kind: .temporaryBytes)
    }

    func trimmed(_ source: String, kind: LibertySourceStorageKind = .temporaryBytes) throws -> String {
        // Trimming deletes a prefix/suffix; the original UTF-8 extent is an
        // explicit upper bound for its one result payload.
        let lease = try storage.reserve(UInt8.self, capacity: source.utf8.count, kind: kind)
        try storage.step(UInt64(source.utf8.count))
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        try storage.hold(value, receipt: lease, kind: kind)
        try resources.check()
        return value
    }

    func caseMapped(_ input: String, uppercase: Bool,
        kind: LibertySourceStorageKind = .temporaryBytes) throws -> String {
        // Swift 6.4's special UTF-8 case-mapping table stores each mapping length
        // in UInt8. This bounds one scalar mapping before its String is produced.
        let scratchCount = try LibertyParseStorage.add(Int(UInt8.max), MemoryLayout<String>.stride)
        let scratch = try storage.reserve(UInt8.self, capacity: scratchCount, kind: .temporaryBytes)
        var count = 0
        for scalar in input.unicodeScalars {
            try storage.step()
            let mapping = uppercase ? scalar.properties.uppercaseMapping : scalar.properties.lowercaseMapping
            guard mapping.utf8.count <= Int(UInt8.max) else { throw LibertySourceError.arithmeticOverflow }
            count = try LibertyParseStorage.add(count, mapping.utf8.count)
        }
        // The fixed implementation begins with input capacity; a grown result
        // can coexist with it. Admit both exact source/mapping-derived capacities.
        let capacity = try LibertyParseStorage.add(input.utf8.count, count)
        let payload = try storage.reserve(UInt8.self, capacity: capacity, kind: kind)
        try storage.step(UInt64(input.unicodeScalars.count))
        let result = uppercase ? input.uppercased() : input.lowercased()
        try resources.check()
        guard result.utf8.count == count else { throw LibertySourceError.arithmeticOverflow }
        try storage.hold(result, receipt: payload, kind: kind)
        withExtendedLifetime(scratch) {}
        return result
    }

    func concatenate<S: StringProtocol>(_ first: String, _ second: S,
        kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> String {
        let count = try LibertyParseStorage.add(first.utf8.count, second.utf8.count)
        let lease = try storage.reserve(UInt8.self, capacity: count, kind: kind)
        try storage.step(UInt64(count))
        var output = String()
        output.reserveCapacity(count)
        output.append(contentsOf: first); output.append(contentsOf: second)
        try storage.hold(output, receipt: lease, kind: kind)
        try resources.check()
        return output
    }

    func map<C: Collection, Value: Sendable>(_ input: C,
        kind: LibertySourceStorageKind = .temporaryBytes,
        _ transform: (C.Element) throws -> Value) throws -> [Value] {
        let lease = try storage.reserve(Value.self, capacity: input.count, kind: kind)
        try storage.step(UInt64(input.count))
        var output: [Value] = []
        output.reserveCapacity(input.count)
        for item in input { try storage.step(); output.append(try transform(item)) }
        try storage.hold(output, receipt: lease, kind: kind)
        try resources.check()
        return output
    }

    func filter<C: Collection>(_ input: C,
        kind: LibertySourceStorageKind = .temporaryBytes,
        _ predicate: (C.Element) throws -> Bool) throws -> [C.Element] where C.Element: Sendable {
        let lease = try storage.reserve(C.Element.self, capacity: input.count, kind: kind)
        try storage.step(UInt64(input.count))
        var output: [C.Element] = []
        output.reserveCapacity(input.count)
        for item in input {
            try storage.step()
            if try predicate(item) { output.append(item) }
        }
        try storage.hold(output, receipt: lease, kind: kind)
        try resources.check()
        return output
    }

    func sorted<C: Collection>(_ input: C,
        kind: LibertySourceStorageKind = .temporaryBytes,
        by compare: (C.Element, C.Element) throws -> Bool) throws -> [C.Element] where C.Element: Sendable {
        let lease = try storage.reserve(C.Element.self, capacity: input.count, kind: kind)
        try storage.step(UInt64(input.count))
        var output: [C.Element] = []
        output.reserveCapacity(input.count)
        for item in input { try storage.step(); output.append(item) }
        // Bottom-up stable merges use one explicitly admitted contiguous scratch
        // array. No recursive stack or Foundation sorting workspace is assumed.
        let scratchLease = try storage.reserve(C.Element.self, capacity: input.count, kind: .temporaryBytes)
        try storage.step(UInt64(input.count))
        var scratch: [C.Element] = []
        scratch.reserveCapacity(input.count)
        for value in output { try storage.step(); scratch.append(value) }
        var width = 1
        while width < output.count {
            var beginning = 0
            while beginning < output.count {
                let middle = beginning + Swift.min(width, output.count - beginning)
                let ending = middle + Swift.min(width, output.count - middle)
                var left = beginning, right = middle
                for destination in beginning..<ending {
                    try storage.step()
                    let takeRight: Bool
                    if right == ending { takeRight = false }
                    else if left == middle { takeRight = true }
                    else { takeRight = try compare(output[right], output[left]) }
                    if takeRight {
                        scratch[destination] = output[right]; right += 1
                    } else {
                        scratch[destination] = output[left]; left += 1
                    }
                }
                beginning = ending
            }
            for index in output.indices { try storage.step(); output[index] = scratch[index] }
            if width > output.count / 2 { break }
            width *= 2
        }
        withExtendedLifetime(scratchLease) {}
        try storage.hold(output, receipt: lease, kind: kind)
        try resources.check()
        return output
    }

    func reserveSet<Element>(_: Element.Type, capacity: Int,
        kind: LibertySourceStorageKind = .temporaryBytes) throws -> LibertySourceStorageReservation {
        let bytes = try TimingTransformCapacity.set(Element.self, minimumCapacity: capacity)
        try storage.step(UInt64(capacity))
        return try resources.reserveStorage(kind: kind, byteCount: bytes)
    }

    func reserveDictionary<Key, Value>(_: Key.Type, _: Value.Type, capacity: Int,
        kind: LibertySourceStorageKind = .temporaryBytes) throws -> LibertySourceStorageReservation {
        let bytes = try TimingTransformCapacity.dictionary(Key.self, Value.self, minimumCapacity: capacity)
        try storage.step(UInt64(capacity))
        return try resources.reserveStorage(kind: kind, byteCount: bytes)
    }

    func finish<Value: Sendable>(_ value: Value) throws -> TimingTransformValue<Value> {
        try resources.check()
        storage.releaseTemporary()
        return try TimingTransformValue(value: value, retaining: storage, resources: resources)
    }
}

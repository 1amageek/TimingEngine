import Synchronization
import TimingCore


/// Immutable accounting anchors for one published Native value, not certificate authority.
internal final class NativeSTATransformRetention: Sendable {
    let owners: [any Sendable]
    private let metadata: LibertySourceStorageReservation?

    fileprivate init(owners: [any Sendable], metadata: LibertySourceStorageReservation?) {
        self.owners = owners; self.metadata = metadata
    }
}

/// Only construction changes this anchor; publication retains it without further mutation.
internal final class NativeSTATransformBufferLease: Sendable {
    private let current = Mutex<LibertySourceStorageReservation?>(nil)
    private let metadata: LibertySourceStorageReservation?
    init(metadata: LibertySourceStorageReservation?) { self.metadata = metadata }
    func replace(_ reservation: LibertySourceStorageReservation?) {
        let previous = current.withLock { value in
            let old = value; value = reservation; return old
        }
        // A caller's release callback is never invoked while the anchor mutex is held.
        withExtendedLifetime(previous) {}
    }
}

/// Construction-confined storage for concrete buffers in one lexical workspace.
/// External accounting callbacks occur only outside synchronization primitives.
internal final class NativeSTATransformStorage {
    let budget: NativeSTAStateBudget
    let kind: LibertySourceStorageKind
    private var owners: [any Sendable] = []
    private var ownerCapacity = 0
    private var metadata: LibertySourceStorageReservation?
    private struct ArraySite: Hashable { let line: Int; let discriminator: Int }
    private var arrayOwners: [ArraySite: NativeSTATransformBufferLease] = [:]
    private var arrayOwnerCapacity = 0
    private var completed: NativeSTATransformRetention?
    private var arrayOwnerMetadata: LibertySourceStorageReservation?

    init(budget: NativeSTAStateBudget, kind: LibertySourceStorageKind) {
        self.budget = budget; self.kind = kind
    }

    func hold<Owner: Sendable>(_ owner: Owner?) throws {
        guard let owner, budget.transformResources != nil else { return }
        guard completed == nil else { throw LibertySourceError.invalidCapacity }
        if owners.count == ownerCapacity {
            let doubled = max(1, ownerCapacity).multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { throw LibertySourceError.arithmeticOverflow }
            let capacity = doubled.partialValue
            let lease = try budget.reservePayload((any Sendable).self, capacity: capacity, kind: kind)
            try budget.chargeScheduledWork(UInt64(owners.count))
            var replacement: [any Sendable] = []
            replacement.reserveCapacity(capacity)
            replacement.append(contentsOf: owners)
            owners = replacement
            metadata = lease; ownerCapacity = capacity
        }
        // Admit compiler-owned existential payload before erasure. Small inline
        // values need only the already admitted existential array element.
        if MemoryLayout<Owner>.size > 3 * MemoryLayout<UInt>.size {
            guard let resources = budget.transformResources else { return }
            let boxBytes = UInt64(MemoryLayout<(Owner, LibertySourceStorageReservation?)>.stride)
            try resources.check()
            let boxLease = try resources.reserveStorage(kind: kind, byteCount: boxBytes)
            try resources.check()
            owners.append((owner, Optional(boxLease)))
        } else { owners.append(owner) }
    }

    func reserve<Element>(_ type: Element.Type, capacity: Int) throws {
        guard capacity >= 0 else { throw LibertySourceError.arithmeticOverflow }
        if capacity > 0 { try hold(budget.reservePayload(type, capacity: capacity, kind: kind)) }
    }

    func reserveDictionary<Key, Value>(_ key: Key.Type, _ value: Value.Type, capacity: Int) throws {
        guard let resources = budget.transformResources else { return }
        guard completed == nil else { throw LibertySourceError.invalidCapacity }
        let bytes = try TimingTransformCapacity.dictionary(key, value, minimumCapacity: capacity)
        try resources.check()
        let lease = try resources.reserveStorage(kind: kind, byteCount: bytes)
        try resources.check(); try hold(lease)
    }

    func reserveSet<Element>(_ type: Element.Type, capacity: Int) throws {
        guard let resources = budget.transformResources else { return }
        guard completed == nil else { throw LibertySourceError.invalidCapacity }
        let bytes = try TimingTransformCapacity.set(type, minimumCapacity: capacity)
        try resources.check()
        let lease = try resources.reserveStorage(kind: kind, byteCount: bytes)
        try resources.check(); try hold(lease)
    }

    func map<C: Collection, Element>(_ source: C, site: Int? = nil, _ body: (C.Element) throws -> Element) throws -> [Element] {
        let lease = try budget.reservePayload(Element.self, capacity: source.count, kind: kind)
        try budget.chargeScheduledWork(UInt64(source.count))
        var output: [Element] = []; output.reserveCapacity(source.count)
        for item in source { try budget.chargeScheduledWork(1); output.append(try body(item)) }
        if let site { try arrayOwner(site: site, discriminator: 0)?.replace(lease) }
        else { try hold(lease) }
        return output
    }

    func filter<C: Collection>(_ source: C, site: Int? = nil, _ body: (C.Element) throws -> Bool) throws -> [C.Element] {
        let lease = try budget.reservePayload(C.Element.self, capacity: source.count, kind: kind)
        var output: [C.Element] = []; output.reserveCapacity(source.count)
        for item in source { try budget.chargeScheduledWork(1); if try body(item) { output.append(item) } }
        if let site { try arrayOwner(site: site, discriminator: 0)?.replace(lease) }
        else { try hold(lease) }
        return output
    }

    func sorted<C: Collection>(_ source: C, by less: (C.Element, C.Element) throws -> Bool) throws -> [C.Element] {
        if budget.transformResources == nil { return try source.sorted(by: less) }
        var firstLease = try budget.reservePayload(C.Element.self, capacity: source.count, kind: kind)
        var output: [C.Element] = []; output.reserveCapacity(source.count)
        for item in source { try budget.chargeScheduledWork(1); output.append(item) }
        guard output.count > 1 else { try hold(firstLease); return output }
        var secondLease = try budget.reservePayload(C.Element.self, capacity: source.count, kind: kind)
        var other: [C.Element] = []; other.reserveCapacity(source.count)
        for item in source { try budget.chargeScheduledWork(1); other.append(item) }
        var width = 1
        while width < output.count {
            var start = 0
            while start < output.count {
                let middle = start + min(width, output.count - start)
                let end = middle + min(width, output.count - middle)
                var left = start; var right = middle; var destination = start
                while left < middle || right < end {
                    try budget.chargeScheduledWork(1)
                    let takeRight: Bool
                    if right == end { takeRight = false }
                    else if left == middle { takeRight = true }
                    else { takeRight = try less(output[right], output[left]) }
                    if takeRight { other[destination] = output[right]; right += 1 }
                    else { other[destination] = output[left]; left += 1 }
                    destination += 1
                }
                start = end
            }
            swap(&output, &other); swap(&firstLease, &secondLease)
            if width > output.count / 2 { break }
            width *= 2
        }
        try hold(firstLease)
        withExtendedLifetime(secondLease) {}
        return output
    }

    static func sourceFailure<Retention: Sendable>(diagnostics: TimingControlledDiagnostics<Retention>?,
        _ first: String, _ second: String = "", _ third: String = "", _ fourth: String = "",
        _ fifth: String = "", _ sixth: String = "", construct: (String) -> any Error) throws -> any Error {
        var count: UInt64 = 0
        func add(_ text: String) throws {
            let next = count.addingReportingOverflow(UInt64(text.utf8.count))
            guard !next.overflow else { throw LibertySourceError.arithmeticOverflow }
            count = next.partialValue
        }
        try add(first); try add(second); try add(third); try add(fourth); try add(fifth); try add(sixth)
        guard let capacity = Int(exactly: count) else { throw LibertySourceError.arithmeticOverflow }
        func make() -> any Error {
            var text = String(); text.reserveCapacity(capacity)
            text.append(first); text.append(second); text.append(third)
            text.append(fourth); text.append(fifth); text.append(sixth)
            return construct(text)
        }
        if let diagnostics { return try diagnostics.sourceFailure(utf8ByteCount: count, make) }
        return make()
    }

    func joined(_ left: String, _ separator: String, _ right: String) throws -> String {
        if budget.transformResources == nil { return left + separator + right }
        try budget.chargeScheduledWork(UInt64(left.utf8.count))
        try budget.chargeScheduledWork(UInt64(right.utf8.count))
        let first = left.utf8.count.addingReportingOverflow(separator.utf8.count)
        let total = first.partialValue.addingReportingOverflow(right.utf8.count)
        guard !first.overflow, !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        try reserve(UInt8.self, capacity: total.partialValue)
        try budget.chargeScheduledWork(UInt64(total.partialValue))
        var result = String(); result.reserveCapacity(total.partialValue)
        result.append(left); result.append(separator); result.append(right)
        if kind == .liveOwnedBytes { try hold(result) }
        return result
    }

    func repeated<Element>(_ value: Element, count: Int) throws -> [Element] {
        try reserve(Element.self, capacity: count)
        try budget.chargeScheduledWork(UInt64(count))
        return Array(repeating: value, count: count)
    }

    private func arrayOwner(site: Int, discriminator: Int) throws -> NativeSTATransformBufferLease? {
        guard let resources = budget.transformResources else { return nil }
        let key = ArraySite(line: site, discriminator: discriminator)
        if let owner = arrayOwners[key] { return owner }
        if arrayOwners.count == arrayOwnerCapacity {
            let doubled = max(1, arrayOwnerCapacity).multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { throw LibertySourceError.arithmeticOverflow }
            let capacity = doubled.partialValue
            let bytes = try TimingTransformCapacity.dictionary(ArraySite.self, NativeSTATransformBufferLease.self,
                minimumCapacity: capacity)
            try resources.check()
            let reservation = try resources.reserveStorage(kind: .temporaryBytes, byteCount: bytes)
            try resources.check(); try budget.chargeScheduledWork(UInt64(arrayOwners.count))
            var replacement: [ArraySite: NativeSTATransformBufferLease] = [:]
            replacement.reserveCapacity(capacity)
            for (key, value) in arrayOwners { replacement[key] = value }
            arrayOwners = replacement; arrayOwnerMetadata = reservation; arrayOwnerCapacity = capacity
        }
        try resources.check()
        let lease = try resources.reserveStorage(kind: kind,
            byteCount: UInt64(MemoryLayout<Mutex<LibertySourceStorageReservation?>>.stride))
        try resources.check()
        let owner = NativeSTATransformBufferLease(metadata: lease)
        try hold(owner); arrayOwners[key] = owner
        return owner
    }

    func append<Element>(_ value: Element, to output: inout [Element], site: Int = #line, discriminator: Int = 0) throws {
        try append(contentsOf: CollectionOfOne(value), to: &output, site: site, discriminator: discriminator)
    }

    /// Call only after the corresponding buffer has been replaced or destroyed.
    func releaseArrayBuffer(site: Int, discriminator: Int = 0) {
        arrayOwners[ArraySite(line: site, discriminator: discriminator)]?.replace(nil)
    }

    func append<C: Collection>(contentsOf values: C, to output: inout [C.Element], site: Int = #line, discriminator: Int = 0) throws {
        let total = output.count.addingReportingOverflow(values.count)
        guard !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        if budget.transformResources == nil { output.append(contentsOf: values); return }
        guard completed == nil else { throw LibertySourceError.invalidCapacity }
        let owner = try arrayOwner(site: site, discriminator: discriminator)
        if total.partialValue > output.capacity {
            let doubled = output.capacity.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow else { throw LibertySourceError.arithmeticOverflow }
            let capacity = max(total.partialValue, max(1, doubled.partialValue))
            let lease = try budget.reservePayload(C.Element.self, capacity: capacity, kind: kind)
            try budget.chargeScheduledWork(UInt64(output.count))
            var replacement: [C.Element] = []; replacement.reserveCapacity(capacity)
            replacement.append(contentsOf: output)
            try budget.transformResources?.check()
            output = replacement
            owner?.replace(lease)
        }
        try budget.chargeScheduledWork(UInt64(values.count))
        output.append(contentsOf: values)
    }

    func finish() throws -> NativeSTATransformRetention? {
        guard budget.transformResources != nil else { return nil }
        if let completed { return completed }
        try reserve(([any Sendable], LibertySourceStorageReservation?).self, capacity: 1)
        try budget.chargeScheduledWork(1)
        let result = NativeSTATransformRetention(owners: owners, metadata: metadata)
        completed = result
        // The result owns every buffer anchor; this construction index is not published.
        // Drop its backing before releasing the temporary metadata admission.
        arrayOwners = [:]
        arrayOwnerMetadata = nil
        arrayOwnerCapacity = 0
        return result
    }
}

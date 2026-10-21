import Foundation
import PDKCore
import TimingCore

/// Reuses the bounded decoder's retained resource context, not a second budget.
internal final class NativeSTADecodingResources: LibertySourceResourceAccounting {
    private let accounting: any PDKAdmissionResourceAccounting
    private let metadata: PDKAdmissionReservation

    static func resources(_ decoder: any Decoder) throws -> (any LibertySourceResourceAccounting)? {
        guard let raw = decoder.userInfo[PDKAdmissionDecodingContext.accountingKey] else { return nil }
        guard let accounting = raw as? any PDKAdmissionResourceAccounting else {
            throw PDKAdmissionResourceError.unsupportedBudgetCapability("Invalid Timing decode accounting context")
        }
        try accounting.check()
        let bytes = try LibertySourceCapacity.byteCount(of:
            (any PDKAdmissionResourceAccounting, PDKAdmissionReservation).self, capacity: 1)
        let lease = try accounting.reserve(.init(dimension: .liveOwnedBytes, amount: bytes))
        try accounting.check()
        return NativeSTADecodingResources(accounting: accounting, metadata: lease)
    }

    private init(accounting: any PDKAdmissionResourceAccounting, metadata: PDKAdmissionReservation) {
        self.accounting = accounting; self.metadata = metadata
    }

    func check() throws { try accounting.check() }

    func chargeWork(_ amount: UInt64) throws {
        try accounting.check()
        if amount > 0 { try accounting.charge(.init(dimension: .parserWork, amount: amount)) }
        try accounting.check()
    }

    func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
        try accounting.check()
        let dimension: PDKAdmissionResourceDimension = kind == .liveOwnedBytes ? .liveOwnedBytes : .temporaryBytes
        let wrapper = try LibertySourceCapacity.byteCount(of:
            (PDKAdmissionReservation?, PDKAdmissionReservation).self, capacity: 1)
        let metadata = try accounting.reserve(.init(dimension: dimension, amount: wrapper))
        let payload: PDKAdmissionReservation?
        if byteCount > 0 { payload = try accounting.reserve(.init(dimension: dimension, amount: byteCount)) }
        else { payload = nil }
        try accounting.check()
        return LibertySourceStorageReservation(kind: kind, byteCount: byteCount) {
            withExtendedLifetime((payload, metadata)) {}
        }
    }
    // Capacities are admitted by the owning custom initializer before these
    // operation-local transforms. Every visit checks the same decoder owner.
    static func prepaidSet<C: Collection>(_ source: C,
        resources: (any LibertySourceResourceAccounting)?) throws -> Set<C.Element> where C.Element: Hashable {
        guard let resources else { return Set(source) }
        var result: Set<C.Element> = []; result.reserveCapacity(source.count)
        for item in source { try resources.check(); try resources.chargeWork(1); try resources.check(); result.insert(item) }
        return result
    }

    static func prepaidMap<C: Collection, Value>(_ source: C,
        resources: (any LibertySourceResourceAccounting)?, _ transform: (C.Element) throws -> Value) throws -> [Value] {
        guard let resources else { return try source.map(transform) }
        var result: [Value] = []; result.reserveCapacity(source.count)
        for item in source { try resources.check(); try resources.chargeWork(1); try resources.check(); result.append(try transform(item)) }
        return result
    }

    static func all<C: Collection>(_ source: C, resources: (any LibertySourceResourceAccounting)?,
        _ predicate: (C.Element) throws -> Bool) throws -> Bool {
        for item in source {
            try resources?.check(); try resources?.chargeWork(1); try resources?.check()
            if try !predicate(item) { return false }
        }
        return true
    }

    static func contains<C: Collection>(_ source: C, resources: (any LibertySourceResourceAccounting)?,
        _ predicate: (C.Element) throws -> Bool) throws -> Bool {
        for item in source {
            try resources?.check(); try resources?.chargeWork(1); try resources?.check()
            if try predicate(item) { return true }
        }
        return false
    }

}

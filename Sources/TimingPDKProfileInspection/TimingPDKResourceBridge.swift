import PDKCore
import TimingCore

struct TimingPDKResourceBridge: LibertySourceResourceAccounting {
    let resources: any PDKAdmissionResourceAccounting
    func check() throws { try resources.check() }
    func chargeWork(_ amount: UInt64) throws {
        try check()
        if amount > 0 { _ = try resources.reserve(PDKAdmissionCost(dimension: .parserWork, amount: amount)) }
    }
    func reserveStorage(kind: LibertySourceStorageKind, byteCount: UInt64) throws -> LibertySourceStorageReservation {
        try check()
        if byteCount == 0 { return .init(kind: kind, byteCount: 0, release: {}) }
        let owner = try resources.reserve(PDKAdmissionCost(
            dimension: kind == .liveOwnedBytes ? .liveOwnedBytes : .temporaryBytes, amount: byteCount))
        return .init(kind: kind, byteCount: byteCount, release: { withExtendedLifetime(owner) {} })
    }
}

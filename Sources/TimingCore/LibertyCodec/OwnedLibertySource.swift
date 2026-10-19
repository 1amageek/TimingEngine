/// Immutable parse publication retains its actual library/facts/storage through copies.
/// Retain this owner while using raw extracted values; their mutation is caller-owned.
public final class OwnedLibertySource: Sendable {
    public let library: TimingLibrary
    public let cells: [LibertySourceCell]
    public let thresholds: TimingCharacterizationThresholds?
    public let thresholdIssue: TimingCharacterizationError?
    public let hasPinThresholdOverrides: Bool
    public let operatingConditions: [LibertySourceOperatingCondition]
    private let bytes: [UInt8]
    private let storage: LibertyParseStorage
    private let metadata: LibertySourceStorageReservation
    public var byteCount: Int { bytes.count }
    internal var normalPowerResources: any LibertySourceResourceAccounting { storage.resources }

    internal init(library: TimingLibrary, cells: [LibertySourceCell],
                  operatingConditions: [LibertySourceOperatingCondition], thresholds: TimingCharacterizationThresholds?, thresholdIssue: TimingCharacterizationError?,
                  hasPinThresholdOverrides: Bool, bytes: [UInt8],
                  storage: LibertyParseStorage, metadata: LibertySourceStorageReservation) {
        self.library = library; self.cells = cells; self.operatingConditions = operatingConditions
        self.thresholds = thresholds; self.thresholdIssue = thresholdIssue; self.hasPinThresholdOverrides = hasPinThresholdOverrides
        self.bytes = bytes; self.storage = storage; self.metadata = metadata
    }

    public func withBytes<Result>(_ body: (borrowing Span<UInt8>) throws -> Result) rethrows -> Result {
        let retainedOwner = self
        let bytes = retainedOwner.bytes
        defer { withExtendedLifetime(retainedOwner) {} }
        return try body(bytes.span)
    }
}

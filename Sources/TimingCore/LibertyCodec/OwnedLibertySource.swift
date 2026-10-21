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

    package func withThresholdIssueDescription<Result>(resources: any LibertySourceResourceAccounting,
        _ body: (String) throws -> Result) throws -> Result {
        let descriptionBytes: UInt64
        let numericFields: Int
        switch thresholdIssue {
        case .none:
            descriptionBytes = 3
            numericFields = 0
        case .some(.missingSourceFact(let fact)):
            descriptionBytes = try TimingDiagnosticTextCapacity.description(
                literal: "Missing Liberty characterization source fact: .", ints: 0, doubles: 0,
                booleans: 0, additionalUTF8: UInt64(fact.utf8.count))
            numericFields = 0
        case .some(.unsupportedSemantic(let semantic)):
            descriptionBytes = try TimingDiagnosticTextCapacity.description(
                literal: "Unsupported Liberty characterization semantic: .", ints: 0, doubles: 0,
                booleans: 0, additionalUTF8: UInt64(semantic.utf8.count))
            numericFields = 0
        case .some(.ambiguousSource(let fact)):
            descriptionBytes = try TimingDiagnosticTextCapacity.description(
                literal: "Ambiguous Liberty characterization source: .", ints: 0, doubles: 0,
                booleans: 0, additionalUTF8: UInt64(fact.utf8.count))
            numericFields = 0
        case .some(.invalidValue(let fact)):
            descriptionBytes = try TimingDiagnosticTextCapacity.description(
                literal: "Invalid Liberty characterization value: .", ints: 0, doubles: 0,
                booleans: 0, additionalUTF8: UInt64(fact.utf8.count))
            numericFields = 0
        case .some(.inputOutOfRange(let axis, _, _, _)):
            descriptionBytes = try TimingDiagnosticTextCapacity.description(
                literal: "Characterization   is outside [, ].", ints: 0, doubles: 3,
                booleans: 0, additionalUTF8: UInt64(axis.utf8.count))
            numericFields = 3
        }
        // The existing formatter creates one result String and up to three numeric
        // descriptions. Their source-proved capacities coexist within this offer.
        let numericBytes = try TimingDiagnosticTextCapacity.description(
            literal: "", ints: 0, doubles: numericFields, booleans: 0)
        let text = descriptionBytes.addingReportingOverflow(numericBytes)
        let headers = try LibertySourceCapacity.byteCount(of: String.self, capacity: numericFields + 1)
        let total = text.partialValue.addingReportingOverflow(headers)
        guard !text.overflow, !total.overflow else { throw LibertySourceError.arithmeticOverflow }
        try resources.check()
        let lease = try resources.reserveStorage(kind: .temporaryBytes, byteCount: total.partialValue)
        try resources.check()
        try resources.chargeWork(text.partialValue)
        try resources.check()
        defer { withExtendedLifetime(lease) {} }
        // This nested scope destroys the intermediate description before its outer
        // admission ends. The callback owns any separately admitted published text.
        return try {
            if let issue = thresholdIssue {
                guard let description = issue.errorDescription else {
                    throw TimingError.invariantViolation("Missing owned threshold issue description")
                }
                return try body(description)
            }
            return try body("nil")
        }()
    }

    public func withBytes<Result>(_ body: (borrowing Span<UInt8>) throws -> Result) rethrows -> Result {
        let retainedOwner = self
        let bytes = retainedOwner.bytes
        defer { withExtendedLifetime(retainedOwner) {} }
        return try body(bytes.span)
    }
}

import CircuiteFoundation
import TimingCore

/// Complete source consumption retained separately from maxPaths-limited display paths.
/// Decoding this value is not source-complete acceptance; a prepared replay validates it.
public struct STASourceEvidence: Sendable, Hashable, Codable {
    public struct Role: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            case pin, powerPin, normalPower, sequentialDefinition, propagation, directionalControlPropagation, sequentialCheck, pulseWidth, checkApplicability
        }
        public let modeID: String
        public let cornerID: String
        public let library: ArtifactReference
        public let instance: String
        public let cell: String
        public let pin: String
        public let relatedPin: String?
        public let kind: Kind
        public let source: LibertyTimingSourceIdentity?
        public let constrainedEdge: TimingEdge?
        public let relatedEdge: TimingEdge?
        public let checkKind: TimingCheckArc.Kind?
        public let applicableKind: STAAnalysisKind?
        public var endpointKey: String? {
            kind == .sequentialCheck || kind == .pulseWidth ? instance + "/" + pin : nil
        }
        public var analysisKind: STAAnalysisKind? {
            applicableKind ?? (kind == .pulseWidth ? .pulseWidth : checkKind.flatMap { STAAnalysisKind(rawValue: $0.rawValue) })
        }

        internal init(modeID: String, cornerID: String, library: ArtifactReference,
                      instance: String, cell: String, pin: String, relatedPin: String? = nil,
                      kind: Kind, source: LibertyTimingSourceIdentity? = nil,
                      constrainedEdge: TimingEdge? = nil, relatedEdge: TimingEdge? = nil,
                      checkKind: TimingCheckArc.Kind? = nil, applicableKind: STAAnalysisKind? = nil) {
            self.modeID = modeID; self.cornerID = cornerID; self.library = library
            self.instance = instance; self.cell = cell; self.pin = pin; self.relatedPin = relatedPin
            self.kind = kind; self.source = source; self.constrainedEdge = constrainedEdge
            self.relatedEdge = relatedEdge; self.checkKind = checkKind
            self.applicableKind = applicableKind
        }
    }

    public struct Coverage: Sendable, Hashable, Codable {
        public enum Disposition: String, Sendable, Hashable, Codable {
            case evaluated, sourceFact, staticZero, staticOne, excluded, unrequested, unconnected, unknown
            case sourceNotApplicable, staticControlNotApplicable, staticStateNotApplicable
        }
        public let role: Int
        public let disposition: Disposition
        public let witness: String

        internal init(role: Int, disposition: Disposition, witness: String) {
            self.role = role; self.disposition = disposition; self.witness = witness
        }
    }

    public struct SequentialCoordinate: Sendable, Hashable, Codable {
        public enum Branch: String, Sendable, Hashable, Codable { case data, gate, clock }
        public enum Meaning: String, Sendable, Hashable, Codable { case attained, infimum, supremum }
        public let pin: String
        public let branch: Branch
        public let meaning: Meaning
        public let selectedInputCoordinate: Double
        public let causalEarly: Double
        public let causalLate: Double
        public let releaseTime: Double
        public let waiting: Double
        public let borrowedTime: Double
        public let cycle: Int
        public let windowOpen: Double?
        public let windowClose: Double?
    }

    public struct Sample: Sendable, Hashable, Codable {
        public enum Context: String, Sendable, Hashable, Codable { case early, late }
        public let role: Int
        public let context: Context
        public let inputEdge: TimingEdge
        public let outputEdge: TimingEdge
        public let inputPoint: Int?
        public let receiver: String
        public let observation: TimingSourceEvaluationSample
        public let rangeObservation: TimingSourceEvaluationRangeSample?
        public let appliedScale: Double
        public let sequentialCoordinate: SequentialCoordinate?
        public var appliedResult: Double {
            let raw = rangeObservation.map { context == .early && $0.quantity != .constraint ? $0.result.lowerBound : $0.result.upperBound } ?? observation.result
            let value = raw * appliedScale
            guard rangeObservation != nil, appliedScale != 1, raw != 0 else { return value }
            return context == .late || observation.quantity == .constraint ? value.nextUp : value.nextDown
        }

        internal init(role: Int, context: Context, inputEdge: TimingEdge, outputEdge: TimingEdge,
                      inputPoint: Int?, receiver: String, observation: TimingSourceEvaluationSample,
                      appliedScale: Double, sequentialCoordinate: SequentialCoordinate? = nil,
                      rangeObservation: TimingSourceEvaluationRangeSample? = nil) {
            self.role = role; self.context = context; self.inputEdge = inputEdge; self.outputEdge = outputEdge
            self.inputPoint = inputPoint; self.receiver = receiver; self.observation = observation
            self.appliedScale = appliedScale
            self.rangeObservation = rangeObservation
            self.sequentialCoordinate = sequentialCoordinate
        }
    }

    public struct PulseWidthSample: Sendable, Hashable, Codable {
        public let role: Int
        public let context: Sample.Context
        public let observation: TimingPulseWidthSample
        public var rangeObservation: TimingPulseWidthRangeSample? = nil
        public let rootSource: String
        public let openingSlew: Double
        public let openingSegments: [STAClockObservation.Segment]
        public let closingSegments: [STAClockObservation.Segment]
        public let openingArrival: Double
        public let closingArrival: Double
        public let openingRootEdge: TimingEdge
        public let closingRootEdge: TimingEdge
        public let openingRootPhase: Double
        public let closingRootPhase: Double
        public let closingCycleOffset: Double
        public let period: Double
        public let uncertainty: Double
        public var sourceLine: Int { observation.source.line }
        public var sourceByteOffset: Int { observation.source.byteOffset }
        public var minimumWidth: Double { rangeObservation?.result.upperBound ?? observation.result }
        public var actualWidth: Double {
            rangeObservation == nil ? closingArrival + closingCycleOffset - openingArrival
                : ((closingArrival + closingCycleOffset).nextDown - openingArrival).nextDown
        }
        public var slack: Double {
            rangeObservation == nil ? actualWidth - minimumWidth - uncertainty
                : ((actualWidth - minimumWidth).nextDown - uncertainty).nextDown
        }
    }

    public struct NormalPowerSample: Sendable, Hashable, Codable {
        public let role: Int
        public let observation: LibertyNormalPowerReceipt
    }

    public struct StaticStateSample: Sendable, Hashable, Codable {
        public enum Effect: String, Sendable, Hashable, Codable { case inactive, clear, preset, unknown }
        public let role: Int
        public let clear: Bool?
        public let preset: Bool?
        public let effect: Effect
        public let inputConstants: [String: TimingDesign.Constant]
        public let powerConstants: [String: TimingDesign.Constant]
        public let outputConstants: [String: TimingDesign.Constant]
    }

    public let version: Int
    public let executionInputIdentity: ContentDigest
    public let configurationDigest: ContentDigest
    public let roles: [Role]
    public let coverage: [Coverage]
    public let samples: [Sample]
    public let pulseWidthSamples: [PulseWidthSample]
    public let staticStateSamples: [StaticStateSample]
    public let normalPowerSamples: [NormalPowerSample]
    private let normalPowerOwners: [CheckedLibertyNormalPower]

    public enum CheckStatus: String, Sendable, Hashable, Codable {
        case measured, staticDataNotApplicable, excluded, unrequested, unconnected, unknown
        case sourceNotApplicable, staticControlNotApplicable, staticStateNotApplicable
    }

    /// Consume only after prepared validation; this projection never grants source authority by itself.
    public func checkStatus(for role: Role) -> CheckStatus? {
        guard role.analysisKind != nil, let index = roles.firstIndex(of: role),
              let entry = coverage.first(where: { $0.role == index }) else { return nil }
        return Self.status(role:role,disposition:entry.disposition)
    }

    internal static func status(role: Role, disposition: Coverage.Disposition) -> CheckStatus {
        switch disposition {
        case .evaluated: return .measured
        case .staticZero, .staticOne:
            return role.checkKind == .setup || role.checkKind == .hold ? .staticDataNotApplicable : .unknown
        case .excluded: return .excluded
        case .unrequested: return .unrequested
        case .unconnected: return .unconnected
        case .sourceNotApplicable: return .sourceNotApplicable
        case .staticControlNotApplicable: return .staticControlNotApplicable
        case .staticStateNotApplicable: return .staticStateNotApplicable
        case .unknown, .sourceFact: return .unknown
        }
    }

    internal init(executionInputIdentity: ContentDigest, configurationDigest: ContentDigest,
                  roles: [Role], coverage: [Coverage], samples: [Sample], pulseWidthSamples: [PulseWidthSample] = [],
                  staticStateSamples: [StaticStateSample] = [], normalPowerSamples: [NormalPowerSample] = [],
                  normalPowerOwners: [CheckedLibertyNormalPower] = []) {
        version = 3; self.executionInputIdentity = executionInputIdentity
        self.configurationDigest = configurationDigest; self.roles = roles
        self.coverage = coverage; self.samples = samples
        self.pulseWidthSamples = pulseWidthSamples
        self.staticStateSamples = staticStateSamples
        self.normalPowerSamples = normalPowerSamples; self.normalPowerOwners = normalPowerOwners
    }

    private enum CodingKeys: String, CodingKey {
        case version, executionInputIdentity, configurationDigest, roles, coverage, samples, pulseWidthSamples, staticStateSamples, normalPowerSamples
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        version = try c.decode(Int.self,forKey:.version)
        executionInputIdentity = try c.decode(ContentDigest.self,forKey:.executionInputIdentity)
        configurationDigest = try c.decode(ContentDigest.self,forKey:.configurationDigest)
        roles = try c.decode([Role].self,forKey:.roles); coverage = try c.decode([Coverage].self,forKey:.coverage)
        samples = try c.decode([Sample].self,forKey:.samples)
        pulseWidthSamples = try c.decode([PulseWidthSample].self,forKey:.pulseWidthSamples)
        staticStateSamples = try c.decode([StaticStateSample].self,forKey:.staticStateSamples)
        normalPowerSamples = try c.decodeIfPresent([NormalPowerSample].self,forKey:.normalPowerSamples) ?? []
        normalPowerOwners = []
    }
    public static func == (lhs:Self,rhs:Self) -> Bool {
        lhs.version == rhs.version && lhs.executionInputIdentity == rhs.executionInputIdentity
            && lhs.configurationDigest == rhs.configurationDigest && lhs.roles == rhs.roles && lhs.coverage == rhs.coverage
            && lhs.samples == rhs.samples && lhs.pulseWidthSamples == rhs.pulseWidthSamples
            && lhs.staticStateSamples == rhs.staticStateSamples && lhs.normalPowerSamples == rhs.normalPowerSamples
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(version); hasher.combine(executionInputIdentity); hasher.combine(configurationDigest)
        hasher.combine(roles); hasher.combine(coverage); hasher.combine(samples); hasher.combine(pulseWidthSamples)
        hasher.combine(staticStateSamples); hasher.combine(normalPowerSamples)
    }

    internal func validateStructure(maximumStates: Int, maximumWork: UInt64) throws {
        let roleSlots = roles.count.multipliedReportingOverflow(by: 4)
        let pulseSlots = pulseWidthSamples.count.addingReportingOverflow(staticStateSamples.count)
        let powerSlots = pulseSlots.partialValue.addingReportingOverflow(normalPowerSamples.count)
        let sampleSlots = samples.count.addingReportingOverflow(powerSlots.partialValue)
        let slots = roleSlots.partialValue.addingReportingOverflow(sampleSlots.partialValue)
        guard !roleSlots.overflow, !pulseSlots.overflow, !powerSlots.overflow, !sampleSlots.overflow, !slots.overflow, slots.partialValue <= maximumStates,
              UInt64(slots.partialValue) <= maximumWork,
              version == 3, Set(roles).count == roles.count, coverage.count == roles.count,
              Set(coverage.map(\.role)) == Set(roles.indices) else { throw Self.invalid() }
        var retainedSlots = slots.partialValue
        func retain(_ count: Int) throws {
            let next = retainedSlots.addingReportingOverflow(count)
            guard !next.overflow, next.partialValue <= maximumStates, UInt64(next.partialValue) <= maximumWork else { throw Self.invalid() }
            retainedSlots = next.partialValue
        }
        for sample in pulseWidthSamples { try retain(sample.openingSegments.count); try retain(sample.closingSegments.count) }
        for sample in staticStateSamples {
            try retain(sample.inputConstants.count); try retain(sample.powerConstants.count); try retain(sample.outputConstants.count)
        }
        for sample in normalPowerSamples {
            try retain(sample.observation.pgValues.count); try retain(sample.observation.functions.count)
            for function in sample.observation.functions { try retain(function.queries.count) }
        }
        try Task.checkCancellation()
        var sampled = Array(repeating: false, count: roles.count)
        for sample in samples {
            try Task.checkCancellation()
            guard roles.indices.contains(sample.role) else { throw Self.invalid() }
            let role = roles[sample.role], value = sample.observation
            guard role.source == value.source, role.cell == value.source.cell,
                  sample.appliedScale.isFinite, sample.appliedScale > 0, sample.appliedResult.isFinite,
                  !sample.receiver.isEmpty, sample.inputPoint == nil || sample.inputPoint! >= 0,
                  [value.firstInput, value.secondInput, value.firstMinimum, value.firstMaximum,
                      value.secondMinimum, value.secondMaximum, value.result].allSatisfy(\.isFinite),
                  value.firstInput >= 0, value.secondInput >= 0,
                  value.firstMinimum <= value.firstInput, value.firstInput <= value.firstMaximum,
                  value.secondMinimum <= value.secondInput, value.secondInput <= value.secondMaximum,
                  value.quantity == .constraint || value.result >= 0 else { throw Self.invalid() }
            if let range = sample.rangeObservation {
                guard range.source == value.source, range.table == value.table, range.quantity == value.quantity,
                      range.firstInput.contains(value.firstInput), range.secondInput.contains(value.secondInput),
                      Self.validRange(range.firstInput), Self.validRange(range.secondInput), Self.validRange(range.result),
                      range.firstDomain.lowerBound <= range.firstInput.lowerBound, range.firstInput.upperBound <= range.firstDomain.upperBound,
                      range.secondDomain.lowerBound <= range.secondInput.lowerBound, range.secondInput.upperBound <= range.secondDomain.upperBound else { throw Self.invalid() }
            }
            sampled[sample.role] = true
            if let coordinate = sample.sequentialCoordinate {
                guard !coordinate.pin.isEmpty,
                      [coordinate.selectedInputCoordinate, coordinate.causalEarly, coordinate.causalLate,
                       coordinate.releaseTime, coordinate.waiting, coordinate.borrowedTime].allSatisfy(\.isFinite),
                      coordinate.causalEarly <= coordinate.causalLate,
                      coordinate.selectedInputCoordinate >= coordinate.causalEarly,
                      coordinate.selectedInputCoordinate <= coordinate.causalLate,
                      coordinate.waiting >= 0, coordinate.borrowedTime >= 0,
                      coordinate.windowOpen == nil || coordinate.windowOpen!.isFinite,
                      coordinate.windowClose == nil || coordinate.windowClose!.isFinite,
                      (coordinate.windowOpen == nil) == (coordinate.windowClose == nil),
                      coordinate.windowOpen == nil || coordinate.windowOpen! < coordinate.windowClose! else { throw Self.invalid() }
            }
        }
        for sample in pulseWidthSamples {
            try Task.checkCancellation()
            guard roles.indices.contains(sample.role), roles[sample.role].kind == .pulseWidth,
                  roles[sample.role].source == sample.observation.source,
                  roles[sample.role].constrainedEdge == sample.observation.openingEdge,
                  sample.sourceLine > 0, sample.sourceByteOffset >= 0,
                  !sample.rootSource.isEmpty, sample.openingSlew.isFinite, sample.openingSlew > 0,
                  [sample.minimumWidth, sample.actualWidth, sample.uncertainty, sample.slack].allSatisfy(\.isFinite),
                  sample.minimumWidth >= 0, sample.actualWidth >= 0, sample.uncertainty >= 0,
                  [sample.openingArrival, sample.closingArrival, sample.openingRootPhase,
                   sample.closingRootPhase, sample.closingCycleOffset, sample.period].allSatisfy(\.isFinite),
                  sample.period > 0, sample.closingCycleOffset == 0 || sample.closingCycleOffset == sample.period,
                  sample.closingCycleOffset == (sample.closingRootPhase <= sample.openingRootPhase ? sample.period : 0) else { throw Self.invalid() }
            let value = sample.observation
            if let query = value.inputSlew, let minimum = value.minimumSlew, let maximum = value.maximumSlew {
                guard [query, minimum, maximum].allSatisfy(\.isFinite), query == sample.openingSlew,
                      minimum <= query, query <= maximum else { throw Self.invalid() }
            } else {
                guard value.inputSlew == nil, value.minimumSlew == nil, value.maximumSlew == nil else { throw Self.invalid() }
            }
            if let range = sample.rangeObservation {
                guard range.source == value.source, range.table == value.table, range.openingEdge == value.openingEdge,
                      Self.validRange(range.result), range.result.lowerBound >= 0,
                      range.inputSlew == nil || (Self.validRange(range.inputSlew!) && range.inputSlew!.contains(sample.openingSlew)) else { throw Self.invalid() }
            }
            for segment in sample.openingSegments + sample.closingSegments {
                guard !segment.physicalIdentity.isEmpty, segment.earlyDelay.isFinite, segment.lateDelay.isFinite else { throw Self.invalid() }
            }
            sampled[sample.role] = true
        }
        for sample in normalPowerSamples {
            guard roles.indices.contains(sample.role), roles[sample.role].kind == .normalPower,
                  sample.observation.cell == roles[sample.role].cell,
                  sample.observation.cellLine > 0, sample.observation.cellByteOffset >= 0,
                  !sampled[sample.role] else { throw Self.invalid() }
            for value in sample.observation.pgValues {
                guard !value.condition.pin.isEmpty, !value.condition.sourcePGType.isEmpty,
                      value.line > 0, value.byteOffset >= 0 else { throw Self.invalid() }
            }
            for function in sample.observation.functions {
                guard !function.result, function.origin.functionLine > 0, function.origin.functionByteOffset >= 0,
                      function.origin.ownerLine > 0, function.origin.ownerByteOffset >= 0 else { throw Self.invalid() }
                for query in function.queries {
                    guard !query.symbol.isEmpty, query.domain == .binary,
                          query.binding != .powerPin || query.value != nil else { throw Self.invalid() }
                }
            }
            sampled[sample.role] = true
        }
        for sample in staticStateSamples {
            guard roles.indices.contains(sample.role), roles[sample.role].kind == .sequentialDefinition,
                  (sample.effect != .clear && sample.effect != .preset) || !sample.outputConstants.isEmpty else { throw Self.invalid() }
        }
        for entry in coverage {
            try Task.checkCancellation()
            guard !entry.witness.isEmpty, entry.disposition != .unknown,
                  entry.disposition == .evaluated ? sampled[entry.role] : !sampled[entry.role] else { throw Self.invalid() }
            let role = roles[entry.role]
            if entry.disposition == .sourceNotApplicable {
                guard role.kind == .checkApplicability, role.applicableKind != nil, role.source == nil else { throw Self.invalid() }
            }
            if entry.disposition == .staticControlNotApplicable {
                guard role.kind == .pulseWidth || role.checkKind == .recovery || role.checkKind == .removal else { throw Self.invalid() }
            }
            if entry.disposition == .staticStateNotApplicable {
                guard role.checkKind == .setup || role.checkKind == .hold else { throw Self.invalid() }
            }
            if role.kind == .sequentialCheck {
                guard entry.disposition != .sourceFact,
                      (entry.disposition != .staticZero && entry.disposition != .staticOne)
                        || role.checkKind == .setup || role.checkKind == .hold else { throw Self.invalid() }
            }
        }
    }

    private static func validRange(_ value: ClosedRange<Double>) -> Bool {
        value.lowerBound.isFinite && value.upperBound.isFinite && value.lowerBound <= value.upperBound
    }

    private static func invalid() -> TimingError {
        .invalidInput("Strict STA source evidence is incomplete or inconsistent")
    }
}

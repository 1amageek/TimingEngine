import CircuiteFoundation
import Foundation
import TimingCore

/// A versioned value record. Decode success is not source or physical authority.
public struct STAConservativeSourceContextRecord: Sendable, Equatable, Codable {
    internal struct Binding {
        let input: ContentDigest
        let configuration: ContentDigest
        let library: ArtifactReference
    }
    public enum Stage: String, Sendable, Codable { case initialRoots }
    public enum Origin: String, Sendable, Codable { case primaryPort, prescribedCellOutput }
    public struct Clock: Sendable, Equatable, Codable {
        public let rootIdentity: String
        public let period: Double
        public let riseReference: ClosedRange<Double>
        public let fallReference: ClosedRange<Double>
        internal var native: NativeSTAConservativeSourceHistory.Clock {
            .init(rootIdentity: rootIdentity, period: period, riseReference: riseReference, fallReference: fallReference)
        }
    }
    public enum History: Sendable, Equatable, Codable {
        case unrestricted
        case clock(Clock)
    }
    public struct Source: Sendable, Equatable, Codable {
        public let authority: STAConservativeSourceAuthority
        public let origin: Origin
        public let history: History
        internal var native: NativeSTAConservativeCoupling.Source {
            if let value = authority.constantVoltage { return .constant(endpoint: authority.endpoint, voltage: value) }
            // Validated records always have both dynamic directions.
            return .dynamic(endpoint: authority.endpoint, sourceIsPort: authority.sourceIsPort,
                riseSlew: authority.riseSlew!, fallSlew: authority.fallSlew!)
        }
    }
    public let version: Int
    public let stage: Stage
    public let modelIdentity: String
    public let executionInputIdentity: ContentDigest
    public let configurationDigest: ContentDigest
    public let library: ArtifactReference
    public let modeID: String
    public let cornerID: String
    public let historyGeneration: UInt64
    public let thresholds: TimingCharacterizationThresholds
    public let sources: [Source]
    private let retainedLease: LibertySourceStorageReservation?

    internal init(input: ContentDigest, configuration: ContentDigest, library: ArtifactReference,
        mode: String, corner: String, thresholds: TimingCharacterizationThresholds, sources: [Source],
        lease: LibertySourceStorageReservation? = nil) throws {
        version = 1; stage = .initialRoots; modelIdentity = STAConservativeCoupledRCOptions.modelIdentity
        executionInputIdentity = input; configurationDigest = configuration; self.library = library
        modeID = mode; cornerID = corner; historyGeneration = 0
        self.thresholds = thresholds; self.sources = sources; retainedLease = lease
    }

    internal func validate(checkpoint: () throws -> Void) throws {
        try checkpoint()
        guard version == 1, stage == .initialRoots, historyGeneration == 0,
              modelIdentity == STAConservativeCoupledRCOptions.modelIdentity,
              !modeID.isEmpty, !cornerID.isEmpty, !sources.isEmpty else { throw Self.invalid("context identity or stage") }
        _ = try NativeSTAConservativeCoupling().thresholdSpan(thresholds, rising: true)
        _ = try NativeSTAConservativeCoupling().thresholdSpan(thresholds, rising: false)
        for value in [thresholds.inputRise, thresholds.inputFall, thresholds.outputRise, thresholds.outputFall] {
            try checkpoint()
            guard value.isFinite, value > 0, value < 100 else { throw Self.invalid("reference threshold") }
        }
        for (index, source) in sources.enumerated() {
            try checkpoint()
            let a = source.authority
            guard !a.endpoint.name.isEmpty, !a.endpoint.ownerNet.isEmpty,
                  (source.origin == .primaryPort) == a.sourceIsPort else { throw Self.invalid("source origin") }
            for earlier in 0..<index {
                try checkpoint()
                guard sources[earlier].authority.endpoint != a.endpoint else { throw Self.invalid("duplicate endpoint") }
            }
            if let value = a.constantVoltage {
                guard value.isFinite, (0...1).contains(value), a.riseSlew == nil, a.fallSlew == nil,
                      source.history == .unrestricted else { throw Self.invalid("constant history") }
            } else {
                guard let r = a.riseSlew, let f = a.fallSlew,
                      r.lowerBound.isFinite, r.upperBound.isFinite, r.lowerBound > 0,
                      f.lowerBound.isFinite, f.upperBound.isFinite, f.lowerBound > 0 else { throw Self.invalid("slew") }
                if !a.sourceIsPort {
                    guard !a.sourceArcs.isEmpty, let load = a.prescribedBoundaryLoad, load.isFinite, load >= 0,
                          source.history == .unrestricted else { throw Self.invalid("unproved cell history") }
                }
            }
            if case .clock(let clock) = source.history {
                guard a.sourceIsPort, a.constantVoltage == nil, !clock.rootIdentity.isEmpty,
                      clock.period.isFinite, clock.period > 0,
                      clock.riseReference.lowerBound.isFinite, clock.riseReference.upperBound.isFinite,
                      clock.fallReference.lowerBound.isFinite, clock.fallReference.upperBound.isFinite else {
                    throw Self.invalid("clock binding")
                }
                let ramps = try clock.native.ramps(source: source.native, thresholds: thresholds)
                let next = try ramps.rise.start.adding(.init(point: clock.period))
                guard ramps.rise.end.upperBound < ramps.fall.start.lowerBound,
                      ramps.fall.end.upperBound < next.lowerBound else { throw Self.invalid("overlapping root ramps") }
            }
        }
    }
    private static func invalid(_ reason: String) -> TimingError { .invalidInput("Initial source context: " + reason) }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.stage == rhs.stage && lhs.modelIdentity == rhs.modelIdentity
            && lhs.executionInputIdentity == rhs.executionInputIdentity && lhs.configurationDigest == rhs.configurationDigest
            && lhs.library == rhs.library && lhs.modeID == rhs.modeID && lhs.cornerID == rhs.cornerID
            && lhs.historyGeneration == rhs.historyGeneration && lhs.thresholds == rhs.thresholds && lhs.sources == rhs.sources
    }
    private enum CodingKeys: String, CodingKey {
        case version, stage, modelIdentity, executionInputIdentity, configurationDigest, library,
             modeID, cornerID, historyGeneration, thresholds, sources
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        stage = try c.decode(Stage.self, forKey: .stage)
        modelIdentity = try c.decode(String.self, forKey: .modelIdentity)
        executionInputIdentity = try c.decode(ContentDigest.self, forKey: .executionInputIdentity)
        configurationDigest = try c.decode(ContentDigest.self, forKey: .configurationDigest)
        library = try c.decode(ArtifactReference.self, forKey: .library)
        modeID = try c.decode(String.self, forKey: .modeID); cornerID = try c.decode(String.self, forKey: .cornerID)
        historyGeneration = try c.decode(UInt64.self, forKey: .historyGeneration)
        let t = try c.decode([Double].self, forKey: .thresholds)
        guard t.count == 8 else { throw TimingError.invalidInput("Initial source context: threshold cardinality") }
        thresholds = .init(inputRise: t[0], inputFall: t[1], outputRise: t[2], outputFall: t[3],
            slewLowerRise: t[4], slewUpperRise: t[5], slewLowerFall: t[6], slewUpperFall: t[7])
        sources = try c.decode([Source].self, forKey: .sources)
        retainedLease = nil
        try validate(checkpoint: {})
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(stage, forKey: .stage)
        try c.encode(modelIdentity, forKey: .modelIdentity)
        try c.encode(executionInputIdentity, forKey: .executionInputIdentity)
        try c.encode(configurationDigest, forKey: .configurationDigest); try c.encode(library, forKey: .library)
        try c.encode(modeID, forKey: .modeID); try c.encode(cornerID, forKey: .cornerID)
        try c.encode(historyGeneration, forKey: .historyGeneration); try c.encode(sources, forKey: .sources)
        try c.encode([thresholds.inputRise, thresholds.inputFall, thresholds.outputRise, thresholds.outputFall,
            thresholds.slewLowerRise, thresholds.slewUpperRise, thresholds.slewLowerFall, thresholds.slewUpperFall], forKey: .thresholds)
    }
}

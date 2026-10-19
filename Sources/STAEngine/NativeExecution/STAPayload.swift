import Foundation
import TimingCore

public struct STAPayload: Sendable, Hashable, Codable {
    public var worstSetupSlack: Double?
    public var worstHoldSlack: Double?
    public var analyzedCorners: [String]
    public var analyzedModes: [String]
    public var endpoints: [STAEndpoint]
    public var unconstrainedEndpoints: [STAEndpoint]
    public var criticalPaths: [STAPath]
    public var violations: [STAViolation]
    public var repairCandidates: [STARepairCandidate]
    public var parasiticReduction: TimingParasiticReductionEvidence?
    public var clockObservations: [STAClockObservation]
    public var wireCoverage: [STAWireCoverage]
    public var wireObservations: [STADistributedRCObservation]
    public var conservativeWireObservations: [STAConservativeWireObservation]
    public var provenance: TimingArtifactProvenance
    public var processSelection: STAProcessSelection?
    public var effectiveConfiguration: STAEffectiveConfiguration?
    public var characterization: [STACharacterizationObservation]
    public var libraryConsumption: [STALibraryConsumption]
    public var sourceEvidence: STASourceEvidence?
    public var setupApplicability: STASetupApplicability?

    public init(
        worstSetupSlack: Double?,
        worstHoldSlack: Double?,
        analyzedCorners: [String],
        analyzedModes: [String] = [],
        endpoints: [STAEndpoint] = [],
        unconstrainedEndpoints: [STAEndpoint] = [],
        criticalPaths: [STAPath] = [],
        violations: [STAViolation] = [],
        repairCandidates: [STARepairCandidate] = [],
        parasiticReduction: TimingParasiticReductionEvidence? = nil,
        wireObservations: [STADistributedRCObservation] = [],
        conservativeWireObservations: [STAConservativeWireObservation] = [],
        wireCoverage: [STAWireCoverage] = [],
        clockObservations: [STAClockObservation] = [],
        provenance: TimingArtifactProvenance = TimingArtifactProvenance(),
        processSelection: STAProcessSelection? = nil,
        effectiveConfiguration: STAEffectiveConfiguration? = nil,
        characterization: [STACharacterizationObservation] = [],
        libraryConsumption: [STALibraryConsumption] = [],
        sourceEvidence: STASourceEvidence? = nil,
        setupApplicability: STASetupApplicability? = nil
    ) {
        self.worstSetupSlack = worstSetupSlack
        self.worstHoldSlack = worstHoldSlack
        self.analyzedCorners = analyzedCorners
        self.analyzedModes = analyzedModes
        self.endpoints = endpoints
        self.unconstrainedEndpoints = unconstrainedEndpoints
        self.criticalPaths = criticalPaths
        self.violations = violations
        self.repairCandidates = repairCandidates
        self.parasiticReduction = parasiticReduction
        self.clockObservations = clockObservations
        self.wireCoverage = wireCoverage
        self.wireObservations = wireObservations
        self.conservativeWireObservations = conservativeWireObservations
        self.provenance = provenance
        self.processSelection = processSelection
        self.effectiveConfiguration = effectiveConfiguration
        self.characterization = characterization
        self.libraryConsumption = libraryConsumption
        self.sourceEvidence = sourceEvidence
        self.setupApplicability = setupApplicability
    }

    private enum CodingKeys: String, CodingKey {
        case worstSetupSlack
        case worstHoldSlack
        case analyzedCorners
        case analyzedModes
        case endpoints
        case unconstrainedEndpoints
        case criticalPaths
        case violations
        case repairCandidates
        case parasiticReduction
        case clockObservations
        case wireCoverage
        case wireObservations
        case conservativeWireObservations
        case provenance
        case processSelection
        case effectiveConfiguration
        case characterization
        case libraryConsumption
        case sourceEvidence
        case setupApplicability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            worstSetupSlack: try container.decodeIfPresent(Double.self, forKey: .worstSetupSlack),
            worstHoldSlack: try container.decodeIfPresent(Double.self, forKey: .worstHoldSlack),
            analyzedCorners: try container.decode([String].self, forKey: .analyzedCorners),
            analyzedModes: try container.decode([String].self, forKey: .analyzedModes),
            endpoints: try container.decode([STAEndpoint].self, forKey: .endpoints),
            unconstrainedEndpoints: try container.decodeIfPresent([STAEndpoint].self, forKey: .unconstrainedEndpoints) ?? [],
            criticalPaths: try container.decode([STAPath].self, forKey: .criticalPaths),
            violations: try container.decode([STAViolation].self, forKey: .violations),
            repairCandidates: try container.decode([STARepairCandidate].self, forKey: .repairCandidates),
            parasiticReduction: try container.decodeIfPresent(TimingParasiticReductionEvidence.self, forKey: .parasiticReduction),
            wireObservations: try container.decodeIfPresent([STADistributedRCObservation].self, forKey: .wireObservations) ?? [],
            conservativeWireObservations: try container.decodeIfPresent([STAConservativeWireObservation].self, forKey: .conservativeWireObservations) ?? [],
            wireCoverage: try container.decodeIfPresent([STAWireCoverage].self, forKey: .wireCoverage) ?? [],
            clockObservations: try container.decodeIfPresent([STAClockObservation].self, forKey: .clockObservations) ?? [],
            provenance: try container.decode(TimingArtifactProvenance.self, forKey: .provenance),
            processSelection: try container.decodeIfPresent(STAProcessSelection.self, forKey: .processSelection),
            effectiveConfiguration: try container.decodeIfPresent(STAEffectiveConfiguration.self, forKey: .effectiveConfiguration),
            characterization: try container.decode([STACharacterizationObservation].self, forKey: .characterization),
            libraryConsumption: try container.decode([STALibraryConsumption].self, forKey: .libraryConsumption),
            sourceEvidence: try container.decodeIfPresent(STASourceEvidence.self, forKey: .sourceEvidence),
            setupApplicability: try container.decodeIfPresent(STASetupApplicability.self, forKey: .setupApplicability)
        )
        if effectiveConfiguration?.requireStrictSourceEvidence == true {
            try validateSetupApplicabilityStructure()
            guard let sourceEvidence, sourceEvidence.configurationDigest == effectiveConfiguration?.digest else {
                throw DecodingError.dataCorruptedError(forKey: .sourceEvidence, in: container,
                    debugDescription: "Strict STA requires exact complete source evidence")
            }
            try sourceEvidence.validateStructure(maximumStates: effectiveConfiguration!.maximumPathStates,
                maximumWork: effectiveConfiguration!.maximumPathWorkUnits)
        } else if sourceEvidence != nil {
            throw DecodingError.dataCorruptedError(forKey: .sourceEvidence, in: container,
                debugDescription: "Strict source evidence requires its effective policy")
        }
        if let configuration = effectiveConfiguration {
            let expected = Set(configuration.clockReceiverScope.flatMap { scope in
                [TimingEdge.rise, .fall].map { [scope.modeID, scope.cornerID, scope.rootClock, scope.receiver, $0.rawValue] }
            })
            let observed = clockObservations.map { [$0.modeID, $0.cornerID, $0.rootClock, $0.receiver, $0.edge.rawValue] }
            guard observed.count == Set(observed).count, Set(observed) == expected,
                  clockObservations.allSatisfy({ observation in
                      guard let root = configuration.clockSources[observation.modeID]?.first(where: { $0.name == observation.rootClock && $0.isPropagated }) else { return false }
                      return observation.period == root.period
                          && observation.rootPhase == root.waveform[observation.rootEdge == .rise ? 0 : 1]
                          && [observation.lateArrival, observation.earlyArrival, observation.lateSlew, observation.earlySlew].allSatisfy(\.isFinite)
                          && observation.lateSlew > 0 && observation.earlySlew > 0 && !observation.segments.isEmpty
                          && observation.segments.allSatisfy { !$0.physicalIdentity.isEmpty && $0.lateDelay.isFinite && $0.earlyDelay.isFinite }
                          && (configuration.conservativeCoupledRC != nil
                              ? observation.lateArrival >= observation.segments.reduce(observation.rootPhase, { $0 + $1.lateDelay })
                                && observation.earlyArrival <= observation.segments.reduce(observation.rootPhase, { $0 + $1.earlyDelay })
                              : observation.segments.reduce(observation.rootPhase, { $0 + $1.lateDelay }) == observation.lateArrival
                                && observation.segments.reduce(observation.rootPhase, { $0 + $1.earlyDelay }) == observation.earlyArrival)
                  }) else {
                throw DecodingError.dataCorruptedError(forKey: .clockObservations, in: container,
                    debugDescription: "Receiving clock scope or physical timing is missing or inconsistent")
            }
        } else if !clockObservations.isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .clockObservations, in: container, debugDescription: "Clock observations require exact configuration")
        }
        if effectiveConfiguration?.conservativeCoupledRC != nil {
            guard wireObservations.isEmpty, !wireCoverage.isEmpty,
                  Set(wireCoverage.map { [$0.modeID, $0.cornerID, $0.net] }).count == wireCoverage.count,
                  !conservativeWireObservations.isEmpty,
                  conservativeWireObservations.allSatisfy({ value in
                      let ranges = [value.sourceSlew, value.admittedSourceSlew, value.delay, value.slew]
                      return ranges.allSatisfy { $0.lowerBound.isFinite && $0.upperBound.isFinite }
                          && value.sourceSlew.lowerBound > 0 && value.slew.lowerBound > 0
                          && value.admittedSourceSlew.lowerBound <= value.sourceSlew.lowerBound
                          && value.sourceSlew.upperBound <= value.admittedSourceSlew.upperBound
                          && value.voltageErrorUpperBound.isFinite && value.voltageErrorUpperBound >= 0
                          && value.minimumCrossingDerivative.isFinite && value.minimumCrossingDerivative > 0
                          && value.maximumAbsoluteDerivative.isFinite && value.maximumAbsoluteDerivative > 0
                          && value.source.ownerNet == value.net && value.sink.ownerNet == value.net
                          && !value.source.name.isEmpty && !value.sink.name.isEmpty
                          && !value.sourceAuthorities.isEmpty
                          && Set(value.sourceAuthorities.map(\.endpoint)).count == value.sourceAuthorities.count
                          && value.sourceAuthorities.contains { $0.endpoint == value.source && $0.constantVoltage == nil }
                          && value.sourceAuthorities.allSatisfy { authority in
                              if let voltage = authority.constantVoltage {
                                  return (voltage == 0 || voltage == 1) && authority.riseSlew == nil && authority.fallSlew == nil
                              }
                              guard let rise = authority.riseSlew, let fall = authority.fallSlew else { return false }
                              return rise.lowerBound.isFinite && rise.upperBound.isFinite && rise.lowerBound > 0
                                  && fall.lowerBound.isFinite && fall.upperBound.isFinite && fall.lowerBound > 0
                                  && (authority.sourceIsPort || (!authority.sourceArcs.isEmpty
                                      && authority.prescribedBoundaryLoad.map { $0.isFinite && $0 >= 0 } == true))
                          }
                          && wireCoverage.contains { $0.modeID == value.modeID && $0.cornerID == value.cornerID
                              && $0.net == value.net && $0.model == .conservativeCoupledRC }
                  }) else {
                throw DecodingError.dataCorruptedError(forKey: .conservativeWireObservations, in: container,
                    debugDescription: "Certified coupled wire observations are incomplete or inconsistent")
            }
        } else if !conservativeWireObservations.isEmpty || wireCoverage.contains(where: { $0.model == .conservativeCoupledRC }) {
            throw DecodingError.dataCorruptedError(forKey: .conservativeWireObservations, in: container,
                debugDescription: "Certified observations require their exact model configuration")
        }
        if let options = effectiveConfiguration?.distributedRC {
            let keys = wireCoverage.map { [$0.modeID, $0.cornerID, $0.net] }
            guard !keys.isEmpty, Set(keys).count == keys.count,
                  wireCoverage.allSatisfy({ analyzedModes.contains($0.modeID) && analyzedCorners.contains($0.cornerID) }),
                  wireObservations.allSatisfy({ observation in
                      Self.validWireObservation(observation, options: options)
                          && wireCoverage.contains { $0.modeID == observation.modeID && $0.cornerID == observation.cornerID
                              && $0.net == observation.net && ($0.model == .distributedRC || $0.model == .propagatedClock) }
                  }) else {
                throw DecodingError.dataCorruptedError(forKey: .wireCoverage, in: container,
                    debugDescription: "Distributed wire scope or observations are missing or inconsistent")
            }
        }
    }

    private static func validWireObservation(_ value: STADistributedRCObservation, options: STADistributedRCOptions) -> Bool {
        guard !value.source.isEmpty, !value.sink.isEmpty,
              [value.sourceSlew, value.wireDelay, value.sinkSlew].allSatisfy(\.isFinite),
              value.sourceSlew >= 0, value.sinkSlew >= 0, value.cumulativeSteps <= options.maximumSteps,
              [value.sourceThreshold, value.sinkThreshold, value.lowerThreshold, value.upperThreshold].allSatisfy({ $0 > 0 && $0 < 1 }),
              value.lowerThreshold < value.upperThreshold,
              value.period == nil || (value.period!.isFinite && value.period! > 0) else { return false }
        switch value.method {
        case .backwardEuler:
            guard let crossing = value.observedCrossingDifference, let step = value.finalMaximumTimeStep else { return false }
            return value.sinkSlew > 0 && value.cumulativeSteps > 0
                && crossing.isFinite && crossing >= 0 && crossing <= options.crossingTolerance
                && step.isFinite && step > 0 && step <= options.maximumTimeStep
                && (value.period == nil || value.observedCycleDifference.map({ $0.isFinite && $0 >= 0 && $0 <= options.crossingTolerance }) == true)
        case .idealConstraint:
            guard value.observedCrossingDifference == nil, value.finalMaximumTimeStep == nil,
                  value.observedCycleDifference == nil, value.sinkSlew == value.sourceSlew else { return false }
            let duration = value.sourceSlew / (value.upperThreshold - value.lowerThreshold)
            guard duration.isFinite, duration <= options.stopTime,
                  value.period == nil || value.period! <= options.stopTime else { return false }
            // Exact numerical truth is checked by prepared replay, preserving the evaluator's arithmetic order.
            return true
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(worstSetupSlack, forKey: .worstSetupSlack)
        try container.encodeIfPresent(worstHoldSlack, forKey: .worstHoldSlack)
        try container.encode(analyzedCorners, forKey: .analyzedCorners)
        try container.encode(analyzedModes, forKey: .analyzedModes)
        try container.encode(endpoints, forKey: .endpoints)
        try container.encode(unconstrainedEndpoints, forKey: .unconstrainedEndpoints)
        try container.encode(criticalPaths, forKey: .criticalPaths)
        try container.encode(violations, forKey: .violations)
        try container.encode(repairCandidates, forKey: .repairCandidates)
        try container.encodeIfPresent(parasiticReduction, forKey: .parasiticReduction)
        try container.encode(clockObservations, forKey: .clockObservations)
        try container.encode(wireCoverage, forKey: .wireCoverage)
        try container.encode(wireObservations, forKey: .wireObservations)
        try container.encode(conservativeWireObservations, forKey: .conservativeWireObservations)
        try container.encode(provenance, forKey: .provenance)
        try container.encodeIfPresent(processSelection, forKey: .processSelection)
        try container.encodeIfPresent(effectiveConfiguration, forKey: .effectiveConfiguration)
        try container.encode(characterization, forKey: .characterization)
        try container.encode(libraryConsumption, forKey: .libraryConsumption)
        try container.encodeIfPresent(sourceEvidence, forKey: .sourceEvidence)
        try container.encodeIfPresent(setupApplicability, forKey: .setupApplicability)
    }
}

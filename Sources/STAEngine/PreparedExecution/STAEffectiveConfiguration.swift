import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import TimingCore

public struct STAEffectiveConfiguration: Sendable, Hashable, Codable {
    public let encodingVersion: Int
    public let algorithmIdentity: String
    public let reductionIdentity: String
    public let modeIDs: [String]
    public let cornerIDs: [String]
    public let analysisKinds: [STAAnalysisKind]
    public let maxPaths: Int
    public let requireStrictSourceEvidence: Bool
    public let operatingSupplyAssumptions: [STAOperatingSupplyAssumption]
    public let controlPulseSources: [STAControlPulseSource]
    public let maximumPathStates: Int
    public let maximumPathWorkUnits: UInt64
    public let requiresPostLayoutInputs: Bool
    public let variation: STAVariation
    public let inputSlews: [String: Double]
    public let inputTransitions: [String: TimingConstraintSet.InputTransition]
    public let clockSources: [String: [TimingConstraintSet.Clock]]
    public let clockReceiverScope: [STAClockReceiverScope]
    public let defaultOutputLoads: [String: Double]
    public let characterizationPolicy: STACharacterizationPolicy
    public let characterizationBindings: [STACharacterizationBinding]
    public let distributedRC: STADistributedRCOptions?
    public let conservativeCoupledRC: STAConservativeCoupledRCOptions?
    public let digest: ContentDigest
    internal init(request: STARequest, modes: [String], constraints: [String: TimingConstraintSet], limits: STAExecutionLimits, clockReceiverScope: [STAClockReceiverScope] = []) throws {
        encodingVersion = request.conservativeCoupledRC == nil ? 9 : 10
        algorithmIdentity = request.conservativeCoupledRC == nil ? "timing.sta.3.9.0" : "timing.sta.3.15.0"
        reductionIdentity = Self.reduction(distributedRC: request.distributedRC, conservative: request.conservativeCoupledRC)
        conservativeCoupledRC = request.conservativeCoupledRC
        distributedRC = request.distributedRC
        modeIDs = modes; cornerIDs = request.requestedCornerIDs; analysisKinds = request.analysisKinds
        maximumPathStates = limits.maximumPathStates; maximumPathWorkUnits = limits.maximumPathWorkUnits
        requireStrictSourceEvidence = request.requireStrictSourceEvidence
        operatingSupplyAssumptions = request.operatingSupplyAssumptions.sorted { [$0.cornerID, $0.instance, $0.pin].lexicographicallyPrecedes([$1.cornerID, $1.instance, $1.pin]) }
        controlPulseSources = request.controlPulseSources.sorted { [$0.modeID, $0.sourcePort].lexicographicallyPrecedes([$1.modeID, $1.sourcePort]) }
        maxPaths = request.maxPaths; requiresPostLayoutInputs = request.requiresPostLayoutInputs; variation = request.variation
        self.clockReceiverScope = clockReceiverScope.sorted { [$0.modeID, $0.cornerID, $0.rootClock, $0.receiver].lexicographicallyPrecedes([$1.modeID, $1.cornerID, $1.rootClock, $1.receiver]) }
        clockSources = constraints.mapValues { $0.clocks.sorted { $0.name < $1.name } }
        inputTransitions = request.conservativeCoupledRC == nil ? [:] : constraints.compactMapValues(\.inputTransition)
        inputSlews = constraints.mapValues(\.defaultInputSlew); defaultOutputLoads = constraints.mapValues(\.defaultOutputLoad)
        characterizationPolicy = request.characterizationPolicy; characterizationBindings = request.characterizationBindings
        digest = try Self.calculate(modeIDs: modeIDs, cornerIDs: cornerIDs, analysisKinds: analysisKinds,
            maxPaths: maxPaths, requireStrictSourceEvidence: requireStrictSourceEvidence, operatingSupplyAssumptions: operatingSupplyAssumptions, controlPulseSources: controlPulseSources, maximumPathStates: maximumPathStates, maximumPathWorkUnits: maximumPathWorkUnits, requiresPostLayoutInputs: requiresPostLayoutInputs, variation: variation,
            inputSlews: inputSlews, inputTransitions: inputTransitions, defaultOutputLoads: defaultOutputLoads,
            characterizationPolicy: characterizationPolicy, characterizationBindings: characterizationBindings, distributedRC: distributedRC, conservativeCoupledRC: conservativeCoupledRC, clockSources: clockSources, clockReceiverScope: self.clockReceiverScope)
    }
    private static func calculate(modeIDs: [String], cornerIDs: [String], analysisKinds: [STAAnalysisKind],
        maxPaths: Int, requireStrictSourceEvidence: Bool, operatingSupplyAssumptions: [STAOperatingSupplyAssumption], controlPulseSources: [STAControlPulseSource], maximumPathStates: Int, maximumPathWorkUnits: UInt64, requiresPostLayoutInputs: Bool, variation: STAVariation, inputSlews: [String: Double], inputTransitions: [String: TimingConstraintSet.InputTransition],
        defaultOutputLoads: [String: Double], characterizationPolicy: STACharacterizationPolicy,
        characterizationBindings: [STACharacterizationBinding], distributedRC: STADistributedRCOptions?, conservativeCoupledRC: STAConservativeCoupledRCOptions?, clockSources: [String: [TimingConstraintSet.Clock]], clockReceiverScope: [STAClockReceiverScope], transformStorage: NativeSTATransformStorage? = nil) throws -> ContentDigest {
        if let storage = transformStorage {
            return try controlledDigest(modeIDs: modeIDs, cornerIDs: cornerIDs, analysisKinds: analysisKinds,
                maxPaths: maxPaths, requireStrictSourceEvidence: requireStrictSourceEvidence,
                operatingSupplyAssumptions: operatingSupplyAssumptions, controlPulseSources: controlPulseSources,
                maximumPathStates: maximumPathStates, maximumPathWorkUnits: maximumPathWorkUnits,
                requiresPostLayoutInputs: requiresPostLayoutInputs, variation: variation,
                inputSlews: inputSlews, inputTransitions: inputTransitions, defaultOutputLoads: defaultOutputLoads,
                characterizationPolicy: characterizationPolicy, characterizationBindings: characterizationBindings,
                distributedRC: distributedRC, conservativeCoupledRC: conservativeCoupledRC,
                clockSources: clockSources, clockReceiverScope: clockReceiverScope,
                reduction: reduction(distributedRC: distributedRC, conservative: conservativeCoupledRC), storage: storage)
        }
        var bytes = Data()
        func frame(_ text: String) { let utf8 = text.utf8; bytes.append(contentsOf: String(utf8.count).utf8); bytes.append(58); bytes.append(contentsOf: utf8) }
        frame(conservativeCoupledRC == nil ? "timing.sta.effective.configuration.v9" : "timing.sta.effective.configuration.v10")
        frame(conservativeCoupledRC == nil ? "timing.sta.3.9.0" : "timing.sta.3.15.0")
        frame(reduction(distributedRC: distributedRC, conservative: conservativeCoupledRC))
        if let conservativeCoupledRC {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            frame(String(decoding: try encoder.encode(conservativeCoupledRC), as: UTF8.self))
            frame(STAConservativeCoupledRCOptions.loadModelIdentity)
            frame(String(decoding: try encoder.encode(inputTransitions), as: UTF8.self))
        }
        if let distributedRC { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; frame(String(decoding: try encoder.encode(distributedRC), as: UTF8.self)) }
        let clockEncoder = JSONEncoder(); clockEncoder.outputFormatting = [.sortedKeys]
        frame(String(decoding: try clockEncoder.encode(clockSources), as: UTF8.self))
        frame(String(decoding: try clockEncoder.encode(clockReceiverScope), as: UTF8.self))
        frame("defaults.v1"); frame(String(modeIDs.count)); modeIDs.forEach(frame)
        frame(String(cornerIDs.count)); cornerIDs.forEach(frame)
        frame(String(analysisKinds.count)); analysisKinds.forEach { frame($0.rawValue) }
        frame(String(maximumPathStates)); frame(String(maximumPathWorkUnits))
        frame("strict-source-evidence.v3"); frame(String(requireStrictSourceEvidence))
        frame(String(decoding: try clockEncoder.encode(operatingSupplyAssumptions), as: UTF8.self))
        frame(String(decoding: try clockEncoder.encode(controlPulseSources), as: UTF8.self))
        frame(String(maxPaths)); frame(String(requiresPostLayoutInputs))
        for value in [variation.lateCellDelayScale, variation.earlyCellDelayScale,
            variation.lateInterconnectDelayScale, variation.earlyInterconnectDelayScale] { frame(String(value.bitPattern)) }
        for mode in modeIDs { frame(String(inputSlews[mode]!.bitPattern)); frame(String(defaultOutputLoads[mode]!.bitPattern)) }
        frame(characterizationPolicy.rawValue); frame(String(characterizationBindings.count))
        for binding in characterizationBindings.sorted(by: { $0.cornerID < $1.cornerID }) {
            frame(binding.cornerID); frame(binding.conditionName); frame(binding.requiredNumericProcess.map { String($0.bitPattern) } ?? "none")
        }
        return try SHA256ContentDigester().digest(data: bytes, using: .sha256)
    }
    private static func reduction(distributedRC: STADistributedRCOptions?, conservative: STAConservativeCoupledRCOptions?) -> String {
        conservative != nil ? STAConservativeCoupledRCOptions.modelIdentity
            : distributedRC == nil ? "equipotential-cap-load.v1" : "prescribed-linear-ramp.ideal-quotient.backward-euler.v3"
    }
    private enum CodingKeys: String, CodingKey {
        case conservativeCoupledRC, clockReceiverScope, clockSources, distributedRC, encodingVersion, algorithmIdentity, reductionIdentity, modeIDs, cornerIDs, analysisKinds, maxPaths
        case inputTransitions, controlPulseSources, operatingSupplyAssumptions, requireStrictSourceEvidence, maximumPathStates, maximumPathWorkUnits, requiresPostLayoutInputs, variation, inputSlews, defaultOutputLoads, characterizationPolicy, characterizationBindings, digest
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        encodingVersion = try c.decode(Int.self, forKey: .encodingVersion)
        algorithmIdentity = try c.decode(String.self, forKey: .algorithmIdentity)
        reductionIdentity = try c.decode(String.self, forKey: .reductionIdentity)
        modeIDs = try c.decode([String].self, forKey: .modeIDs); cornerIDs = try c.decode([String].self, forKey: .cornerIDs)
        analysisKinds = try c.decode([STAAnalysisKind].self, forKey: .analysisKinds); maxPaths = try c.decode(Int.self, forKey: .maxPaths)
        requireStrictSourceEvidence = try c.decode(Bool.self, forKey: .requireStrictSourceEvidence)
        operatingSupplyAssumptions = try c.decode([STAOperatingSupplyAssumption].self, forKey: .operatingSupplyAssumptions)
        controlPulseSources = try c.decode([STAControlPulseSource].self, forKey: .controlPulseSources)
        maximumPathStates = try c.decode(Int.self, forKey: .maximumPathStates)
        maximumPathWorkUnits = try c.decode(UInt64.self, forKey: .maximumPathWorkUnits)
        requiresPostLayoutInputs = try c.decode(Bool.self, forKey: .requiresPostLayoutInputs)
        variation = try c.decode(STAVariation.self, forKey: .variation)
        inputTransitions = try c.decodeIfPresent([String: TimingConstraintSet.InputTransition].self, forKey: .inputTransitions) ?? [:]
        inputSlews = try c.decode([String: Double].self, forKey: .inputSlews)
        clockSources = try c.decode([String: [TimingConstraintSet.Clock]].self, forKey: .clockSources)
        clockReceiverScope = try c.decode([STAClockReceiverScope].self, forKey: .clockReceiverScope)
        defaultOutputLoads = try c.decode([String: Double].self, forKey: .defaultOutputLoads)
        characterizationPolicy = try c.decode(STACharacterizationPolicy.self, forKey: .characterizationPolicy)
        characterizationBindings = try c.decode([STACharacterizationBinding].self, forKey: .characterizationBindings)
        distributedRC = try c.decodeIfPresent(STADistributedRCOptions.self, forKey: .distributedRC)
        conservativeCoupledRC = try c.decodeIfPresent(STAConservativeCoupledRCOptions.self, forKey: .conservativeCoupledRC)
        digest = try c.decode(ContentDigest.self, forKey: .digest)
        let decodeResources = try NativeSTADecodingResources.resources(decoder)
        let decodeBudget = NativeSTAStateBudget(maximum: maximumPathStates, transformResources: decodeResources)
        let temporary = NativeSTATransformStorage(budget: decodeBudget, kind: .temporaryBytes)
        if decodeResources != nil {
            try temporary.reserveSet(String.self, capacity: modeIDs.count)
            try temporary.reserveSet(String.self, capacity: cornerIDs.count)
            try temporary.reserve([String].self, capacity: operatingSupplyAssumptions.count)
            try temporary.reserveSet([String].self, capacity: operatingSupplyAssumptions.count)
            for _ in operatingSupplyAssumptions { try temporary.reserve(String.self, capacity: 3) }
            try temporary.reserve([String].self, capacity: controlPulseSources.count)
            try temporary.reserveSet([String].self, capacity: controlPulseSources.count)
            for _ in controlPulseSources { try temporary.reserve(String.self, capacity: 2) }
            try temporary.reserveSet(String.self, capacity: clockSources.count)
            try temporary.reserveSet(String.self, capacity: modeIDs.count)
            var clockCount = 0
            for clocks in clockSources.values {
                try decodeBudget.chargeScheduledWork(1)
                let sum = clockCount.addingReportingOverflow(clocks.count)
                guard !sum.overflow else { throw LibertySourceError.arithmeticOverflow }
                clockCount = sum.partialValue
            }
            try temporary.reserveSet(STAClockReceiverScope.self, capacity: clockReceiverScope.count)
            try temporary.reserveSet(String.self, capacity: inputTransitions.count)
            try temporary.reserveSet(String.self, capacity: modeIDs.count)
            try temporary.reserveSet(String.self, capacity: inputSlews.count)
            try temporary.reserveSet(String.self, capacity: modeIDs.count)
            try temporary.reserveSet(String.self, capacity: defaultOutputLoads.count)
            try temporary.reserveSet(String.self, capacity: modeIDs.count)
            for _ in operatingSupplyAssumptions { try temporary.reserve(String.self, capacity: 4) }
        }
        guard encodingVersion == (conservativeCoupledRC == nil ? 9 : 10),
              algorithmIdentity == (conservativeCoupledRC == nil ? "timing.sta.3.9.0" : "timing.sta.3.15.0"),
              reductionIdentity == Self.reduction(distributedRC: distributedRC, conservative: conservativeCoupledRC),
              conservativeCoupledRC == nil || (distributedRC == nil && requireStrictSourceEvidence),
              !modeIDs.isEmpty, !cornerIDs.isEmpty, !analysisKinds.isEmpty, maxPaths > 0, maximumPathStates > 0, maximumPathWorkUnits > 0, variation.isValid,
              try NativeSTADecodingResources.prepaidSet(modeIDs, resources: decodeResources).count == modeIDs.count, try NativeSTADecodingResources.prepaidSet(cornerIDs, resources: decodeResources).count == cornerIDs.count,
              try NativeSTADecodingResources.prepaidSet(NativeSTADecodingResources.prepaidMap(operatingSupplyAssumptions, resources: decodeResources) { [$0.cornerID, $0.instance, $0.pin] }, resources: decodeResources).count == operatingSupplyAssumptions.count,
              try NativeSTADecodingResources.all(operatingSupplyAssumptions, resources: decodeResources, { assumption in
                  try NativeSTADecodingResources.contains(cornerIDs, resources: decodeResources, { $0 == assumption.cornerID })
                      && NativeSTADecodingResources.all([assumption.instance, assumption.cell, assumption.pin, assumption.sourcePGType],
                          resources: decodeResources, { !$0.isEmpty })
              }),
              try NativeSTADecodingResources.prepaidSet(NativeSTADecodingResources.prepaidMap(controlPulseSources, resources: decodeResources) { [$0.modeID, $0.sourcePort] }, resources: decodeResources).count == controlPulseSources.count,
              try NativeSTADecodingResources.all(controlPulseSources, resources: decodeResources, { source in
                  guard let clocks = clockSources[source.modeID] else { return false }
                  return try NativeSTADecodingResources.contains(modeIDs, resources: decodeResources, { $0 == source.modeID })
                      && NativeSTADecodingResources.contains(clocks, resources: decodeResources, { $0.name == source.referenceClock && $0.period == source.period })
              }),
              try NativeSTADecodingResources.prepaidSet(clockSources.keys, resources: decodeResources) == NativeSTADecodingResources.prepaidSet(modeIDs, resources: decodeResources),
              try NativeSTADecodingResources.all(clockSources.values, resources: decodeResources, { clocks in
                  try NativeSTADecodingResources.all(clocks, resources: decodeResources, { !$0.isPropagated || $0.hasValidPropagatedSource })
              }),
              try NativeSTADecodingResources.all(clockSources, resources: decodeResources, { mode, clocks in
                  try NativeSTADecodingResources.all(clocks, resources: decodeResources, { clock in
                      if !clock.isPropagated { return true }
                      return try NativeSTADecodingResources.all(cornerIDs, resources: decodeResources, { corner in
                          try NativeSTADecodingResources.contains(clockReceiverScope, resources: decodeResources, {
                              $0.modeID == mode && $0.cornerID == corner && $0.rootClock == clock.name
                          })
                      })
                  })
              }),
              try NativeSTADecodingResources.prepaidSet(clockReceiverScope, resources: decodeResources).count == clockReceiverScope.count,
              try NativeSTADecodingResources.all(clockReceiverScope, resources: decodeResources, { scope in
                  guard let clocks = clockSources[scope.modeID], !scope.receiver.isEmpty else { return false }
                  return try NativeSTADecodingResources.contains(modeIDs, resources: decodeResources, { $0 == scope.modeID })
                      && NativeSTADecodingResources.contains(cornerIDs, resources: decodeResources, { $0 == scope.cornerID })
                      && NativeSTADecodingResources.contains(clocks, resources: decodeResources, { $0.name == scope.rootClock && $0.isPropagated })
              }),
              try NativeSTADecodingResources.prepaidSet(inputTransitions.keys, resources: decodeResources).isSubset(of: NativeSTADecodingResources.prepaidSet(modeIDs, resources: decodeResources)),
              try NativeSTADecodingResources.all(inputTransitions, resources: decodeResources, { mode, transition in
                  switch transition { case .allInputsBothEdges(let slew): return slew.isFinite && slew > 0 && slew == inputSlews[mode] }
              }),
              try NativeSTADecodingResources.prepaidSet(inputSlews.keys, resources: decodeResources) == NativeSTADecodingResources.prepaidSet(modeIDs, resources: decodeResources), try NativeSTADecodingResources.prepaidSet(defaultOutputLoads.keys, resources: decodeResources) == NativeSTADecodingResources.prepaidSet(modeIDs, resources: decodeResources),
              try NativeSTADecodingResources.all(inputSlews.values, resources: decodeResources, { $0.isFinite && $0 >= 0 }),
              try NativeSTADecodingResources.all(defaultOutputLoads.values, resources: decodeResources, { $0.isFinite && $0 >= 0 }),
              try NativeSTADecodingResources.all(characterizationBindings, resources: decodeResources, { $0.requiredNumericProcess?.isFinite ?? true }),
              digest == (try Self.calculate(modeIDs: modeIDs, cornerIDs: cornerIDs, analysisKinds: analysisKinds,
                  maxPaths: maxPaths, requireStrictSourceEvidence: requireStrictSourceEvidence, operatingSupplyAssumptions: operatingSupplyAssumptions, controlPulseSources: controlPulseSources, maximumPathStates: maximumPathStates, maximumPathWorkUnits: maximumPathWorkUnits, requiresPostLayoutInputs: requiresPostLayoutInputs, variation: variation,
                  inputSlews: inputSlews, inputTransitions: inputTransitions, defaultOutputLoads: defaultOutputLoads,
                  characterizationPolicy: characterizationPolicy, characterizationBindings: characterizationBindings, distributedRC: distributedRC, conservativeCoupledRC: conservativeCoupledRC, clockSources: clockSources, clockReceiverScope: self.clockReceiverScope, transformStorage: decodeResources == nil ? nil : temporary)) else {
            throw DecodingError.dataCorruptedError(forKey: .digest, in: c, debugDescription: "Effective STA configuration is inconsistent")
        }
        withExtendedLifetime(temporary) {}
    }
}

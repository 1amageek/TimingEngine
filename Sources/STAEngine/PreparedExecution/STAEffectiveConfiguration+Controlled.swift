import CircuiteFoundation
import CircuiteFoundationCrypto
import TimingCore

extension STAEffectiveConfiguration {
    internal init(request: STARequest, modes: [String], constraints: [String:TimingConstraintSet],
        limits: STAExecutionLimits, clockReceiverScope: [STAClockReceiverScope],
        transformStorage storage: NativeSTATransformStorage) throws {
        encodingVersion = request.conservativeCoupledRC == nil ? 9 : 10
        algorithmIdentity = request.conservativeCoupledRC == nil ? "timing.sta.3.9.0" : "timing.sta.3.15.0"
        reductionIdentity = request.conservativeCoupledRC != nil ? STAConservativeCoupledRCOptions.modelIdentity
            : request.distributedRC == nil ? "equipotential-cap-load.v1" : "prescribed-linear-ramp.ideal-quotient.backward-euler.v3"
        conservativeCoupledRC = request.conservativeCoupledRC; distributedRC = request.distributedRC
        modeIDs = modes; cornerIDs = request.requestedCornerIDs; analysisKinds = request.analysisKinds
        maximumPathStates = limits.maximumPathStates; maximumPathWorkUnits = limits.maximumPathWorkUnits
        requireStrictSourceEvidence = request.requireStrictSourceEvidence
        operatingSupplyAssumptions = try storage.sorted(request.operatingSupplyAssumptions) { left, right in
            try storage.budget.chargeScheduledWork(1)
            if left.cornerID != right.cornerID { return left.cornerID < right.cornerID }
            if left.instance != right.instance { return left.instance < right.instance }
            return left.pin < right.pin
        }
        controlPulseSources = try storage.sorted(request.controlPulseSources) { left, right in
            try storage.budget.chargeScheduledWork(1)
            return left.modeID == right.modeID ? left.sourcePort < right.sourcePort : left.modeID < right.modeID
        }
        maxPaths = request.maxPaths; requiresPostLayoutInputs = request.requiresPostLayoutInputs; variation = request.variation
        self.clockReceiverScope = try storage.sorted(clockReceiverScope) { left, right in
            try storage.budget.chargeScheduledWork(1)
            if left.modeID != right.modeID { return left.modeID < right.modeID }
            if left.cornerID != right.cornerID { return left.cornerID < right.cornerID }
            if left.rootClock != right.rootClock { return left.rootClock < right.rootClock }
            return left.receiver < right.receiver
        }
        try storage.reserveDictionary(String.self, [TimingConstraintSet.Clock].self, capacity: constraints.count)
        try storage.reserveDictionary(String.self, TimingConstraintSet.InputTransition.self, capacity: constraints.count)
        try storage.reserveDictionary(String.self, Double.self, capacity: constraints.count)
        try storage.reserveDictionary(String.self, Double.self, capacity: constraints.count)
        var clocks: [String:[TimingConstraintSet.Clock]] = [:]; clocks.reserveCapacity(constraints.count)
        var transitions: [String:TimingConstraintSet.InputTransition] = [:]; transitions.reserveCapacity(constraints.count)
        var slews: [String:Double] = [:]; slews.reserveCapacity(constraints.count)
        var loads: [String:Double] = [:]; loads.reserveCapacity(constraints.count)
        for (mode, constraint) in constraints {
            try storage.budget.chargeScheduledWork(1)
            clocks[mode] = try storage.sorted(constraint.clocks) { left, right in
                try storage.budget.chargeScheduledWork(1); return left.name < right.name
            }
            if request.conservativeCoupledRC != nil, let transition = constraint.inputTransition { transitions[mode] = transition }
            slews[mode] = constraint.defaultInputSlew; loads[mode] = constraint.defaultOutputLoad
        }
        clockSources = clocks; inputTransitions = transitions; inputSlews = slews; defaultOutputLoads = loads
        characterizationPolicy = request.characterizationPolicy; characterizationBindings = request.characterizationBindings
        digest = try Self.controlledDigest(modeIDs: modes, cornerIDs: request.requestedCornerIDs,
            analysisKinds: request.analysisKinds, maxPaths: request.maxPaths,
            requireStrictSourceEvidence: request.requireStrictSourceEvidence,
            operatingSupplyAssumptions: operatingSupplyAssumptions, controlPulseSources: controlPulseSources,
            maximumPathStates: limits.maximumPathStates, maximumPathWorkUnits: limits.maximumPathWorkUnits,
            requiresPostLayoutInputs: request.requiresPostLayoutInputs, variation: request.variation,
            inputSlews: slews, inputTransitions: transitions, defaultOutputLoads: loads,
            characterizationPolicy: request.characterizationPolicy, characterizationBindings: request.characterizationBindings,
            distributedRC: request.distributedRC, conservativeCoupledRC: request.conservativeCoupledRC,
            clockSources: clocks, clockReceiverScope: self.clockReceiverScope, reduction: reductionIdentity, storage: storage)
    }

    internal static func controlledDigest(modeIDs: [String], cornerIDs: [String], analysisKinds: [STAAnalysisKind],
        maxPaths: Int, requireStrictSourceEvidence: Bool, operatingSupplyAssumptions: [STAOperatingSupplyAssumption],
        controlPulseSources: [STAControlPulseSource], maximumPathStates: Int, maximumPathWorkUnits: UInt64,
        requiresPostLayoutInputs: Bool, variation: STAVariation, inputSlews: [String:Double],
        inputTransitions: [String:TimingConstraintSet.InputTransition], defaultOutputLoads: [String:Double],
        characterizationPolicy: STACharacterizationPolicy, characterizationBindings: [STACharacterizationBinding],
        distributedRC: STADistributedRCOptions?, conservativeCoupledRC: STAConservativeCoupledRCOptions?,
        clockSources: [String:[TimingConstraintSet.Clock]], clockReceiverScope: [STAClockReceiverScope],
        reduction: String, storage: NativeSTATransformStorage) throws -> ContentDigest {
        guard let resources = storage.budget.transformResources else {
            throw TimingTransformError.unsupportedCapability("Controlled configuration requires its invocation owner")
        }
        let framed = try NativeSTAConfigurationFraming(resources: resources)
        try framed.text(conservativeCoupledRC == nil ? "timing.sta.effective.configuration.v9" : "timing.sta.effective.configuration.v10")
        try framed.text(conservativeCoupledRC == nil ? "timing.sta.3.9.0" : "timing.sta.3.15.0")
        try framed.text(reduction)
        if let conservative = conservativeCoupledRC {
            try framed.json(conservative); try framed.text(STAConservativeCoupledRCOptions.loadModelIdentity)
            try framed.json(inputTransitions)
        }
        if let distributed = distributedRC { try framed.json(distributed) }
        try framed.json(clockSources); try framed.json(clockReceiverScope)
        try framed.text("defaults.v1"); try framed.integer(modeIDs.count)
        for mode in modeIDs { try framed.text(mode) }
        try framed.integer(cornerIDs.count)
        for corner in cornerIDs { try framed.text(corner) }
        try framed.integer(analysisKinds.count)
        for kind in analysisKinds { try framed.text(kind.rawValue) }
        try framed.integer(maximumPathStates); try framed.integer(maximumPathWorkUnits)
        try framed.text("strict-source-evidence.v3"); try framed.boolean(requireStrictSourceEvidence)
        try framed.json(operatingSupplyAssumptions); try framed.json(controlPulseSources)
        try framed.integer(maxPaths); try framed.boolean(requiresPostLayoutInputs)
        try framed.integer(variation.lateCellDelayScale.bitPattern); try framed.integer(variation.earlyCellDelayScale.bitPattern)
        try framed.integer(variation.lateInterconnectDelayScale.bitPattern); try framed.integer(variation.earlyInterconnectDelayScale.bitPattern)
        for mode in modeIDs {
            guard let slew = inputSlews[mode], let load = defaultOutputLoads[mode] else {
                throw TimingError.invariantViolation("Configuration mode is missing its defaults")
            }
            try framed.integer(slew.bitPattern); try framed.integer(load.bitPattern)
        }
        try framed.text(characterizationPolicy.rawValue); try framed.integer(characterizationBindings.count)
        for binding in try storage.sorted(characterizationBindings, by: { $0.cornerID < $1.cornerID }) {
            try framed.text(binding.cornerID); try framed.text(binding.conditionName)
            if let number = binding.requiredNumericProcess { try framed.integer(number.bitPattern) }
            else { try framed.text("none") }
        }
        return try framed.withBytes { bytes in
            let count = UInt64(bytes.count)
            let digester = SHA256ContentDigester()
            let cost = try SHA256ContentDigester.managedCost(byteCount: count)
            let copy = try digester.foundationDataCopyCost(byteCount: count)
            let scratchBytes = cost.temporaryByteCount.addingReportingOverflow(copy.temporaryByteCount)
            let work = cost.workUnits.addingReportingOverflow(copy.workUnits)
            guard !scratchBytes.overflow, !work.overflow else { throw LibertySourceError.arithmeticOverflow }
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: scratchBytes.partialValue)
            guard let retainedBytes = Int(exactly: cost.retainedByteCount) else { throw LibertySourceError.arithmeticOverflow }
            try storage.reserve(UInt8.self, capacity: retainedBytes)
            try resources.chargeWork(work.partialValue); try resources.check()
            let digest = try digester.digest(data: bytes, using: .sha256)
            try resources.check(); withExtendedLifetime(scratch) {}
            return digest
        }
    }
}

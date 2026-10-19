import TimingCore

/// Invocation-local receipts. No role or numerical result is inferred from display paths.
internal struct NativeSTASourceEvidence: ~Copyable {
    private struct Key: Hashable {
        let instance: String
        let source: LibertyTimingSourceIdentity
        let constrainedEdge: TimingEdge?
        let relatedEdge: TimingEdge?
        let kind: TimingCheckArc.Kind?
    }
    let roles: [STASourceEvidence.Role]
    private var lookup: [Key: Int]
    private var dispositions: [STASourceEvidence.Coverage.Disposition]
    private var witnesses: [String]
    private(set) var samples: [STASourceEvidence.Sample]
    private(set) var pulseWidthSamples: [STASourceEvidence.PulseWidthSample]
    private(set) var staticStateSamples: [STASourceEvidence.StaticStateSample]
    private(set) var normalPowerSamples: [STASourceEvidence.NormalPowerSample]
    private(set) var normalPowerOwners: [CheckedLibertyNormalPower]

    init(roles: [STASourceEvidence.Role], design: TimingDesign, analysisKinds: [STAAnalysisKind],
         stateBudget: NativeSTAStateBudget, limits: STAExecutionLimits, work: inout UInt64) throws {
        let slots = roles.count.multipliedReportingOverflow(by: 4)
        guard !slots.overflow else { throw TimingError.invalidInput("Source evidence workspace overflow") }
        try Self.charge(UInt64(slots.partialValue), limits: limits, work: &work)
        try stateBudget.reserve(slots.partialValue)
        let instanceSlots = design.instances.count.multipliedReportingOverflow(by: 2)
        guard !instanceSlots.overflow else { throw TimingError.invalidInput("Source instance workspace overflow") }
        try Self.charge(UInt64(instanceSlots.partialValue), limits: limits, work: &work)
        try stateBudget.reserve(instanceSlots.partialValue)
        let instances = Dictionary(uniqueKeysWithValues: design.instances.map { ($0.name, $0) })
        var lookup: [Key: Int] = [:]
        var dispositions = Array(repeating: STASourceEvidence.Coverage.Disposition.unknown, count: roles.count)
        var witnesses = Array(repeating: "unmeasured required role", count: roles.count)
        for index in roles.indices {
            let role = roles[index]
            guard let instance = instances[role.instance] else {
                throw TimingError.invariantViolation("Foreign source evidence instance")
            }
            if let source = role.source {
                let key = Key(instance: role.instance, source: source,
                    constrainedEdge: role.constrainedEdge, relatedEdge: role.relatedEdge, kind: role.checkKind)
                guard lookup.updateValue(index, forKey: key) == nil else {
                    throw TimingError.invariantViolation("Duplicate required source role")
                }
            }
            switch role.kind {
            case .pin:
                dispositions[index] = instance.connections[role.pin] == nil ? .unconnected : .sourceFact
                witnesses[index] = "exact admitted source pin declaration"
            case .powerPin:
                dispositions[index] = .sourceFact
                witnesses[index] = "exact admitted source PG declaration; operating value requires an explicit condition"
            case .sequentialDefinition, .normalPower: break
            case .propagation, .directionalControlPropagation:
                if instance.connections[role.pin] == nil || role.relatedPin.flatMap({ instance.connections[$0] }) == nil {
                    dispositions[index] = .unconnected; witnesses[index] = "unconnected source arc endpoint"
                }
            case .sequentialCheck:
                if let kind = role.checkKind, !analysisKinds.contains(where: { $0.rawValue == kind.rawValue }) {
                    dispositions[index] = .unrequested; witnesses[index] = "check absent from requested analysis kinds"
                }
            case .checkApplicability:
                dispositions[index] = .sourceNotApplicable; witnesses[index] = "complete owned source proves no applicable check law or control"
            case .pulseWidth:
                if !analysisKinds.contains(.pulseWidth) {
                    dispositions[index] = .unrequested; witnesses[index] = "pulse width absent from requested analysis kinds"
                }
            }
        }
        self.roles = roles
        self.lookup = lookup
        self.dispositions = dispositions
        self.witnesses = witnesses
        self.samples = []
        self.pulseWidthSamples = []
        self.staticStateSamples = []
        self.normalPowerSamples = []; self.normalPowerOwners = []
    }

    mutating func record(_ observation: TimingSourceEvaluationSample, instance: String,
                         context: STASourceEvidence.Sample.Context, inputEdge: TimingEdge, outputEdge: TimingEdge,
                         inputPoint: Int?, receiver: String, scale: Double,
                         sequentialCoordinate: STASourceEvidence.SequentialCoordinate? = nil,
                         checkKind: TimingCheckArc.Kind? = nil, relatedEdge: TimingEdge? = nil,
                         rangeObservation: TimingSourceEvaluationRangeSample? = nil,
                         stateBudget: NativeSTAStateBudget, limits: STAExecutionLimits, work: inout UInt64) throws -> Int {
        try Self.charge(2, limits: limits, work: &work)
        let key = Key(instance: instance, source: observation.source,
            constrainedEdge: checkKind == nil ? nil : inputEdge, relatedEdge: relatedEdge, kind: checkKind)
        guard let role = lookup[key], scale.isFinite, scale > 0,
              (observation.result * scale).isFinite else {
            throw TimingError.invariantViolation("An actual source sample has no required role or finite transformation")
        }
        try stateBudget.reserve(1)
        let index = samples.count
        samples.append(.init(role: role, context: context, inputEdge: inputEdge, outputEdge: outputEdge,
            inputPoint: inputPoint, receiver: receiver, observation: observation, appliedScale: scale,
            sequentialCoordinate: sequentialCoordinate, rangeObservation: rangeObservation))
        dispositions[role] = .evaluated; witnesses[role] = "actual source evaluator query"
        return index
    }

    mutating func mark(instance: String, kind: STASourceEvidence.Role.Kind? = nil, pin: String? = nil,
                       relatedPin: String? = nil, checkKind: TimingCheckArc.Kind? = nil,
                       disposition: STASourceEvidence.Coverage.Disposition, witness: String,
                       limits: STAExecutionLimits, work: inout UInt64) throws {
        for index in roles.indices {
            try Self.charge(1, limits: limits, work: &work)
            let role = roles[index]
            guard role.instance == instance, kind == nil || role.kind == kind,
                  pin == nil || role.pin == pin, relatedPin == nil || role.relatedPin == relatedPin,
                  checkKind == nil || role.checkKind == checkKind, dispositions[index] != .evaluated,
                  dispositions[index] != .unrequested, dispositions[index] != .unconnected else { continue }
            dispositions[index] = disposition; witnesses[index] = witness
        }
    }

    mutating func recordPulse(instance: String, observation: TimingPulseWidthSample,
                              context: STASourceEvidence.Sample.Context, rootSource: String, openingSlew: Double,
                              openingSegments: [STAClockObservation.Segment], closingSegments: [STAClockObservation.Segment],
                              openingArrival: Double, closingArrival: Double, openingRootEdge: TimingEdge,
                              closingRootEdge: TimingEdge, openingRootPhase: Double, closingRootPhase: Double,
                              period: Double, uncertainty: Double, rangeObservation: TimingPulseWidthRangeSample? = nil,
                              stateBudget: NativeSTAStateBudget, limits: STAExecutionLimits, work: inout UInt64) throws -> Double {
        try Self.charge(UInt64(roles.count), limits: limits, work: &work)
        guard let role = roles.firstIndex(where: { $0.instance == instance && $0.kind == .pulseWidth
            && $0.source == observation.source && $0.constrainedEdge == observation.openingEdge }) else {
            throw TimingError.invariantViolation("Pulse width has no exact required source law")
        }
        var sample = STASourceEvidence.PulseWidthSample(role: role, context: context, observation: observation, rootSource: rootSource, openingSlew: openingSlew,
            openingSegments: openingSegments, closingSegments: closingSegments,
            openingArrival: openingArrival, closingArrival: closingArrival, openingRootEdge: openingRootEdge,
            closingRootEdge: closingRootEdge, openingRootPhase: openingRootPhase, closingRootPhase: closingRootPhase,
            closingCycleOffset: closingRootPhase <= openingRootPhase ? period : 0, period: period, uncertainty: uncertainty)
        sample.rangeObservation = rangeObservation
        guard sample.actualWidth.isFinite, sample.actualWidth >= 0, sample.slack.isFinite else {
            throw TimingError.invalidInput("Source pulse receiver edges cross or produce nonfinite width")
        }
        try stateBudget.reserve(1 + openingSegments.count + closingSegments.count); pulseWidthSamples.append(sample)
        dispositions[role] = .evaluated; witnesses[role] = "actual paired receiver edges and checked positioned pulse law"
        return sample.slack
    }

    mutating func recordNormalPower(instance: String, checked: CheckedLibertyNormalPower,
                                    stateBudget: NativeSTAStateBudget, limits: STAExecutionLimits, work: inout UInt64) throws {
        try Self.charge(UInt64(roles.count),limits:limits,work:&work)
        guard let role = roles.firstIndex(where:{ $0.instance == instance && $0.kind == .normalPower }),
              checked.receipt.cell == roles[role].cell else { throw TimingError.invariantViolation("Normal power lost exact instance source role") }
        var slots = checked.receipt.pgValues.count.addingReportingOverflow(checked.receipt.functions.count)
        guard !slots.overflow else { throw TimingError.invalidInput("Normal power evidence workspace overflow") }
        for function in checked.receipt.functions {
            slots = slots.partialValue.addingReportingOverflow(function.queries.count)
            guard !slots.overflow else { throw TimingError.invalidInput("Normal power evidence workspace overflow") }
        }
        let total = slots.partialValue.addingReportingOverflow(2)
        guard !total.overflow else { throw TimingError.invalidInput("Normal power evidence workspace overflow") }
        try stateBudget.reserve(total.partialValue)
        normalPowerSamples.append(.init(role:role,observation:checked.receipt)); normalPowerOwners.append(checked)
        dispositions[role] = .evaluated; witnesses[role] = "all explicit source PG values and every original power-down function false"
    }

    mutating func recordStatic(instance: String, effect: STASourceEvidence.StaticStateSample.Effect,
                               clear: Bool?, preset: Bool?, inputs: [String: TimingDesign.Constant],
                               powers: [String: TimingDesign.Constant], outputs: [String: TimingDesign.Constant],
                               stateBudget: NativeSTAStateBudget, limits: STAExecutionLimits, work: inout UInt64) throws {
        try Self.charge(UInt64(roles.count + inputs.count + powers.count + outputs.count), limits: limits, work: &work)
        guard let role = roles.firstIndex(where: { $0.instance == instance && $0.kind == .sequentialDefinition }) else {
            throw TimingError.invariantViolation("Static asynchronous state lost its exact declaration role")
        }
        try stateBudget.reserve(1 + inputs.count + powers.count + outputs.count)
        staticStateSamples.append(.init(role: role, clear: clear, preset: preset, effect: effect,
            inputConstants: inputs, powerConstants: powers, outputConstants: outputs))
    }

    func finish(stateBudget: NativeSTAStateBudget, limits: STAExecutionLimits, work: inout UInt64) throws -> [STASourceEvidence.Coverage] {
        try Self.charge(UInt64(roles.count), limits: limits, work: &work)
        try stateBudget.reserve(roles.count)
        var result: [STASourceEvidence.Coverage] = []
        result.reserveCapacity(roles.count)
        for index in roles.indices {
            guard dispositions[index] != .unknown else {
                throw TimingError.unsupportedSemantic(format: "strict source STA",
                    semantic: "unmeasured required role " + roles[index].instance + "/" + roles[index].pin)
            }
            result.append(.init(role: index, disposition: dispositions[index], witness: witnesses[index]))
        }
        return result
    }

    private static func charge(_ amount: UInt64, limits: STAExecutionLimits, work: inout UInt64) throws {
        try Task.checkCancellation()
        let next = work.addingReportingOverflow(amount)
        guard !next.overflow, next.partialValue <= limits.maximumPathWorkUnits else {
            throw STAPathAnalysisError.capacity(resource: "source evidence work", limit: limits.maximumPathWorkUnits)
        }
        work = next.partialValue
    }
}

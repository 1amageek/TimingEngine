import TimingCore

extension NativeSTAEngine {
    /// Projects all retained scenarios before any source-response or derived-history proof.
    public func initialSourceContexts(_ prepared: PreparedSTAExecution)
        throws(STAExecutionError) -> [STAConservativeSourceContext] {
        do {
            guard prepared.request.conservativeCoupledRC != nil, prepared.request.requireStrictSourceEvidence else {
                throw TimingError.unsupportedSemantic(format: "initial source context", semantic: "strict conservative preparation required")
            }
            let count = prepared.modeIDs.count.multipliedReportingOverflow(by: prepared.request.requestedCornerIDs.count)
            guard !count.overflow, count.partialValue > 0, count.partialValue <= prepared.limits.maximumScenarios else {
                throw STAPreparationError.capacity("Initial source scenario count")
            }
            let control = try NativeSTAInitialSourceControl(limits: prepared.limits,
                resources: prepared.sourceResources, contextCount: count.partialValue, transformResources: prepared.transformResources)
            var work: UInt64 = 0
            func tick(_ n: UInt64 = 1) throws {
                try NativeSTASequentialExecution.charge(n, work: &work, limits: prepared.limits,
                    sourceResources: prepared.sourceResources)
            }
            try tick(UInt64(count.partialValue))
            var contexts: [STAConservativeSourceContext] = []
            contexts.reserveCapacity(count.partialValue)
            for mode in prepared.modeIDs {
                guard let constraints = prepared.constraints[mode] else { throw TimingError.invariantViolation("Missing retained source mode") }
                guard constraints.caseAnalyses.isEmpty, constraints.generatedClocks.isEmpty else {
                    throw TimingError.unsupportedSemantic(format: "initial source context", semantic: "conditional or generated-clock history")
                }
                for corner in prepared.request.requestedCornerIDs {
                    try tick()
                    guard let library = prepared.processInputs.librariesByCorner[corner],
                          let source = prepared.processInputs.sourcesByCorner[corner],
                          let libraryReference = prepared.processSelection.librariesByCorner[corner] else {
                        throw TimingError.invariantViolation("Missing retained source corner")
                    }
                    var roleCount = 0
                    for role in prepared.sourceRoleInventory {
                        try tick()
                        if role.modeID == mode && role.cornerID == corner { roleCount += 1 }
                    }
                    try control.stateBudget.reserve(roleCount)
                    let rolePayload = try control.stateBudget.reservePayload(STASourceEvidence.Role.self, capacity: roleCount, kind: .temporaryBytes)
                    defer { withExtendedLifetime(rolePayload) {} }
                    var roles: [STASourceEvidence.Role] = []
                    roles.reserveCapacity(roleCount)
                    for role in prepared.sourceRoleInventory {
                        try tick()
                        if role.modeID == mode && role.cornerID == corner { roles.append(role) }
                    }
                    // Pre-admit the existing constructor's input-index collections before
                    // its map/set/sort transforms. They remain logical payload bounds.
                    let nets = prepared.design.nets.count.addingReportingOverflow(prepared.design.ports.count)
                    let axes = nets.partialValue.addingReportingOverflow(prepared.design.instances.count)
                    let slots = axes.partialValue.multipliedReportingOverflow(by: 8)
                    guard !nets.overflow, !axes.overflow, !slots.overflow else { throw LibertySourceError.arithmeticOverflow }
                    try tick(UInt64(slots.partialValue))
                    try control.stateBudget.reserve(slots.partialValue)
                    var analysis = try NativeSTAPathAnalysis(request: prepared.request, design: prepared.design,
                        library: library, source: source, constraints: constraints,
                        clockCharacterization: prepared.clockCharacterization[corner], sourceResources: prepared.sourceResources,
                        stateBudget: control.stateBudget, sourceRoles: roles, limits: prepared.limits, mode: mode,
                        corner: corner, initialWork: work)
                    let context = try analysis.initialSourceContext(parasitics: prepared.parasitics,
                        parasiticSource: prepared.parasiticSource,
                        binding: .init(input: prepared.executionInputIdentity, configuration: prepared.configurationDigest,
                            library: libraryReference), control: control, cumulativeWork: &work)
                    contexts.append(context)
                }
            }
            try control.finishBuilder(work: work)
            return contexts
        } catch is CancellationError { throw .cancelled }
        catch { throw .underlying(error) }
    }

    /// Reconstructs the actual producer values; decoded records cannot grant their own authority.
    public func validateInitialSourceContext(_ record: STAConservativeSourceContextRecord,
        against prepared: PreparedSTAExecution) throws(STAExecutionError) -> STAConservativeSourceContext {
        do {
            let contexts = try initialSourceContexts(prepared)
            for context in contexts {
                if try context.matchesScenario(record) {
                    try context.requireSameRecord(record)
                    return context
                }
            }
            throw TimingError.invalidInput("Initial source context scenario mismatch")
        } catch let error as STAExecutionError { throw error }
        catch is CancellationError { throw .cancelled }
        catch { throw .underlying(error) }
    }
}

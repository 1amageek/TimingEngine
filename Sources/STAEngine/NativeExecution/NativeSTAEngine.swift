import Foundation
import CircuiteFoundation
import LogicIR
import PDKCore
import TimingCore
import TimingPDKProfileInspection

public struct NativeSTAEngine: STAExecuting, STAExecutionPreparing, STAPreparedExecuting, STASourceEvidenceValidating, STAInitialSourceContextPreparing {
    public static let capability = TimingCapability(
        engineID: "timing.sta",
        supportedInputFormats: [.liberty, .json, .verilog, .sdc, .spef],
        supportedOutputFormats: [.json],
        features: ["foundation-request", "liberty-parsing", "sdc-parsing", "timing-graph", "mmmc-setup-hold", "recovery-removal", "pulse-width", "derate-ocv", "path-groups", "clock-groups", "provenance-digests", "artifact-persistence", "repair-candidates", "prescribed-ramp-distributed-rc", "primary-propagated-clock-tree"],
        limitations: ["advanced-statistical-ocv", "process-qualified-signoff", "equipotential-cap-load", "distributed-rc-requires-explicit-prescribed-ramp-options", "dynamic-cross-net-rc-coupling-unsupported"]
    )

    public typealias Request = STARequest
    public typealias Output = STAExecutionResult
    public let reader: any TimingArtifactReading
    public let artifactStore: (any TimingArtifactStoring)?
    public let libraryParser: any LibertySourceParsing
    public let characterizationParser: any LibertySourceCharacterizationParsing
    public let constraintParser: any TimingConstraintParsing
    public let designParser: any TimingDesignParsing
    public let parasiticParser: any TimingParasiticParsing
    public let parasiticReducer: any TimingParasiticReducing

    public init(
        reader: (any TimingArtifactReading)? = nil,
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil,
        libraryParser: any LibertySourceParsing = LibertyParser(),
        characterizationParser: any LibertySourceCharacterizationParsing = LibertyParser(),
        constraintParser: any TimingConstraintParsing = SDCParser(),
        designParser: any TimingDesignParsing = TimingDesignParser(),
        parasiticParser: any TimingParasiticParsing = SPEFParser(),
        parasiticReducer: any TimingParasiticReducing = EquipotentialTimingParasiticReducer()
    ) {
        self.reader = reader ?? FileSystemTimingArtifactReader(workspaceRoot: workspaceRoot)
        self.artifactStore = artifactStore
        self.libraryParser = libraryParser
        self.characterizationParser = characterizationParser
        self.constraintParser = constraintParser
        self.designParser = designParser
        self.parasiticParser = parasiticParser
        self.parasiticReducer = parasiticReducer
    }

    public func execute(_ request: STARequest) async throws -> STAExecutionResult {
        let startedAt = Date()
        do {
            let resources = STAExecutionResources(reader: reader,
                sourceLimits: try LibertySourceParseLimits(maximumNestingDepth: 64),
                sourceResources: STALibertyResources(), limits: try STAExecutionLimits())
            let prepared = try await prepare(request, resources: resources)
            return try await execute(prepared)
        } catch let error as STAPreparationError {
            if case .input(let cause) = error { return try blockedEnvelope(request: request, startedAt: startedAt, error: cause) }
            if case .cancelled = error { return try cancelledEnvelope(request: request, startedAt: startedAt) }
            return try blockedEnvelope(request: request, startedAt: startedAt,
                error: .unsupportedSemantic(format: "STA preparation", semantic: String(describing: error)))
        } catch let error as STAExecutionError {
            if case .cancelled = error { return try cancelledEnvelope(request: request, startedAt: startedAt) }
            if case .underlying(let cause) = error, let diagnostic = Self.nativeBackendFailureDiagnostic(for: cause) {
                return try STAExecutionResult(runID: request.runID, status: .failed, payload: emptyPayload(request: request),
                    inputBindings: request.artifactBindings, diagnostics: [diagnostic],
                    provenance: makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
                    schemaVersion: STARequest.currentSchemaVersion)
            }
            if case .underlying(let cause) = error, let timing = cause as? TimingError {
                if case .artifactWriteFailed = timing { return try failedEnvelope(request: request, startedAt: startedAt, error: timing) }
                return try blockedEnvelope(request: request, startedAt: startedAt, error: timing)
            }
            throw error
        } catch let error as TimingError {
            if case .artifactWriteFailed = error {
                return try failedEnvelope(request: request, startedAt: startedAt, error: error)
            }
            return try blockedEnvelope(request: request, startedAt: startedAt, error: error)
        } catch {
            let completedAt = Date()
            let diagnostic = DesignDiagnostic(
                severity: .error,
                code: "timing.sta.execution_failed",
                message: error.localizedDescription,
                suggestedActions: ["inspect_input_artifacts", "reproduce_with_timing_cli"]
            )
            return try STAExecutionResult(
                runID: request.runID,
                status: .failed,
                payload: emptyPayload(request: request),
                inputBindings: request.artifactBindings,
                diagnostics: [diagnostic],
                provenance: try makeProvenance(startedAt: startedAt, completedAt: completedAt, inputs: request.inputs),
                schemaVersion: STARequest.currentSchemaVersion
            )
        }
    }

    public func prepare(_ request: STARequest, resources: STAExecutionResources)
        async throws(STAPreparationError) -> PreparedSTAExecution {
        var failureBoundary: TimingControlledDiagnostics<LoadedInputs>?
        do {
            try Task.checkCancellation()
            guard request.randomSeed == nil else { throw STAPreparationError.unsupportedRandomSeed }
            guard request.variation.isValid else { throw TimingError.invalidInput("Invalid STA derates") }
            guard request.maxPaths <= resources.limits.maximumPaths else { throw STAPreparationError.capacity("Path limit exceeded") }
            let transformResources: (any LibertySourceResourceAccounting)? = resources.requiresStrictTransformAccounting ? resources.sourceResources : nil
            let transformBudget = NativeSTAStateBudget(maximum: resources.limits.maximumPathStates, transformResources: transformResources)
            let retained = NativeSTATransformStorage(budget: transformBudget, kind: .liveOwnedBytes)
            let temporary = NativeSTATransformStorage(budget: transformBudget, kind: .temporaryBytes)
            let inputs = try await loadInputs(request, resources: resources)
            if let transformResources {
                failureBoundary = try TimingControlledDiagnostics(resources: transformResources, retaining: inputs)
            }
            try validateCanonicalInputs(inputs, transformBudget: transformBudget)
            guard request.controlPulseSources.isEmpty || request.requireStrictSourceEvidence else {
                throw TimingError.invalidInput("Explicit control pulses require source-qualified execution")
            }
            for pulse in request.controlPulseSources {
                try resources.sourceResources.check()
                let pulseWork = inputs.design.ports.count.addingReportingOverflow(request.controlPulseSources.count)
                guard !pulseWork.overflow else { throw LibertySourceError.arithmeticOverflow }
                try resources.sourceResources.chargeWork(UInt64(pulseWork.partialValue))
                guard inputs.modeIDs.contains(pulse.modeID),
                      let port = inputs.design.ports.first(where: { $0.name == pulse.sourcePort }), port.direction == .input,
                      let constraint = inputs.constraints[pulse.modeID],
                      let clock = constraint.clock(named: pulse.referenceClock), clock.period == pulse.period,
                      !constraint.clocks.contains(where: { $0.source == pulse.sourcePort }) else {
                    throw TimingError.invalidInput("Control pulse source has a foreign port, mode, clock or period")
                }
                let referencePhase = clock.waveform.count == 2 ? clock.waveform[0] : 0
                for delay in constraint.inputDelays where delay.port == pulse.sourcePort {
                    guard delay.clock == nil || delay.clock == pulse.referenceClock,
                          delay.isMax ? (pulse.risePhase <= referencePhase + delay.rise && pulse.fallPhase <= referencePhase + delay.fall)
                            : (pulse.risePhase >= referencePhase + delay.rise && pulse.fallPhase >= referencePhase + delay.fall) else {
                        throw TimingError.invalidInput("Explicit control pulse contradicts the input-delay bounds")
                    }
                }
            }
            // The existing validator appends at most a missing-digest issue plus
            // one provenance/mismatch issue; it performs no String normalization.
            try temporary.reserve(LogicDesignProvenanceValidation.Issue.self, capacity: 2)
            try transformBudget.chargeScheduledWork(UInt64(request.design.digest.hexadecimalValue.utf8.count))
            let issues = LogicDesignProvenanceValidation.issues(for: logicDesignReference(for: request),
                requireProvenance: request.requiresPostLayoutInputs)
            guard issues.isEmpty else { throw TimingError.invalidInput("STA design provenance is incomplete") }
            let observations = try characterization(request, inputs: inputs.processInputs, transformStorage: retained)
            let reduced: TimingLumpedParasitics?
            if let source = inputs.parasitics, let transformResources {
                let value = try parasiticReducer.reduce(source, resources: transformResources)
                try retained.hold(value); reduced = value.value
            } else { reduced = try inputs.parasitics.map { try parasiticReducer.reduce($0) } }
            try retained.reserveDictionary(String.self, CharacterizedTimingLibrary.self, capacity: request.requestedCornerIDs.count)
            var clockCharacterization: [String: CharacterizedTimingLibrary] = [:]
            if transformResources != nil { clockCharacterization.reserveCapacity(request.requestedCornerIDs.count) }
            var receiverScope: [STAClockReceiverScope] = []
            if inputs.constraints.values.contains(where: { $0.clocks.contains(where: \.isPropagated) }) {
                guard request.distributedRC != nil || request.conservativeCoupledRC != nil else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "propagated clock requires explicit wire timing options") }
                let clockPlanBudget = NativeSTAStateBudget(maximum: resources.limits.maximumPathStates, transformResources: transformResources)
                var clockPlanWork: UInt64 = 0
                for corner in request.requestedCornerIDs {
                    guard let source = inputs.processInputs.sourcesByCorner[corner] else { throw TimingError.invariantViolation("Missing clock source owner") }
                    try temporary.reserveSet(String.self, capacity: inputs.design.instances.count)
                    try temporary.reserveSet(String.self, capacity: inputs.design.instances.count)
                    try temporary.reserveDictionary(Int.self, NativeSTASequentialExecution.Plan.self, capacity: inputs.design.instances.count)
                    var buffers = Set<String>(), sequential = Set<String>()
                    var plans: [Int: NativeSTASequentialExecution.Plan] = [:]
                    if transformResources != nil {
                        buffers.reserveCapacity(inputs.design.instances.count); sequential.reserveCapacity(inputs.design.instances.count)
                        plans.reserveCapacity(inputs.design.instances.count)
                    }
                    for (index, instance) in inputs.design.instances.enumerated() {
                        let cell = try source.library.cell(named: instance.cell)
                        guard let model = cell.sequentialModel else { continue }
                        let plan = try NativeSTASequentialExecution.compile(model: model,
                            source: source.cells.first { $0.name == instance.cell }, work: &clockPlanWork,
                            limits: resources.limits, stateBudget: clockPlanBudget, sourceResources: resources.sourceResources)
                        try clockPlanBudget.reserve(1)
                        plans[index] = plan
                    }
                    for mode in inputs.modeIDs {
                        try temporary.reserve(TimingConstraintSet.self, capacity: 1)
                        let selected = try NativeSTAClockPropagation.characterizationCells(design: inputs.design, library: source.library,
                            constraints: [inputs.constraints[mode]!], plans: plans,
                            resources: resources.sourceResources, delimiter: inputs.parasitics?.pinDelimiter ?? ":",
                            transformResources: transformResources)
                        try retained.hold(selected)
                        buffers.formUnion(selected.buffers); sequential.formUnion(selected.sequential)
                        for receiver in selected.receivers {
                            guard receiverScope.count < resources.limits.maximumPathStates else { throw STAPreparationError.capacity("Clock receiver scope") }
                            try retained.append(STAClockReceiverScope(modeID: mode, cornerID: corner, rootClock: receiver.root, receiver: receiver.receiver), to: &receiverScope)
                        }
                    }
                    let all: [String]
                    if transformResources != nil {
                        let count = buffers.count.addingReportingOverflow(sequential.count)
                        guard !count.overflow else { throw LibertySourceError.arithmeticOverflow }
                        try temporary.reserveSet(String.self, capacity: count.partialValue)
                        var union: Set<String> = []; union.reserveCapacity(count.partialValue)
                        for value in buffers { try transformBudget.chargeScheduledWork(1); union.insert(value) }
                        for value in sequential { try transformBudget.chargeScheduledWork(1); union.insert(value) }
                        all = try temporary.sorted(union, by: <)
                    } else { all = Array(buffers.union(sequential)).sorted() }
                    guard !all.isEmpty else { throw TimingError.unsupportedSemantic(format: "propagated clock STA", semantic: "no actual FF clock characterization scope") }
                    if !request.requireStrictSourceEvidence {
                        clockCharacterization[corner] = try source.withBytes {
                            try characterizationParser.parseCharacterizedSource($0, cellNames: all,
                                propagationCellNames: temporary.sorted(buffers, by: <),
                                sequentialPropagationCellNames: temporary.sorted(sequential, by: <),
                                limits: resources.sourceLimits, resources: resources.sourceResources)
                        }
                    }
                }
            }
            if request.requireStrictSourceEvidence {
                let selected: [String]
                if transformResources != nil {
                    try temporary.reserveSet(String.self, capacity: inputs.design.instances.count)
                    var cells: Set<String> = []; cells.reserveCapacity(inputs.design.instances.count)
                    for instance in inputs.design.instances { try transformBudget.chargeScheduledWork(1); cells.insert(instance.cell) }
                    selected = try temporary.sorted(cells, by: <)
                } else { selected = Array(Set(inputs.design.instances.map(\.cell))).sorted() }
                for corner in request.requestedCornerIDs {
                    guard let source = inputs.processInputs.sourcesByCorner[corner] else {
                        throw TimingError.invariantViolation("Missing exact strict source owner")
                    }
                    try temporary.reserve(String.self, capacity: selected.count)
                    try temporary.reserve(String.self, capacity: selected.count)
                    var propagation: [String] = [], sequential: [String] = []
                    if transformResources != nil { propagation.reserveCapacity(selected.count); sequential.reserveCapacity(selected.count) }
                    for name in selected {
                        try transformBudget.chargeScheduledWork(1)
                        try resources.sourceResources.check()
                        let cell = try source.library.cell(named: name)
                        if cell.sequentialModel != nil { sequential.append(name) }
                        else if transformResources != nil {
                            var hasInput = false
                            for pin in cell.pins {
                                try transformBudget.chargeScheduledWork(1)
                                if pin.direction == .input { hasInput = true; break }
                            }
                            if hasInput { propagation.append(name) }
                        } else if !cell.inputPins.isEmpty { propagation.append(name) }
                    }
                    clockCharacterization[corner] = try source.withBytes {
                        try characterizationParser.parseCharacterizedSource($0, cellNames: selected,
                            propagationCellNames: propagation, sequentialPropagationCellNames: sequential,
                            limits: resources.sourceLimits, resources: resources.sourceResources)
                    }
                }
            }
            let configuration: STAEffectiveConfiguration
            if transformResources != nil {
                configuration = try STAEffectiveConfiguration(request: request, modes: inputs.modeIDs,
                    constraints: inputs.constraints, limits: resources.limits, clockReceiverScope: receiverScope, transformStorage: retained)
            } else {
                configuration = try STAEffectiveConfiguration(request: request, modes: inputs.modeIDs, constraints: inputs.constraints,
                    limits: resources.limits, clockReceiverScope: receiverScope)
            }
            if let expected = request.configurationDigest, expected != configuration.digest { throw STAPreparationError.configurationMismatch }
            try Task.checkCancellation()
            var prepared = try PreparedSTAExecution(request: request, design: inputs.design, processInputs: inputs.processInputs,
                constraints: inputs.constraints, parasitics: reduced, parasiticSource: inputs.parasitics, modeIDs: inputs.modeIDs,
                catalog: resources.inspectedSources, configuration: configuration, characterization: observations,
                sourceResources: resources.sourceResources, clockCharacterization: clockCharacterization, limits: resources.limits,
                transformResources: transformResources, runtimeIdentityReadBudget: resources.runtimeIdentityReadBudget)
            if transformResources != nil {
                try retained.hold(prepared.transformRetention); try retained.hold(inputs.transformRetention)
                prepared.transformRetention = try retained.finish()
            }
            withExtendedLifetime(temporary) {}
            return prepared
        } catch {
            if let failureBoundary { throw .underlying(failureBoundary.failure(error)) }
            if let error = error as? STAPreparationError { throw error }
            if let error = error as? LibertySourceError { throw .liberty(error) }
            if let error = error as? TimingError { throw .input(error) }
            if error is CancellationError { throw .cancelled }
            throw .underlying(error)
        }
    }

    public func execute(_ prepared: PreparedSTAExecution) async throws(STAExecutionError) -> STAExecutionResult {
        let request = prepared.request
        let startedAt = Date()
        var failureBoundary: TimingControlledDiagnostics<PreparedSTAExecution>?
        do {
            failureBoundary = try prepared.transformResources.map {
                try TimingControlledDiagnostics(resources: $0, retaining: prepared)
            }
            try Task.checkCancellation()
            let result = try analyze(request: request, design: prepared.design,
                librariesByCorner: prepared.processInputs.librariesByCorner, sourcesByCorner: prepared.processInputs.sourcesByCorner, clockCharacterization: prepared.clockCharacterization, sourceResources: prepared.sourceResources, constraints: prepared.constraints,
                parasitics: prepared.parasitics, parasiticSource: prepared.parasiticSource, cornerIDs: request.requestedCornerIDs,
                modeIDs: prepared.modeIDs, processSelection: prepared.processSelection, sourceRoles: prepared.sourceRoleInventory, limits: prepared.limits, transformResources: prepared.transformResources)
            let budget = NativeSTAStateBudget(maximum: prepared.limits.maximumPathStates,
                transformResources: prepared.transformResources)
            let retained = NativeSTATransformStorage(budget: budget, kind: .liveOwnedBytes)
            try retained.hold(prepared)
            try retained.hold(result.payload.transformRetention)
            var payload = result.payload
            payload.effectiveConfiguration = prepared.effectiveConfiguration
            payload.characterization = prepared.characterization
            payload.libraryConsumption = prepared.libraryConsumption
            if request.requireStrictSourceEvidence {
                payload.sourceEvidence = .init(executionInputIdentity: prepared.executionInputIdentity,
                    configurationDigest: prepared.configurationDigest, roles: prepared.sourceRoleInventory,
                    coverage: result.sourceCoverage, samples: result.sourceSamples, pulseWidthSamples: result.pulseWidthSamples, staticStateSamples: result.staticStateSamples,
                    normalPowerSamples:result.normalPowerSamples,normalPowerOwners:result.normalPowerOwners)
                try prepared.sourceResources.chargeWork(payload.setupApplicabilityValidationWork())
                let applicabilityStorage = NativeSTATransformStorage(budget: budget, kind: .temporaryBytes)
                try applicabilityStorage.reserveDictionary(Int.self, STASourceEvidence.Coverage.Disposition.self,
                    capacity: result.sourceCoverage.count)
                var staticCapacity = 0; var notApplicableCapacity = 0
                for endpoint in payload.endpoints {
                    try budget.chargeScheduledWork(1)
                    staticCapacity = max(staticCapacity, endpoint.staticChecks?.count ?? 0)
                    notApplicableCapacity = max(notApplicableCapacity, endpoint.notApplicableChecks?.count ?? 0)
                }
                try applicabilityStorage.reserveSet(STAAnalysisKind.self, capacity: staticCapacity)
                try applicabilityStorage.reserveSet(STAAnalysisKind.self, capacity: notApplicableCapacity)
                payload.setupApplicability = try payload.derivedSetupApplicability()
                withExtendedLifetime(applicabilityStorage) {}
                try payload.sourceEvidence!.validateStructure(maximumStates: prepared.limits.maximumPathStates,
                    maximumWork: prepared.limits.maximumPathWorkUnits, stateBudget: budget)
            }
            var artifactBindings: [TimingArtifactBinding] = []
            if let artifactStore {
                let artifact: TimingArtifactBinding
                if let resources = prepared.transformResources {
                    let encoded = try TimingJSONEncoding.encode(payload,
                        formatting: [.prettyPrinted, .sortedKeys], resources: resources)
                    try resources.check()
                    artifact = try await artifactStore.store(encoded.value, artifactName: "timing-sta-report",
                        runID: request.runID, kind: .report, format: .json)
                    try resources.check(); withExtendedLifetime(encoded) {}
                } else {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    artifact = try await artifactStore.store(encoder.encode(payload), artifactName: "timing-sta-report",
                        runID: request.runID, kind: .report, format: .json)
                }
                try retained.append(artifact, to: &artifactBindings)
            }
            try Task.checkCancellation()
            let inputBindings = try NativeSTARequestTransforms.bindings(request, storage: retained)
            let inputReferences = try retained.map(inputBindings, \.reference)
            let executionProvenance: ExecutionProvenance
            if let resources = prepared.transformResources {
                let executable = try await TimingRuntimeIdentity.currentExecutableDigest(resources: resources,
                    readBudget: prepared.runtimeIdentityReadBudget)
                let environment = try TimingRuntimeIdentity.environmentFingerprint(toolchain: "timing.sta-3.0.0",
                    resources: resources)
                try retained.hold(executable); try retained.hold(environment)
                executionProvenance = try ExecutionProvenance(
                    producer: ProducerIdentity(kind: .engine, identifier: "timing.sta", version: "3.15.0", build: executable.value),
                    inputs: inputReferences, invocation: ExecutionInvocation.inProcess(entryPoint: "STAEngine.NativeSTAEngine.execute"),
                    environment: environment.value, startedAt: startedAt, completedAt: Date())
            } else {
                executionProvenance = try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: inputReferences)
            }
            payload.transformRetention = try retained.finish()
            let output = try STAExecutionResult(runID: request.runID, status: result.status, payload: payload,
                inputBindings: inputBindings, artifactBindings: artifactBindings, diagnostics: result.diagnostics,
                provenance: executionProvenance,
                schemaVersion: STARequest.currentSchemaVersion, transformBudget: budget)
            return output
        } catch is CancellationError { throw .cancelled }
        catch STAPreparationError.cancelled { throw .cancelled }
        catch let error as NativeSTAConservativeCouplingError {
            if let failureBoundary { throw .underlying(failureBoundary.failure(error)) }
            if prepared.transformResources != nil { throw .underlying(error) }
            switch error {
            case .nativeBackendFailure:
                throw .underlying(error)
            case .unsupportedNativeCapability(let message):
                throw .underlying(TimingError.unsupportedSemantic(format: "native coupled RC capability", semantic: message))
            default:
                throw .underlying(TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: String(describing: error)))
            }
        }
        catch let error as TimingCharacterizationError {
            if let failureBoundary { throw .underlying(failureBoundary.failure(error)) }
            if prepared.transformResources != nil { throw .underlying(error) }
            throw .underlying(TimingError.unsupportedSemantic(format: "propagated clock STA", semantic: error.localizedDescription))
        }
        catch {
            if let failureBoundary { throw .underlying(failureBoundary.failure(error)) }
            throw .underlying(error)
        }
    }

    public func validateSourceEvidence(_ result: STAExecutionResult, against prepared: PreparedSTAExecution)
        async throws(STAExecutionError) {
        do {
            let budget = NativeSTAStateBudget(maximum: prepared.limits.maximumPathStates,
                transformResources: prepared.transformResources)
            let temporary = NativeSTATransformStorage(budget: budget, kind: .temporaryBytes)
            let inputReferences = try temporary.map(result.inputBindings, \.reference)
            let expectedInputReferences = try NativeSTARequestTransforms.references(prepared.request, storage: temporary)
            try Task.checkCancellation(); try prepared.sourceResources.check()
            guard prepared.request.requireStrictSourceEvidence, result.status == .completed,
                  result.runID == prepared.request.runID,
                  inputReferences == expectedInputReferences,
                  result.payload.effectiveConfiguration == prepared.effectiveConfiguration,
                  result.payload.processSelection == prepared.processSelection,
                  let observed = result.payload.sourceEvidence,
                  observed.executionInputIdentity == prepared.executionInputIdentity,
                  observed.configurationDigest == prepared.configurationDigest,
                  observed.roles == prepared.sourceRoleInventory else {
                throw TimingError.invalidInput("Strict source evidence does not match the independently prepared inputs")
            }
            try observed.validateStructure(maximumStates: prepared.limits.maximumPathStates,
                maximumWork: prepared.limits.maximumPathWorkUnits, stateBudget: budget)
            // A separate finite analysis operation retains the same source accountant/deadline.
            // It publishes no artifacts and does not claim an independent numerical oracle.
            let replay = try analyze(request: prepared.request, design: prepared.design,
                librariesByCorner: prepared.processInputs.librariesByCorner,
                sourcesByCorner: prepared.processInputs.sourcesByCorner,
                clockCharacterization: prepared.clockCharacterization, sourceResources: prepared.sourceResources,
                constraints: prepared.constraints, parasitics: prepared.parasitics, parasiticSource: prepared.parasiticSource,
                cornerIDs: prepared.request.requestedCornerIDs, modeIDs: prepared.modeIDs,
                processSelection: prepared.processSelection, sourceRoles: prepared.sourceRoleInventory, limits: prepared.limits,
                transformResources: prepared.transformResources)
            let actual = STASourceEvidence(executionInputIdentity: prepared.executionInputIdentity,
                configurationDigest: prepared.configurationDigest, roles: prepared.sourceRoleInventory,
                coverage: replay.sourceCoverage, samples: replay.sourceSamples, pulseWidthSamples: replay.pulseWidthSamples, staticStateSamples: replay.staticStateSamples,
                normalPowerSamples:replay.normalPowerSamples,normalPowerOwners:replay.normalPowerOwners)
            var replayPayload = replay.payload
            replayPayload.effectiveConfiguration = prepared.effectiveConfiguration; replayPayload.sourceEvidence = actual
            try prepared.sourceResources.chargeWork(replayPayload.setupApplicabilityValidationWork())
            let applicabilityStorage = NativeSTATransformStorage(budget: budget, kind: .temporaryBytes)
            try applicabilityStorage.reserveDictionary(Int.self, STASourceEvidence.Coverage.Disposition.self,
                capacity: replay.sourceCoverage.count)
            var staticCapacity = 0; var notApplicableCapacity = 0
            for endpoint in replayPayload.endpoints {
                try budget.chargeScheduledWork(1)
                staticCapacity = max(staticCapacity, endpoint.staticChecks?.count ?? 0)
                notApplicableCapacity = max(notApplicableCapacity, endpoint.notApplicableChecks?.count ?? 0)
            }
            try applicabilityStorage.reserveSet(STAAnalysisKind.self, capacity: staticCapacity)
            try applicabilityStorage.reserveSet(STAAnalysisKind.self, capacity: notApplicableCapacity)
            let applicability = try replayPayload.derivedSetupApplicability()
            replayPayload.setupApplicability = applicability
            guard actual == observed, applicability == result.payload.setupApplicability,
                  replay.payload.endpoints == result.payload.endpoints,
                  replay.payload.worstSetupSlack == result.payload.worstSetupSlack,
                  replay.payload.worstHoldSlack == result.payload.worstHoldSlack,
                  replay.payload.criticalPaths == result.payload.criticalPaths,
                  replay.payload.violations == result.payload.violations,
                  replay.payload.unconstrainedEndpoints == result.payload.unconstrainedEndpoints,
                  replay.payload.clockObservations == result.payload.clockObservations,
                  replay.payload.wireCoverage == result.payload.wireCoverage,
                  replay.payload.wireObservations == result.payload.wireObservations,
                  replay.payload.conservativeWireObservations == result.payload.conservativeWireObservations else {
                if let resources = prepared.transformResources {
                    let message = try Self.controlledReplayMismatch(observed: result.payload,
                        actual: replayPayload, resources: resources)
                    let failure = try TimingControlledDiagnostics(resources: resources, retaining: message)
                    throw failure.failure(TimingError.invalidInput(message.value))
                }
                throw TimingError.invalidInput(try Self.boundedReplayMismatch(observed: result.payload,
                    actual: replayPayload, resources: prepared.sourceResources))
            }
            withExtendedLifetime((temporary, applicabilityStorage)) {}
            try Task.checkCancellation(); try prepared.sourceResources.check()
        } catch is CancellationError { throw .cancelled }
        catch { throw .underlying(error) }
    }

    private func characterization(_ request: STARequest, inputs: STATimingProcessInputs,
        transformStorage: NativeSTATransformStorage? = nil) throws -> [STACharacterizationObservation] {
        let bindings = request.characterizationBindings
        try transformStorage?.reserveSet(String.self, capacity: bindings.count)
        let bindingNames: [String]
        if let transformStorage { bindingNames = try transformStorage.map(bindings, \.cornerID) }
        else { bindingNames = bindings.map(\.cornerID) }
        try transformStorage?.budget.chargeScheduledWork(UInt64(bindings.count))
        guard Set(bindingNames).count == bindings.count,
              bindings.allSatisfy({ request.requestedCornerIDs.contains($0.cornerID) && !$0.conditionName.isEmpty
                  && ($0.requiredNumericProcess?.isFinite ?? true) }) else {
            throw STAPreparationError.characterization("Invalid or duplicate explicit condition binding")
        }
        if request.characterizationPolicy == .declaredCornerSelection, !bindings.isEmpty {
            throw STAPreparationError.characterization("Declared selection cannot claim observed condition bindings")
        }
        var total = 0
        if let transformStorage {
            for corner in inputs.selection.corners {
                try transformStorage.budget.chargeScheduledWork(1)
                let count = inputs.sourcesByCorner[corner.cornerID]?.operatingConditions.count ?? 0
                let next = total.addingReportingOverflow(count)
                guard !next.overflow else { throw LibertySourceError.arithmeticOverflow }
                total = next.partialValue
            }
            try transformStorage.reserve(STACharacterizationObservation.self, capacity: total)
        }
        var observations: [STACharacterizationObservation] = []
        if transformStorage?.budget.transformResources != nil { observations.reserveCapacity(total) }
        for corner in inputs.selection.corners {
            try transformStorage?.budget.chargeScheduledWork(1)
            guard let source = inputs.sourcesByCorner[corner.cornerID],
                  let reference = inputs.selection.librariesByCorner[corner.cornerID] else {
                throw STAPreparationError.characterization("Missing retained source owner")
            }
            let binding = bindings.first { $0.cornerID == corner.cornerID }
            if request.characterizationPolicy == .requireObservedConditions {
                guard let binding, let condition = source.operatingConditions.first(where: { $0.name == binding.conditionName }),
                      condition.voltage == corner.pvt.voltage, condition.temperature == corner.pvt.temperatureCelsius,
                      binding.requiredNumericProcess == nil || condition.process == binding.requiredNumericProcess else {
                    throw STAPreparationError.characterization("Explicit source voltage/temperature/process observation does not match corner")
                }
            }
            for condition in source.operatingConditions {
                try transformStorage?.budget.chargeScheduledWork(1)
                observations.append(.init(cornerID: corner.cornerID, source: reference, conditionName: condition.name,
                    numericProcess: condition.process, voltage: condition.voltage, temperatureCelsius: condition.temperature,
                    selected: request.characterizationPolicy == .requireObservedConditions && condition.name == binding?.conditionName))
            }
        }
        return observations
    }

    internal struct LoadedInputs: Sendable {
        let design: TimingDesign
        let processInputs: STATimingProcessInputs
        let constraints: [String: TimingConstraintSet]
        let parasitics: TimingParasitics?
        let cornerIDs: [String]
        let modeIDs: [String]
        var transformRetention: NativeSTATransformRetention? = nil
    }

    private func loadInputs(_ request: STARequest, resources: STAExecutionResources) async throws -> LoadedInputs {
        if resources.requiresStrictTransformAccounting {
            return try await loadControlledInputs(request, resources: resources)
        }
        guard !request.libraries.isEmpty else { throw TimingError.missingArtifact(role: "timing-library") }
        let reader = resources.reader
        for binding in request.artifactBindings {
            guard binding.byteCount <= resources.limits.maximumInputBytes else { throw STAPreparationError.capacity("Native source transform byte ceiling exceeded") }
        }
        let designData = try await reader.read(request.design)
        let design = try designParser.parse(designData, topDesignName: request.topDesignName)

        let processInputs = try await STATimingProcessInputs.load(
            request, reader: reader, parser: libraryParser, resources: resources
        )
        let cornerIDs = request.requestedCornerIDs

        let constraintData = try await reader.read(request.constraints)
        let modeIDs = unique(
            request.requestedModeIDs.isEmpty
                ? ["default"]
                : request.requestedModeIDs
        )
        let (scenarioCount, overflow) = modeIDs.count.multipliedReportingOverflow(by: cornerIDs.count)
        guard !overflow, scenarioCount <= resources.limits.maximumScenarios,
              design.instances.count + design.ports.count + design.nets.count <= resources.limits.maximumDesignElements else {
            throw STAPreparationError.capacity("Native design/scenario transform ceiling exceeded")
        }
        var constraints: [String: TimingConstraintSet] = [:]
        for modeID in modeIDs {
            constraints[modeID] = try constraintParser.parse(constraintData, modeID: modeID)
        }

        let parasitics: TimingParasitics?
        if let reference = request.parasitics {
            parasitics = try parasiticParser.parse(try await reader.read(reference))
        } else {
            if request.requiresPostLayoutInputs {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "post-layout signoff without parasitics")
            }
            parasitics = nil
        }
        return LoadedInputs(
            design: design,
            processInputs: processInputs,
            constraints: constraints,
            parasitics: parasitics,
            cornerIDs: cornerIDs,
            modeIDs: modeIDs
        )
    }

    private struct AnalysisResult: Sendable {
        let status: TimingExecutionStatus
        let diagnostics: [DesignDiagnostic]
        let payload: STAPayload
        let sourceCoverage: [STASourceEvidence.Coverage]
        let sourceSamples: [STASourceEvidence.Sample]
        let pulseWidthSamples: [STASourceEvidence.PulseWidthSample]
        let staticStateSamples: [STASourceEvidence.StaticStateSample]
        let normalPowerSamples: [STASourceEvidence.NormalPowerSample]
        let normalPowerOwners: [CheckedLibertyNormalPower]
    }

    private func validateCanonicalInputs(_ inputs: LoadedInputs,
        transformBudget: NativeSTAStateBudget) throws {
        let transformResources = transformBudget.transformResources
        let validator = TimingCanonicalValidator()
        for modeID in inputs.modeIDs {
            try transformResources?.check(); try transformResources?.chargeWork(1)
            guard let constraints = inputs.constraints[modeID] else {
                throw TimingError.invariantViolation(
                    "The parsed STA mode is missing its canonical constraint set.")
            }
            for cornerID in inputs.cornerIDs {
                try transformResources?.check(); try transformResources?.chargeWork(1)
                guard let library = inputs.processInputs.librariesByCorner[cornerID] else {
                    throw TimingError.invariantViolation("The admitted STA corner has no library.")
                }
                if let resources = transformResources {
                    let budget = transformBudget
                    let scratch = NativeSTATransformStorage(budget: budget, kind: .temporaryBytes)
                    try scratch.reserve(TimingLibrary.self, capacity: 1)
                    let report = try validator.validate(design: inputs.design, constraints: constraints,
                        libraries: [library], parasitics: inputs.parasitics, resources: resources)
                    guard report.value.isValid else {
                        let codes = try scratch.map(report.value.findings, \.code)
                        let ordered = try scratch.sorted(codes, by: <)
                        let text = try NativeSTAControlledDiagnosticText(resources: resources)
                        try text.append("Canonical STA validation failed for corner '")
                        try text.append(cornerID); try text.append("': ")
                        for (index, code) in ordered.enumerated() {
                            try budget.chargeScheduledWork(1)
                            if index > 0 { try text.append(", ") }
                            try text.append(code)
                        }
                        let message = try text.finish()
                        let failure = try TimingControlledDiagnostics(resources: resources, retaining: (report, message))
                        throw failure.failure(TimingError.invalidInput(message.value))
                    }
                    withExtendedLifetime((scratch, report)) {}
                } else {
                    let report = validator.validate(design: inputs.design, constraints: constraints,
                        libraries: [library], parasitics: inputs.parasitics)
                    guard report.isValid else {
                        throw TimingError.invalidInput(
                            "Canonical STA validation failed for corner '\(cornerID)': "
                                + report.findings.map(\.code).sorted().joined(separator: ", "))
                    }
                }
            }
        }
    }

    private func analyze(
        request: STARequest,
        design: TimingDesign,
        librariesByCorner: [String: TimingLibrary],
        sourcesByCorner: [String: OwnedLibertySource],
        clockCharacterization: [String: CharacterizedTimingLibrary], sourceResources: any LibertySourceResourceAccounting,
        constraints: [String: TimingConstraintSet],
        parasitics: TimingLumpedParasitics?,
        parasiticSource: TimingParasitics?,
        cornerIDs: [String],
        modeIDs: [String],
        processSelection: STAProcessSelection,
        sourceRoles: [STASourceEvidence.Role],
        limits: STAExecutionLimits,
        transformResources: (any LibertySourceResourceAccounting)? = nil
    ) throws -> AnalysisResult {
        var endpoints: [STAEndpoint] = []
        var unconstrainedEndpoints: [STAEndpoint] = []
        var paths: [STAPath] = []
        var violations: [STAViolation] = []
        var diagnostics: [DesignDiagnostic] = []
        let stateBudget = NativeSTAStateBudget(maximum: request.distributedRC == nil && !request.requireStrictSourceEvidence ? Int.max : limits.maximumPathStates,
            transformResources: transformResources)
        let temporary = NativeSTATransformStorage(budget: stateBudget, kind: .temporaryBytes)
        let retained = NativeSTATransformStorage(budget: stateBudget, kind: .liveOwnedBytes)
        let failureBoundary = try transformResources.map {
            try TimingControlledDiagnostics(resources: $0, retaining: sourceRoles)
        }
        var pathWork: UInt64 = 0
        var rcSteps: UInt64 = 0
        var clockObservations: [STAClockObservation] = []
        var wireCoverage: [STAWireCoverage] = []
        var wireObservations: [STADistributedRCObservation] = []
        var conservativeWireObservations: [STAConservativeWireObservation] = []
        var sourceCoverage: [STASourceEvidence.Coverage] = []
        var sourceSamples: [STASourceEvidence.Sample] = []
        var pulseWidthSamples: [STASourceEvidence.PulseWidthSample] = []
        var staticStateSamples: [STASourceEvidence.StaticStateSample] = []
        var normalPowerSamples: [STASourceEvidence.NormalPowerSample] = []
        var normalPowerOwners: [CheckedLibertyNormalPower] = []
        var roleOffset = 0

        for modeID in modeIDs {
            try Task.checkCancellation()
            guard let constraint = constraints[modeID] else {
                throw try NativeSTATransformStorage.sourceFailure(diagnostics: failureBoundary,
                    "No constraints were parsed for mode '", modeID, "'.") { TimingError.invalidInput($0) }
            }
            guard constraint.caseAnalyses.isEmpty else {
                throw TimingError.unsupportedSemantic(
                    format: "STA",
                    semantic: "conditional timing arc pruning for set_case_analysis"
                )
            }
            for cornerID in cornerIDs {
                try Task.checkCancellation()
                guard let library = librariesByCorner[cornerID], let source = sourcesByCorner[cornerID] else {
                    throw TimingError.invariantViolation("The selected STA scenario has no admitted library.")
                }
                let start = roleOffset
                while roleOffset < sourceRoles.count, sourceRoles[roleOffset].modeID == modeID,
                      sourceRoles[roleOffset].cornerID == cornerID { roleOffset += 1 }
                let count = roleOffset - start
                let nextWork = pathWork.addingReportingOverflow(UInt64(count))
                guard !nextWork.overflow, nextWork.partialValue <= limits.maximumPathWorkUnits else {
                    throw STAPathAnalysisError.capacity(resource: "source scenario roles", limit: limits.maximumPathWorkUnits)
                }
                pathWork = nextWork.partialValue; try stateBudget.reserve(count)
                let scenarioStorage = NativeSTATransformStorage(budget: stateBudget, kind: .temporaryBytes)
                let scenarioRoles = try scenarioStorage.map(sourceRoles[start..<roleOffset]) { $0 }
                let scenario = try analyzeScenario(
                    request: request,
                    design: design,
                    library: library, source: source, clockCharacterization: clockCharacterization[cornerID], sourceResources: sourceResources,
                    constraints: constraint,
                    parasitics: parasitics, parasiticSource: parasiticSource,
                    modeID: modeID,
                    cornerID: cornerID, sourceRoles: scenarioRoles, limits: limits, stateBudget: stateBudget, work: &pathWork, rcSteps: &rcSteps
                )
                try retained.hold(scenario)
                withExtendedLifetime(scenarioStorage) {}
                let outputSlots = scenario.sourceCoverage.count.addingReportingOverflow(scenario.sourceSamples.count)
                let pulseSlots = scenario.pulseWidthSamples.count.addingReportingOverflow(scenario.staticStateSamples.count)
                let powerSlots = scenario.normalPowerSamples.count.addingReportingOverflow(scenario.normalPowerOwners.count)
                let nonPowerSlots = outputSlots.partialValue.addingReportingOverflow(pulseSlots.partialValue)
                let allSlots = nonPowerSlots.partialValue.addingReportingOverflow(powerSlots.partialValue)
                guard !outputSlots.overflow, !pulseSlots.overflow, !powerSlots.overflow, !nonPowerSlots.overflow, !allSlots.overflow else { throw TimingError.invalidInput("Source output workspace overflow") }
                let outputWork = pathWork.addingReportingOverflow(UInt64(allSlots.partialValue))
                guard !outputWork.overflow, outputWork.partialValue <= limits.maximumPathWorkUnits else {
                    throw STAPathAnalysisError.capacity(resource: "source output work", limit: limits.maximumPathWorkUnits)
                }
                try stateBudget.reserve(allSlots.partialValue); pathWork = outputWork.partialValue
                for entry in scenario.sourceCoverage {
                    try retained.append(.init(role: entry.role + start, disposition: entry.disposition, witness: entry.witness), to: &sourceCoverage, site: 20001)
                }
                for sample in scenario.sourceSamples {
                    try retained.append(.init(role: sample.role + start, context: sample.context,
                        inputEdge: sample.inputEdge, outputEdge: sample.outputEdge, inputPoint: sample.inputPoint,
                        receiver: sample.receiver, observation: sample.observation, appliedScale: sample.appliedScale,
                        sequentialCoordinate: sample.sequentialCoordinate, rangeObservation: sample.rangeObservation), to: &sourceSamples, site: 20002)
                }
                for sample in scenario.pulseWidthSamples {
                    try retained.append(.init(role: sample.role + start, context: sample.context, observation: sample.observation,
                        rangeObservation: sample.rangeObservation, rootSource: sample.rootSource, openingSlew: sample.openingSlew,
                        openingSegments: sample.openingSegments, closingSegments: sample.closingSegments,
                        openingArrival: sample.openingArrival, closingArrival: sample.closingArrival,
                        openingRootEdge: sample.openingRootEdge, closingRootEdge: sample.closingRootEdge,
                        openingRootPhase: sample.openingRootPhase, closingRootPhase: sample.closingRootPhase,
                        closingCycleOffset: sample.closingCycleOffset, period: sample.period, uncertainty: sample.uncertainty), to: &pulseWidthSamples, site: 20003)
                }
                for sample in scenario.staticStateSamples {
                    try retained.append(.init(role: sample.role + start, clear: sample.clear, preset: sample.preset,
                        effect: sample.effect, inputConstants: sample.inputConstants, powerConstants: sample.powerConstants,
                        outputConstants: sample.outputConstants), to: &staticStateSamples, site: 20004)
                }
                for sample in scenario.normalPowerSamples {
                    try retained.append(.init(role:sample.role + start,observation:sample.observation), to: &normalPowerSamples, site: 20005)
                }
                try retained.append(contentsOf:scenario.normalPowerOwners, to: &normalPowerOwners, site: 20006)
                try retained.append(contentsOf: scenario.clockObservations, to: &clockObservations, site: 20007)
                try retained.append(contentsOf: scenario.wireCoverage, to: &wireCoverage, site: 20008)
                try retained.append(contentsOf: scenario.wireObservations, to: &wireObservations, site: 20009)
                try retained.append(contentsOf: scenario.conservativeWireObservations, to: &conservativeWireObservations, site: 20010)
                try retained.append(contentsOf: scenario.endpoints, to: &endpoints, site: 20011)
                try retained.append(contentsOf: scenario.unconstrainedEndpoints, to: &unconstrainedEndpoints, site: 20012)
                try temporary.append(contentsOf: scenario.paths, to: &paths, site: 20013)
                try retained.append(contentsOf: scenario.violations, to: &violations, site: 20014)
            }
        }

        if parasitics == nil {
            try retained.reserve(String.self, capacity: 2)
            try retained.append(DesignDiagnostic(
                severity: .warning,
                code: "timing.sta.post_layout_inputs_missing",
                message: "STA ran without parasitics, so post-layout timing effects were not analyzed.",
                suggestedActions: ["provide_spef_artifact", "run_pex_before_signoff"]
            ), to: &diagnostics, site: 20015)
        }
        if let parasitics {
            if request.conservativeCoupledRC != nil {
                try retained.reserve(String.self, capacity: 2)
                try retained.append(.init(severity: .information, code: "timing.sta.certified_coupled_boundary",
                    message: "Conservative bounds cover all admitted normalized bounded-operating source histories in the NLDM prescribed-boundary model under its retained load abstraction; this does not qualify the load approximation, physical current drive or CCS behavior.",
                    suggestedActions: ["inspect_conservative_wire_observations", "review_retained_load_model"]), to: &diagnostics, site: 20015)
            } else if request.distributedRC == nil {
                // The lower evidence formatter emits at most three records, with
                // native Array capacities 1 -> 2 -> 4 (old/new peak six records).
                try temporary.reserve(DesignDiagnostic.self, capacity: 6)
                try retained.reserve(String.self, capacity: 5)
                try stateBudget.chargeScheduledWork(UInt64(parasitics.evidence.inventoryComparisons.count))
                try retained.reserve(UInt8.self, capacity: "timing.sta.equipotential_cap_load_approximation".utf8.count)
                if !parasitics.evidence.collapsedIntraNetCapacitances.isEmpty {
                    try retained.reserve(UInt8.self, capacity: "timing.sta.intra_net_dynamic_capacitance_not_evaluated".utf8.count)
                    let bytes = try TimingDiagnosticTextCapacity.description(literal:
                        " same-net capacitance operators retain exact endpoints and values but contribute zero under the equipotential projection.",
                        ints: 1, doubles: 0, booleans: 0)
                    guard let count = Int(exactly: bytes) else { throw LibertySourceError.arithmeticOverflow }
                    try retained.reserve(UInt8.self, capacity: count)
                }
                if parasitics.evidence.inventoryComparisons.contains(where: { $0.difference != 0 }) {
                    try retained.reserve(UInt8.self, capacity: "timing.sta.declared_capacitance_inventory_differs".utf8.count)
                }
                try retained.append(contentsOf: parasitics.evidence.diagnostics(prefix: "timing.sta"), to: &diagnostics, site: 20015)
            } else {
                try retained.reserve(String.self, capacity: 2)
                try retained.append(.init(severity: .information, code: "timing.sta.prescribed_ramp_distributed_rc",
                    message: "Distributed passive RC response uses characterized-slew prescribed linear drivers; crossing differences are observed grid convergence, not physical error certification.",
                    suggestedActions: ["review_prescribed_driver_assumption", "inspect_wire_observations"]), to: &diagnostics, site: 20015)
            }
        }
        try retained.reserve(String.self, capacity: request.libraries.count)
        try stateBudget.chargeScheduledWork(UInt64(request.libraries.count))
        let provenance = provenance(for: request)
        if !provenance.hasCoreDigests || provenance.libraryDigests.isEmpty {
            try retained.reserve(String.self, capacity: 4)
            try retained.append(DesignDiagnostic(
                severity: .warning,
                code: "timing.sta.incomplete_timing_provenance",
                message: "The timing verdict is missing one or more immutable input digests.",
                suggestedActions: ["record_design_digest", "record_library_digest", "record_constraint_digest", "record_pdk_digest"]
            ), to: &diagnostics, site: 20015)
        }
        try temporary.reserve(String.self, capacity: 4)
        for violation in violations {
            let codeBytes = try TimingDiagnosticTextCapacity.description(literal: "timing.sta._violation",
                ints: 0, doubles: 0, booleans: 0, additionalUTF8: UInt64(violation.kind.rawValue.utf8.count))
            var fields: UInt64 = 0
            for field in [violation.kind.rawValue, violation.endpoint, violation.modeID, violation.cornerID] {
                let next = fields.addingReportingOverflow(UInt64(field.utf8.count))
                guard !next.overflow else { throw LibertySourceError.arithmeticOverflow }; fields = next.partialValue
            }
            let messageBytes = try TimingDiagnosticTextCapacity.description(literal: " slack is  at  in mode , corner .",
                ints: 0, doubles: 1, booleans: 0, additionalUTF8: fields)
            guard let codeCount = Int(exactly: codeBytes), let messageCount = Int(exactly: messageBytes) else {
                throw LibertySourceError.arithmeticOverflow
            }
            try retained.reserve(UInt8.self, capacity: codeCount)
            try retained.reserve(UInt8.self, capacity: messageCount)
            let numericScratch = try stateBudget.reservePayload(UInt8.self, capacity: 64, kind: .temporaryBytes)
            let code = "timing.sta.\(violation.kind.rawValue)_violation"
            try retained.append(DesignDiagnostic(
                severity: .error,
                code: code,
                message: "\(violation.kind.rawValue) slack is \(format(violation.slack)) at \(violation.endpoint) in mode \(violation.modeID), corner \(violation.cornerID).",
                entity: violation.endpoint,
                suggestedActions: violation.suggestedActions
            ), to: &diagnostics, site: 20015)
            withExtendedLifetime(numericScratch) {}
        }
        var worstSetup: Double? = nil; var worstHold: Double? = nil
        for endpoint in endpoints {
            try stateBudget.chargeScheduledWork(1)
            if let value = endpoint.setupSlack { worstSetup = min(worstSetup ?? value, value) }
            if let value = endpoint.holdSlack { worstHold = min(worstHold ?? value, value) }
        }
        let orderedPaths = try temporary.sorted(paths) { $0.slack < $1.slack }
        let criticalPaths = try retained.map(orderedPaths.prefix(request.maxPaths)) { $0 }
        var payload = STAPayload(
            worstSetupSlack: worstSetup,
            worstHoldSlack: worstHold,
            analyzedCorners: cornerIDs,
            analyzedModes: modeIDs,
            endpoints: endpoints,
            unconstrainedEndpoints: unconstrainedEndpoints,
            criticalPaths: criticalPaths,
            violations: violations,
            repairCandidates: try retained.map(violations) { violation in
                let rationale = try retained.joined("The reported ", violation.kind.rawValue, " slack is negative.")
                return STARepairCandidate(
                    kind: violation.kind == .hold ? .addHoldBuffer : .upsizeCell,
                    endpoint: violation.endpoint,
                    modeID: violation.modeID,
                    cornerID: violation.cornerID,
                    rationale: rationale,
                    expectedImpact: violation.kind == .hold ? "Increase minimum data-path delay." : "Reduce late data-path delay."
                )
            },
            parasiticReduction: parasitics?.evidence,
            wireObservations: wireObservations, conservativeWireObservations: conservativeWireObservations, wireCoverage: wireCoverage, clockObservations: clockObservations,
            provenance: provenance,
            processSelection: processSelection
        )
        guard roleOffset == sourceRoles.count else { throw TimingError.invariantViolation("Unconsumed strict source scenario roles") }
        let base = AnalysisResult(status: .completed, diagnostics: diagnostics, payload: payload,
            sourceCoverage: sourceCoverage, sourceSamples: sourceSamples, pulseWidthSamples: pulseWidthSamples,
            staticStateSamples: staticStateSamples, normalPowerSamples: normalPowerSamples, normalPowerOwners: normalPowerOwners)
        try retained.hold(base)
        payload.transformRetention = try retained.finish()
        return AnalysisResult(status: .completed, diagnostics: diagnostics, payload: payload,
            sourceCoverage: sourceCoverage, sourceSamples: sourceSamples, pulseWidthSamples: pulseWidthSamples, staticStateSamples: staticStateSamples,
            normalPowerSamples:normalPowerSamples,normalPowerOwners:normalPowerOwners)
    }

    private func analyzeScenario(request: STARequest, design: TimingDesign, library: TimingLibrary, source: OwnedLibertySource, clockCharacterization: CharacterizedTimingLibrary?, sourceResources: any LibertySourceResourceAccounting,
        constraints: TimingConstraintSet, parasitics: TimingLumpedParasitics?, parasiticSource: TimingParasitics?, modeID: String,
        cornerID: String, sourceRoles: [STASourceEvidence.Role], limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget, work: inout UInt64, rcSteps: inout UInt64) throws -> STAPathAnalysisResult {
        var analysis = try NativeSTAPathAnalysis(request: request, design: design, library: library, source: source,
            constraints: constraints, clockCharacterization: clockCharacterization, sourceResources: sourceResources, stateBudget: stateBudget, sourceRoles: sourceRoles, limits: limits, mode: modeID, corner: cornerID, initialWork: work, initialRCSteps: rcSteps)
        let result = try analysis.run(parasitics: parasitics, parasiticSource: parasiticSource)
        work = result.workUnits; rcSteps = result.rcSteps
        return result
    }

    private func cancelledEnvelope(request: STARequest, startedAt: Date) throws -> STAExecutionResult {
        try STAExecutionResult(runID: request.runID, status: .cancelled, payload: emptyPayload(request: request),
            inputBindings: request.artifactBindings,
            provenance: makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs))
    }

    private func blockedEnvelope(
        request: STARequest,
        startedAt: Date,
        error: TimingError
    ) throws -> STAExecutionResult {
        try STAExecutionResult(
            runID: request.runID,
            status: .blocked,
            payload: emptyPayload(request: request),
            inputBindings: request.artifactBindings,
            diagnostics: [DesignDiagnostic(
                severity: .error,
                code: diagnosticCode(for: error),
                message: error.localizedDescription,
                suggestedActions: ["inspect_input_artifacts", "check_supported_semantics"]
            )],
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: STARequest.currentSchemaVersion
        )
    }

    private func provenanceBlockedEnvelope(
        request: STARequest,
        startedAt: Date,
        issues: [LogicDesignProvenanceValidation.Issue]
    ) throws -> STAExecutionResult {
        try STAExecutionResult(
            runID: request.runID,
            status: .blocked,
            payload: emptyPayload(request: request),
            inputBindings: request.artifactBindings,
            diagnostics: issues.map { issue in
                DesignDiagnostic(
                    severity: .error,
                    code: issue.diagnosticCode,
                    message: issue.message,
                    suggestedActions: ["repair_design_provenance", "recreate_design_handoff"]
                )
            },
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: STARequest.currentSchemaVersion
        )
    }

    private func failedEnvelope(
        request: STARequest,
        startedAt: Date,
        error: TimingError
    ) throws -> STAExecutionResult {
        try STAExecutionResult(
            runID: request.runID,
            status: .failed,
            payload: emptyPayload(request: request),
            inputBindings: request.artifactBindings,
            diagnostics: [DesignDiagnostic(
                severity: .error,
                code: "timing.sta.artifact_write_failed",
                message: error.localizedDescription,
                suggestedActions: ["inspect_output_directory", "retry_with_writable_artifact_store"]
            )],
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: STARequest.currentSchemaVersion
        )
    }

    private func emptyPayload(request: STARequest) -> STAPayload {
        STAPayload(
            worstSetupSlack: nil,
            worstHoldSlack: nil,
            analyzedCorners: [],
            analyzedModes: request.requestedModeIDs,
            provenance: provenance(for: request)
        )
    }

    private func provenance(for request: STARequest) -> TimingArtifactProvenance {
        TimingArtifactProvenance(
            designDigest: request.canonicalDesignDigest?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
            libraryDigests: request.libraries.map { $0.artifact.digest.hexadecimalValue },
            constraintDigest: request.constraints.digest.hexadecimalValue,
            pdkDigest: request.pdkDigest?.hexadecimalValue ?? request.pdkManifest.digest.hexadecimalValue,
            parasiticsDigest: request.parasitics?.digest.hexadecimalValue
        )
    }

    private func logicDesignReference(for request: STARequest) -> LogicDesignReference {
        LogicDesignReference(
            artifact: request.design.reference,
            topDesignName: request.topDesignName,
            designDigest: request.canonicalDesignDigest?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
            provenance: LogicDesignProvenance(
                sourceDesignDigest: request.canonicalDesignDigest?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
                inputDesignDigest: request.design.digest.hexadecimalValue,
                producerID: "timing.sta",
                producerVersion: "3.0.0",
                runID: request.runID
            )
        )
    }

    private func makeProvenance(
        startedAt: Date,
        completedAt: Date,
        inputs: [ArtifactReference]
    ) throws -> ExecutionProvenance {
        try ExecutionProvenance(
            producer: ProducerIdentity(
                kind: .engine,
                identifier: "timing.sta",
                version: "3.15.0",
                build: TimingRuntimeIdentity.currentExecutableDigest()
            ),
            inputs: inputs,
            invocation: ExecutionInvocation.inProcess(
                entryPoint: "STAEngine.NativeSTAEngine.execute"
            ),
            environment: try TimingRuntimeIdentity.environmentFingerprint(
                toolchain: "timing.sta-3.0.0"
            ),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    internal static func boundedReplayMismatch(observed: STAPayload, actual: STAPayload,
        resources: any LibertySourceResourceAccounting) throws -> String {
        func charge() throws { try Task.checkCancellation(); try resources.check(); try resources.chargeWork(1) }
        func text(_ value: String, limit: Int = 96) -> String {
            String(decoding: value.utf8.prefix(limit), as: UTF8.self)
        }
        func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
        func pair(_ name: String, _ observed: Double, _ actual: Double) -> String {
            name + "=" + bits(observed) + "/" + bits(actual)
        }
        func firstDifference<T: Equatable>(_ lhs: [T], _ rhs: [T]) throws -> Int? {
            for index in 0..<min(lhs.count, rhs.count) {
                try charge()
                if lhs[index] != rhs[index] { return index }
            }
            return lhs.count == rhs.count ? nil : min(lhs.count, rhs.count)
        }
        func location<T>(_ name: String, _ index: Int, _ lhs: [T], _ rhs: [T]) -> String {
            name + "[" + String(index) + ";count=" + String(lhs.count) + "/" + String(rhs.count) + "]"
        }
        var fields: [String] = []
        func array<T: Equatable>(_ name: String, _ lhs: [T], _ rhs: [T]) throws {
            if let index = try firstDifference(lhs, rhs) { fields.append(location(name, index, lhs, rhs)) }
        }
        try charge()
        if actual.sourceEvidence != observed.sourceEvidence {
            var detail = "sourceEvidence"
            if let lhs = observed.sourceEvidence, let rhs = actual.sourceEvidence {
                if lhs.version != rhs.version { detail += ".version" }
                else if lhs.executionInputIdentity != rhs.executionInputIdentity { detail += ".executionInputIdentity" }
                else if lhs.configurationDigest != rhs.configurationDigest { detail += ".configurationDigest" }
                else if let index = try firstDifference(lhs.roles, rhs.roles) { detail = location("sourceEvidence.roles", index, lhs.roles, rhs.roles) }
                else if let index = try firstDifference(lhs.coverage, rhs.coverage) { detail = location("sourceEvidence.coverage", index, lhs.coverage, rhs.coverage) }
                else if let index = try firstDifference(lhs.samples, rhs.samples) {
                    detail = location("sourceEvidence.samples", index, lhs.samples, rhs.samples)
                    if index < lhs.samples.count, index < rhs.samples.count {
                        let a = lhs.samples[index], b = rhs.samples[index]
                        detail += " role=" + String(a.role) + "/" + String(b.role)
                            + " receiver=" + text(a.receiver) + "/" + text(b.receiver)
                            + " context=" + a.context.rawValue + "/" + b.context.rawValue
                            + " edge=" + a.inputEdge.rawValue + "/" + b.inputEdge.rawValue
                            + " " + pair("first", a.observation.firstInput, b.observation.firstInput)
                            + " " + pair("second", a.observation.secondInput, b.observation.secondInput)
                            + " " + pair("result", a.observation.result, b.observation.result)
                        if let ar = a.rangeObservation, let br = b.rangeObservation {
                            detail += " " + pair("rangeInputLo", ar.firstInput.lowerBound, br.firstInput.lowerBound)
                                + " " + pair("rangeInputHi", ar.firstInput.upperBound, br.firstInput.upperBound)
                                + " " + pair("rangeResultLo", ar.result.lowerBound, br.result.lowerBound)
                                + " " + pair("rangeResultHi", ar.result.upperBound, br.result.upperBound)
                        }
                    }
                } else if let index = try firstDifference(lhs.pulseWidthSamples, rhs.pulseWidthSamples) { detail = location("sourceEvidence.pulseWidthSamples", index, lhs.pulseWidthSamples, rhs.pulseWidthSamples) }
                else if let index = try firstDifference(lhs.staticStateSamples, rhs.staticStateSamples) { detail = location("sourceEvidence.staticStateSamples", index, lhs.staticStateSamples, rhs.staticStateSamples) }
                else if let index = try firstDifference(lhs.normalPowerSamples, rhs.normalPowerSamples) { detail = location("sourceEvidence.normalPowerSamples", index, lhs.normalPowerSamples, rhs.normalPowerSamples) }
            }
            fields.append(detail)
        }
        try charge()
        if observed.setupApplicability != actual.setupApplicability { fields.append("setupApplicability") }
        try array("endpoints", observed.endpoints, actual.endpoints)
        if observed.worstSetupSlack != actual.worstSetupSlack { fields.append("worstSetupSlack") }
        if observed.worstHoldSlack != actual.worstHoldSlack { fields.append("worstHoldSlack") }
        try array("criticalPaths", observed.criticalPaths, actual.criticalPaths)
        try array("violations", observed.violations, actual.violations)
        try array("unconstrainedEndpoints", observed.unconstrainedEndpoints, actual.unconstrainedEndpoints)
        try array("clockObservations", observed.clockObservations, actual.clockObservations)
        try array("wireCoverage", observed.wireCoverage, actual.wireCoverage)
        try array("wireObservations", observed.wireObservations, actual.wireObservations)
        if let index = try firstDifference(observed.conservativeWireObservations, actual.conservativeWireObservations) {
            var detail = location("conservativeWireObservations", index, observed.conservativeWireObservations, actual.conservativeWireObservations)
            if index < observed.conservativeWireObservations.count, index < actual.conservativeWireObservations.count {
                let a = observed.conservativeWireObservations[index], b = actual.conservativeWireObservations[index]
                try resources.chargeWork(UInt64(a.sourceAuthorities.count) + UInt64(b.sourceAuthorities.count))
                detail += " authorityEqual=" + String(a.sourceAuthorities == b.sourceAuthorities)
                detail += " query=" + text(a.net) + ":" + text(a.sink.name) + ":" + a.edge.rawValue
                    + "/" + text(b.net) + ":" + text(b.sink.name) + ":" + b.edge.rawValue
                for (name, av, bv) in [("sourceLo", a.sourceSlew.lowerBound, b.sourceSlew.lowerBound),
                    ("sourceHi", a.sourceSlew.upperBound, b.sourceSlew.upperBound),
                    ("admittedLo", a.admittedSourceSlew.lowerBound, b.admittedSourceSlew.lowerBound),
                    ("admittedHi", a.admittedSourceSlew.upperBound, b.admittedSourceSlew.upperBound),
                    ("delayLo", a.delay.lowerBound, b.delay.lowerBound), ("delayHi", a.delay.upperBound, b.delay.upperBound),
                    ("slewLo", a.slew.lowerBound, b.slew.lowerBound), ("slewHi", a.slew.upperBound, b.slew.upperBound),
                    ("error", a.voltageErrorUpperBound, b.voltageErrorUpperBound),
                    ("derivativeMin", a.minimumCrossingDerivative, b.minimumCrossingDerivative),
                    ("derivativeMax", a.maximumAbsoluteDerivative, b.maximumAbsoluteDerivative)] {
                    try charge(); detail += " " + pair(name, av, bv)
                }
            }
            fields.append(detail)
        }
        return text("Strict source consumption or actual operands differ from bounded replay; observed/actual: "
            + fields.joined(separator: "; "), limit: 4096)
    }

    internal static func nativeBackendFailureDiagnostic(for error: any Error) -> DesignDiagnostic? {
        guard let coupling = error as? NativeSTAConservativeCouplingError,
              case .nativeBackendFailure(let message) = coupling else { return nil }
        return DesignDiagnostic(severity: .error, code: "timing.sta.native_backend_failed",
            message: message, suggestedActions: ["inspect_native_backend_diagnostics", "reproduce_with_timing_cli"])
    }

    private func diagnosticCode(for error: TimingError) -> String {
        switch error {
        case .unsupportedSemantic(let format, _) where format == "certified coupled RC": return "timing.sta.coupled_rc_inconclusive"
        case .unsupportedSemantic: return "timing.sta.sta_unsupported_semantic"
        case .missingArtifact: return "timing.sta.missing_artifact"
        case .artifactDigestMismatch: return "timing.sta.artifact_digest_mismatch"
        case .artifactSizeMismatch: return "timing.sta.artifact_size_mismatch"
        case .artifactReadFailed: return "timing.sta.artifact_read_failed"
        case .parseFailure, .spefOwnership, .parasiticReduction: return "timing.sta.parse_failed"
        case .invalidInput: return "timing.sta.invalid_input"
        case .artifactWriteFailed: return "timing.sta.artifact_write_failed"
        case .invariantViolation: return "timing.sta.invariant_violation"
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.6g s", value)
    }
}

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
        do {
            try Task.checkCancellation()
            // FIXME(INCOMPLETE_IMPLEMENTATION): Native prepare has no strict payload/work accountant for
            // design/SDC/SPEF/graph/scenario transforms. Callers demanding it are refused before intake;
            // admission must remain blocked until every transform pre-admits its own allocations and work.
            guard !resources.requiresStrictTransformAccounting else { throw STAPreparationError.unsupportedBoundedTransformAccounting }
            guard request.randomSeed == nil else { throw STAPreparationError.unsupportedRandomSeed }
            guard request.variation.isValid else { throw TimingError.invalidInput("Invalid STA derates") }
            guard request.maxPaths <= resources.limits.maximumPaths else { throw STAPreparationError.capacity("Path limit exceeded") }
            let inputs = try await loadInputs(request, resources: resources)
            try validateCanonicalInputs(inputs)
            guard request.controlPulseSources.isEmpty || request.requireStrictSourceEvidence else {
                throw TimingError.invalidInput("Explicit control pulses require source-qualified execution")
            }
            for pulse in request.controlPulseSources {
                try resources.sourceResources.check(); try resources.sourceResources.chargeWork(UInt64(inputs.design.ports.count + request.controlPulseSources.count))
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
            let issues = LogicDesignProvenanceValidation.issues(for: logicDesignReference(for: request),
                requireProvenance: request.requiresPostLayoutInputs)
            guard issues.isEmpty else { throw TimingError.invalidInput("STA design provenance is incomplete") }
            let observations = try characterization(request, inputs: inputs.processInputs)
            let reduced = try inputs.parasitics.map { try parasiticReducer.reduce($0) }
            var clockCharacterization: [String: CharacterizedTimingLibrary] = [:]
            var receiverScope: [STAClockReceiverScope] = []
            if inputs.constraints.values.contains(where: { $0.clocks.contains(where: \.isPropagated) }) {
                guard request.distributedRC != nil || request.conservativeCoupledRC != nil else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "propagated clock requires explicit wire timing options") }
                let clockPlanBudget = NativeSTAStateBudget(maximum: resources.limits.maximumPathStates)
                var clockPlanWork: UInt64 = 0
                for corner in request.requestedCornerIDs {
                    guard let source = inputs.processInputs.sourcesByCorner[corner] else { throw TimingError.invariantViolation("Missing clock source owner") }
                    var buffers = Set<String>(), sequential = Set<String>()
                    var plans: [Int: NativeSTASequentialExecution.Plan] = [:]
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
                        let selected = try NativeSTAClockPropagation.characterizationCells(design: inputs.design, library: source.library,
                            constraints: [inputs.constraints[mode]!], plans: plans,
                            resources: resources.sourceResources, delimiter: inputs.parasitics?.pinDelimiter ?? ":")
                        buffers.formUnion(selected.buffers); sequential.formUnion(selected.sequential)
                        for receiver in selected.receivers {
                            guard receiverScope.count < resources.limits.maximumPathStates else { throw STAPreparationError.capacity("Clock receiver scope") }
                            receiverScope.append(.init(modeID: mode, cornerID: corner, rootClock: receiver.root, receiver: receiver.receiver))
                        }
                    }
                    let all = Array(buffers.union(sequential)).sorted()
                    guard !all.isEmpty else { throw TimingError.unsupportedSemantic(format: "propagated clock STA", semantic: "no actual FF clock characterization scope") }
                    if !request.requireStrictSourceEvidence {
                        clockCharacterization[corner] = try source.withBytes {
                            try characterizationParser.parseCharacterizedSource($0, cellNames: all, propagationCellNames: buffers.sorted(),
                                sequentialPropagationCellNames: sequential.sorted(), limits: resources.sourceLimits, resources: resources.sourceResources)
                        }
                    }
                }
            }
            if request.requireStrictSourceEvidence {
                let selected = Array(Set(inputs.design.instances.map(\.cell))).sorted()
                for corner in request.requestedCornerIDs {
                    guard let source = inputs.processInputs.sourcesByCorner[corner] else {
                        throw TimingError.invariantViolation("Missing exact strict source owner")
                    }
                    var propagation: [String] = [], sequential: [String] = []
                    for name in selected {
                        try resources.sourceResources.check()
                        let cell = try source.library.cell(named: name)
                        if cell.sequentialModel != nil { sequential.append(name) }
                        else if !cell.inputPins.isEmpty { propagation.append(name) }
                    }
                    clockCharacterization[corner] = try source.withBytes {
                        try characterizationParser.parseCharacterizedSource($0, cellNames: selected,
                            propagationCellNames: propagation, sequentialPropagationCellNames: sequential,
                            limits: resources.sourceLimits, resources: resources.sourceResources)
                    }
                }
            }
            let configuration = try STAEffectiveConfiguration(request: request, modes: inputs.modeIDs, constraints: inputs.constraints,
                limits: resources.limits, clockReceiverScope: receiverScope)
            if let expected = request.configurationDigest, expected != configuration.digest { throw STAPreparationError.configurationMismatch }
            try Task.checkCancellation()
            return try PreparedSTAExecution(request: request, design: inputs.design, processInputs: inputs.processInputs,
                constraints: inputs.constraints, parasitics: reduced, parasiticSource: inputs.parasitics, modeIDs: inputs.modeIDs,
                catalog: resources.inspectedSources, configuration: configuration, characterization: observations, sourceResources: resources.sourceResources, clockCharacterization: clockCharacterization, limits: resources.limits)
        } catch let error as STAPreparationError { throw error }
        catch let error as LibertySourceError { throw .liberty(error) }
        catch let error as TimingError { throw .input(error) }
        catch is CancellationError { throw .cancelled }
        catch { throw .underlying(error) }
    }

    public func execute(_ prepared: PreparedSTAExecution) async throws(STAExecutionError) -> STAExecutionResult {
        let request = prepared.request
        let startedAt = Date()
        do {
            try Task.checkCancellation()
            let result = try analyze(request: request, design: prepared.design,
                librariesByCorner: prepared.processInputs.librariesByCorner, sourcesByCorner: prepared.processInputs.sourcesByCorner, clockCharacterization: prepared.clockCharacterization, sourceResources: prepared.sourceResources, constraints: prepared.constraints,
                parasitics: prepared.parasitics, parasiticSource: prepared.parasiticSource, cornerIDs: request.requestedCornerIDs,
                modeIDs: prepared.modeIDs, processSelection: prepared.processSelection, sourceRoles: prepared.sourceRoleInventory, limits: prepared.limits)
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
                payload.setupApplicability = try payload.derivedSetupApplicability()
                try payload.sourceEvidence!.validateStructure(maximumStates: prepared.limits.maximumPathStates,
                    maximumWork: prepared.limits.maximumPathWorkUnits)
            }
            var artifactBindings: [TimingArtifactBinding] = []
            if let artifactStore {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let artifact = try await artifactStore.store(encoder.encode(payload), artifactName: "timing-sta-report",
                    runID: request.runID, kind: .report, format: .json)
                artifactBindings.append(artifact)
            }
            try Task.checkCancellation()
            return try STAExecutionResult(runID: request.runID, status: result.status, payload: payload,
                inputBindings: request.artifactBindings, artifactBindings: artifactBindings, diagnostics: result.diagnostics,
                provenance: makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
                schemaVersion: STARequest.currentSchemaVersion)
        } catch is CancellationError { throw .cancelled }
        catch STAPreparationError.cancelled { throw .cancelled }
        catch let error as NativeSTAConservativeCouplingError {
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
            throw .underlying(TimingError.unsupportedSemantic(format: "propagated clock STA", semantic: error.localizedDescription))
        }
        catch { throw .underlying(error) }
    }

    public func validateSourceEvidence(_ result: STAExecutionResult, against prepared: PreparedSTAExecution)
        async throws(STAExecutionError) {
        do {
            try Task.checkCancellation(); try prepared.sourceResources.check()
            guard prepared.request.requireStrictSourceEvidence, result.status == .completed,
                  result.runID == prepared.request.runID,
                  result.inputBindings.map(\.reference) == prepared.inputReferences,
                  result.payload.effectiveConfiguration == prepared.effectiveConfiguration,
                  result.payload.processSelection == prepared.processSelection,
                  let observed = result.payload.sourceEvidence,
                  observed.executionInputIdentity == prepared.executionInputIdentity,
                  observed.configurationDigest == prepared.configurationDigest,
                  observed.roles == prepared.sourceRoleInventory else {
                throw TimingError.invalidInput("Strict source evidence does not match the independently prepared inputs")
            }
            try observed.validateStructure(maximumStates: prepared.limits.maximumPathStates,
                maximumWork: prepared.limits.maximumPathWorkUnits)
            // A separate finite analysis operation retains the same source accountant/deadline.
            // It publishes no artifacts and does not claim an independent numerical oracle.
            let replay = try analyze(request: prepared.request, design: prepared.design,
                librariesByCorner: prepared.processInputs.librariesByCorner,
                sourcesByCorner: prepared.processInputs.sourcesByCorner,
                clockCharacterization: prepared.clockCharacterization, sourceResources: prepared.sourceResources,
                constraints: prepared.constraints, parasitics: prepared.parasitics, parasiticSource: prepared.parasiticSource,
                cornerIDs: prepared.request.requestedCornerIDs, modeIDs: prepared.modeIDs,
                processSelection: prepared.processSelection, sourceRoles: prepared.sourceRoleInventory, limits: prepared.limits)
            let actual = STASourceEvidence(executionInputIdentity: prepared.executionInputIdentity,
                configurationDigest: prepared.configurationDigest, roles: prepared.sourceRoleInventory,
                coverage: replay.sourceCoverage, samples: replay.sourceSamples, pulseWidthSamples: replay.pulseWidthSamples, staticStateSamples: replay.staticStateSamples,
                normalPowerSamples:replay.normalPowerSamples,normalPowerOwners:replay.normalPowerOwners)
            var replayPayload = replay.payload
            replayPayload.effectiveConfiguration = prepared.effectiveConfiguration; replayPayload.sourceEvidence = actual
            try prepared.sourceResources.chargeWork(replayPayload.setupApplicabilityValidationWork())
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
                throw TimingError.invalidInput(try Self.boundedReplayMismatch(observed: result.payload,
                    actual: replayPayload, resources: prepared.sourceResources))
            }
            try Task.checkCancellation(); try prepared.sourceResources.check()
        } catch is CancellationError { throw .cancelled }
        catch { throw .underlying(error) }
    }

    private func characterization(_ request: STARequest, inputs: STATimingProcessInputs) throws -> [STACharacterizationObservation] {
        let bindings = request.characterizationBindings
        guard Set(bindings.map(\.cornerID)).count == bindings.count,
              bindings.allSatisfy({ request.requestedCornerIDs.contains($0.cornerID) && !$0.conditionName.isEmpty
                  && ($0.requiredNumericProcess?.isFinite ?? true) }) else {
            throw STAPreparationError.characterization("Invalid or duplicate explicit condition binding")
        }
        if request.characterizationPolicy == .declaredCornerSelection, !bindings.isEmpty {
            throw STAPreparationError.characterization("Declared selection cannot claim observed condition bindings")
        }
        var observations: [STACharacterizationObservation] = []
        for corner in inputs.selection.corners {
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
                observations.append(.init(cornerID: corner.cornerID, source: reference, conditionName: condition.name,
                    numericProcess: condition.process, voltage: condition.voltage, temperatureCelsius: condition.temperature,
                    selected: request.characterizationPolicy == .requireObservedConditions && condition.name == binding?.conditionName))
            }
        }
        return observations
    }

    private struct LoadedInputs: Sendable {
        let design: TimingDesign
        let processInputs: STATimingProcessInputs
        let constraints: [String: TimingConstraintSet]
        let parasitics: TimingParasitics?
        let cornerIDs: [String]
        let modeIDs: [String]
    }

    private func loadInputs(_ request: STARequest, resources: STAExecutionResources) async throws -> LoadedInputs {
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

    private func validateCanonicalInputs(_ inputs: LoadedInputs) throws {
        let validator = TimingCanonicalValidator()
        for modeID in inputs.modeIDs {
            guard let constraints = inputs.constraints[modeID] else {
                throw TimingError.invariantViolation(
                    "The parsed STA mode is missing its canonical constraint set."
                )
            }
            for cornerID in inputs.cornerIDs {
                guard let library = inputs.processInputs.librariesByCorner[cornerID] else {
                    throw TimingError.invariantViolation("The admitted STA corner has no library.")
                }
                let report = validator.validate(
                    design: inputs.design,
                    constraints: constraints,
                    libraries: [library],
                    parasitics: inputs.parasitics
                )
                guard report.isValid else {
                    throw TimingError.invalidInput(
                        "Canonical STA validation failed for corner '\(cornerID)': "
                            + report.findings.map(\.code).sorted().joined(separator: ", ")
                    )
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
        limits: STAExecutionLimits
    ) throws -> AnalysisResult {
        var endpoints: [STAEndpoint] = []
        var unconstrainedEndpoints: [STAEndpoint] = []
        var paths: [STAPath] = []
        var violations: [STAViolation] = []
        var diagnostics: [DesignDiagnostic] = []
        let stateBudget = NativeSTAStateBudget(maximum: request.distributedRC == nil && !request.requireStrictSourceEvidence ? Int.max : limits.maximumPathStates)
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
                throw TimingError.invalidInput("No constraints were parsed for mode '\(modeID)'.")
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
                let scenarioRoles = Array(sourceRoles[start..<roleOffset])
                let scenario = try analyzeScenario(
                    request: request,
                    design: design,
                    library: library, source: source, clockCharacterization: clockCharacterization[cornerID], sourceResources: sourceResources,
                    constraints: constraint,
                    parasitics: parasitics, parasiticSource: parasiticSource,
                    modeID: modeID,
                    cornerID: cornerID, sourceRoles: scenarioRoles, limits: limits, stateBudget: stateBudget, work: &pathWork, rcSteps: &rcSteps
                )
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
                    sourceCoverage.append(.init(role: entry.role + start, disposition: entry.disposition, witness: entry.witness))
                }
                for sample in scenario.sourceSamples {
                    sourceSamples.append(.init(role: sample.role + start, context: sample.context,
                        inputEdge: sample.inputEdge, outputEdge: sample.outputEdge, inputPoint: sample.inputPoint,
                        receiver: sample.receiver, observation: sample.observation, appliedScale: sample.appliedScale,
                        sequentialCoordinate: sample.sequentialCoordinate, rangeObservation: sample.rangeObservation))
                }
                for sample in scenario.pulseWidthSamples {
                    pulseWidthSamples.append(.init(role: sample.role + start, context: sample.context, observation: sample.observation,
                        rangeObservation: sample.rangeObservation, rootSource: sample.rootSource, openingSlew: sample.openingSlew,
                        openingSegments: sample.openingSegments, closingSegments: sample.closingSegments,
                        openingArrival: sample.openingArrival, closingArrival: sample.closingArrival,
                        openingRootEdge: sample.openingRootEdge, closingRootEdge: sample.closingRootEdge,
                        openingRootPhase: sample.openingRootPhase, closingRootPhase: sample.closingRootPhase,
                        closingCycleOffset: sample.closingCycleOffset, period: sample.period, uncertainty: sample.uncertainty))
                }
                for sample in scenario.staticStateSamples {
                    staticStateSamples.append(.init(role: sample.role + start, clear: sample.clear, preset: sample.preset,
                        effect: sample.effect, inputConstants: sample.inputConstants, powerConstants: sample.powerConstants,
                        outputConstants: sample.outputConstants))
                }
                for sample in scenario.normalPowerSamples {
                    normalPowerSamples.append(.init(role:sample.role + start,observation:sample.observation))
                }
                normalPowerOwners.append(contentsOf:scenario.normalPowerOwners)
                clockObservations.append(contentsOf: scenario.clockObservations)
                wireCoverage.append(contentsOf: scenario.wireCoverage)
                wireObservations.append(contentsOf: scenario.wireObservations)
                conservativeWireObservations.append(contentsOf: scenario.conservativeWireObservations)
                endpoints.append(contentsOf: scenario.endpoints)
                unconstrainedEndpoints.append(contentsOf: scenario.unconstrainedEndpoints)
                paths.append(contentsOf: scenario.paths)
                violations.append(contentsOf: scenario.violations)
            }
        }

        if parasitics == nil {
            diagnostics.append(DesignDiagnostic(
                severity: .warning,
                code: "timing.sta.post_layout_inputs_missing",
                message: "STA ran without parasitics, so post-layout timing effects were not analyzed.",
                suggestedActions: ["provide_spef_artifact", "run_pex_before_signoff"]
            ))
        }
        if let parasitics {
            if request.conservativeCoupledRC != nil {
                diagnostics.append(.init(severity: .information, code: "timing.sta.certified_coupled_boundary",
                    message: "Conservative bounds cover all admitted normalized bounded-operating source histories in the NLDM prescribed-boundary model under its retained load abstraction; this does not qualify the load approximation, physical current drive or CCS behavior.",
                    suggestedActions: ["inspect_conservative_wire_observations", "review_retained_load_model"]))
            } else if request.distributedRC == nil {
                diagnostics.append(contentsOf: parasitics.evidence.diagnostics(prefix: "timing.sta"))
            } else {
                diagnostics.append(.init(severity: .information, code: "timing.sta.prescribed_ramp_distributed_rc",
                    message: "Distributed passive RC response uses characterized-slew prescribed linear drivers; crossing differences are observed grid convergence, not physical error certification.",
                    suggestedActions: ["review_prescribed_driver_assumption", "inspect_wire_observations"]))
            }
        }
        let provenance = provenance(for: request)
        if !provenance.hasCoreDigests || provenance.libraryDigests.isEmpty {
            diagnostics.append(DesignDiagnostic(
                severity: .warning,
                code: "timing.sta.incomplete_timing_provenance",
                message: "The timing verdict is missing one or more immutable input digests.",
                suggestedActions: ["record_design_digest", "record_library_digest", "record_constraint_digest", "record_pdk_digest"]
            ))
        }
        for violation in violations {
            let code = "timing.sta.\(violation.kind.rawValue)_violation"
            diagnostics.append(DesignDiagnostic(
                severity: .error,
                code: code,
                message: "\(violation.kind.rawValue) slack is \(format(violation.slack)) at \(violation.endpoint) in mode \(violation.modeID), corner \(violation.cornerID).",
                entity: violation.endpoint,
                suggestedActions: violation.suggestedActions
            ))
        }
        let worstSetup = endpoints.compactMap(\.setupSlack).min()
        let worstHold = endpoints.compactMap(\.holdSlack).min()
        let payload = STAPayload(
            worstSetupSlack: worstSetup,
            worstHoldSlack: worstHold,
            analyzedCorners: cornerIDs,
            analyzedModes: modeIDs,
            endpoints: endpoints,
            unconstrainedEndpoints: unconstrainedEndpoints,
            criticalPaths: Array(paths.sorted { $0.slack < $1.slack }.prefix(request.maxPaths)),
            violations: violations,
            repairCandidates: violations.map { violation in
                STARepairCandidate(
                    kind: violation.kind == .hold ? .addHoldBuffer : .upsizeCell,
                    endpoint: violation.endpoint,
                    modeID: violation.modeID,
                    cornerID: violation.cornerID,
                    rationale: "The reported \(violation.kind.rawValue) slack is negative.",
                    expectedImpact: violation.kind == .hold ? "Increase minimum data-path delay." : "Reduce late data-path delay."
                )
            },
            parasiticReduction: parasitics?.evidence,
            wireObservations: wireObservations, conservativeWireObservations: conservativeWireObservations, wireCoverage: wireCoverage, clockObservations: clockObservations,
            provenance: provenance,
            processSelection: processSelection
        )
        guard roleOffset == sourceRoles.count else { throw TimingError.invariantViolation("Unconsumed strict source scenario roles") }
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

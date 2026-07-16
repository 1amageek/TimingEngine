import Foundation
import CircuiteFoundation
import LogicIR
import PDKCore
import TimingCore

public struct NativeSTAEngine: STAFoundationEngine {
    public typealias Request = STAFoundationRequest
    public typealias Output = STAExecutionResult
    public let reader: any TimingArtifactReading
    public let artifactStore: (any TimingArtifactStoring)?
    public let libraryParser: any TimingLibraryParsing
    public let constraintParser: any TimingConstraintParsing
    public let designParser: any TimingDesignParsing
    public let parasiticParser: any TimingParasiticParsing

    public init(
        reader: (any TimingArtifactReading)? = nil,
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil,
        libraryParser: any TimingLibraryParsing = LibertyParser(),
        constraintParser: any TimingConstraintParsing = SDCParser(),
        designParser: any TimingDesignParsing = TimingDesignParser(),
        parasiticParser: any TimingParasiticParsing = SPEFParser()
    ) {
        self.reader = reader ?? FileSystemTimingArtifactReader(workspaceRoot: workspaceRoot)
        self.artifactStore = artifactStore
        self.libraryParser = libraryParser
        self.constraintParser = constraintParser
        self.designParser = designParser
        self.parasiticParser = parasiticParser
    }

    public func execute(_ request: STAFoundationRequest) async throws -> STAExecutionResult {
        let startedAt = Date()
        do {
            guard request.variation.isValid else {
                throw TimingError.invalidInput("STA variation derates must be finite and positive.")
            }
            let inputs = try await loadInputs(request)
            let provenanceIssues = LogicDesignProvenanceValidation.issues(
                for: logicDesignReference(for: request),
                requireProvenance: request.requiresPostLayoutInputs
            )
            guard provenanceIssues.isEmpty else {
                return try provenanceBlockedEnvelope(
                    request: request,
                    startedAt: startedAt,
                    issues: provenanceIssues
                )
            }
            let result = try analyze(
                request: request,
                design: inputs.design,
                library: inputs.library,
                constraints: inputs.constraints,
                parasitics: inputs.parasitics,
                cornerIDs: inputs.cornerIDs,
                modeIDs: inputs.modeIDs
            )
            var artifacts: [ArtifactReference] = []
            if let artifactStore {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let reportData = try encoder.encode(result.payload)
                let artifact = try await artifactStore.store(
                    reportData,
                    artifactID: try ArtifactID(rawValue: "timing-sta-report"),
                    runID: request.runID,
                    kind: .report,
                    format: .json,
                    producer: nil
                )
                artifacts.append(artifact)
            }
            let completedAt = Date()
            return STAExecutionResult(
                runID: request.runID,
                status: result.status,
                payload: result.payload,
                artifacts: artifacts,
                diagnostics: result.diagnostics,
                provenance: try makeProvenance(startedAt: startedAt, completedAt: completedAt, inputs: request.inputs),
                schemaVersion: STAFoundationRequest.currentSchemaVersion
            )
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
            return STAExecutionResult(
                runID: request.runID,
                status: .failed,
                payload: emptyPayload(request: request),
                diagnostics: [diagnostic],
                provenance: try makeProvenance(startedAt: startedAt, completedAt: completedAt, inputs: request.inputs),
                schemaVersion: STAFoundationRequest.currentSchemaVersion
            )
        }
    }

    private struct LoadedInputs: Sendable {
        let design: TimingDesign
        let library: TimingLibrary
        let constraints: [String: TimingConstraintSet]
        let parasitics: TimingParasitics?
        let cornerIDs: [String]
        let modeIDs: [String]
    }

    private func loadInputs(_ request: STAFoundationRequest) async throws -> LoadedInputs {
        guard !request.libraries.isEmpty else { throw TimingError.missingArtifact(role: "timing-library") }
        let designData = try await reader.read(request.design)
        let design = try designParser.parse(designData, topDesignName: request.topDesignName)

        var library: TimingLibrary?
        var cornerIDs: [String] = []
        for reference in request.libraries {
            let data = try await reader.read(reference.artifact)
            let parsed = try libraryParser.parse(data)
            library = library.map { $0.merged(with: parsed) } ?? parsed
            cornerIDs.append(contentsOf: reference.cornerIDs)
        }
        guard let library else { throw TimingError.missingArtifact(role: "timing-library") }
        cornerIDs = unique(cornerIDs.isEmpty ? ["default"] : cornerIDs)
        if !request.requestedCornerIDs.isEmpty {
            cornerIDs = request.requestedCornerIDs
        }

        _ = try await reader.read(request.pdkManifest)
        let constraintData = try await reader.read(request.constraints)
        let modeIDs = unique(
            request.requestedModeIDs.isEmpty
                ? ["default"]
                : request.requestedModeIDs
        )
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
            library: library,
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
    }

    private func analyze(
        request: STAFoundationRequest,
        design: TimingDesign,
        library: TimingLibrary,
        constraints: [String: TimingConstraintSet],
        parasitics: TimingParasitics?,
        cornerIDs: [String],
        modeIDs: [String]
    ) throws -> AnalysisResult {
        var endpoints: [STAEndpoint] = []
        var paths: [STAPath] = []
        var violations: [STAViolation] = []
        var diagnostics: [DesignDiagnostic] = []

        for modeID in modeIDs {
            guard let constraint = constraints[modeID] else {
                throw TimingError.invalidInput("No constraints were parsed for mode '\(modeID)'.")
            }
            for cornerID in cornerIDs {
                let scenario = try analyzeScenario(
                    request: request,
                    design: design,
                    library: library,
                    constraints: constraint,
                    parasitics: parasitics,
                    modeID: modeID,
                    cornerID: cornerID
                )
                endpoints.append(contentsOf: scenario.endpoints)
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
            provenance: provenance
        )
        return AnalysisResult(status: .completed, diagnostics: diagnostics, payload: payload)
    }

    private struct ScenarioResult: Sendable {
        let endpoints: [STAEndpoint]
        let paths: [STAPath]
        let violations: [STAViolation]
    }

    private struct EdgePair: Sendable {
        var rise: Double
        var fall: Double

        func value(for edge: TimingEdge) -> Double {
            switch edge {
            case .rise: return rise
            case .fall: return fall
            }
        }

        mutating func set(_ value: Double, for edge: TimingEdge) {
            switch edge {
            case .rise: rise = value
            case .fall: fall = value
            }
        }
    }

    private struct Predecessor: Sendable {
        let instanceIndex: Int
        let inputPin: String
        let inputNet: String
        let inputEdge: TimingEdge
        let delay: Double
        let outputSlew: Double
        let load: Double
    }

    private func analyzeScenario(
        request: STAFoundationRequest,
        design: TimingDesign,
        library: TimingLibrary,
        constraints: TimingConstraintSet,
        parasitics: TimingParasitics?,
        modeID: String,
        cornerID: String
    ) throws -> ScenarioResult {
        let cells = try Dictionary(uniqueKeysWithValues: design.instances.map { instance in
            (instance.name, try library.cell(named: instance.cell))
        })
        let sequential = design.instances.enumerated().compactMap { index, instance -> (Int, TimingDesign.Instance, TimingCell, TimingSequentialModel)? in
            guard let cell = cells[instance.name], let model = cell.sequentialModel else { return nil }
            return (index, instance, cell, model)
        }
        let sequentialIndices = Set(sequential.map(\.0))
        let primaryInputNets = Set(design.ports.filter { $0.direction == .input || $0.direction == .bidirectional }.map(\.name))
        var sourceNets = primaryInputNets
        var netLoad: [String: Double] = [:]
        for (index, instance) in design.instances.enumerated() {
            guard let cell = cells[instance.name] else { continue }
            for pin in cell.inputPins {
                if let net = instance.connections[pin.name] {
                    netLoad[net, default: 0] += pin.capacitance
                }
            }
            if let model = cell.sequentialModel, let q = instance.connections[model.outputPin] {
                sourceNets.insert(q)
            }
            _ = index
        }
        for net in design.nets { netLoad[net.name, default: 0] += net.capacitance }
        if let parasitics {
            for network in parasitics.networks {
                netLoad[network.name, default: 0] += network.totalCapacitance
            }
        }

        var lateArrival: [String: EdgePair] = [:]
        var earlyArrival: [String: EdgePair] = [:]
        var lateSlew: [String: EdgePair] = [:]
        var launchDelay: [String: Double] = [:]
        var predecessors: [String: [TimingEdge: Predecessor]] = [:]

        for port in design.ports where port.direction == .input || port.direction == .bidirectional {
            let inputDelay = constraints.inputDelays.first { $0.port == port.name && $0.isMax }
            let arrival = inputDelay.map { max($0.rise, $0.fall) } ?? 0
            let slew = constraints.defaultInputSlew
            lateArrival[port.name] = EdgePair(rise: arrival, fall: arrival)
            earlyArrival[port.name] = EdgePair(rise: arrival, fall: arrival)
            lateSlew[port.name] = EdgePair(rise: slew, fall: slew)
            launchDelay[port.name] = 0
        }

        for (_, instance, timingCell, model) in sequential {
            guard let qNet = instance.connections[model.outputPin],
                  let clockNet = instance.connections[model.clockPin],
                  let clock = constraints.clock(for: clockNet) ?? constraints.clock(named: clockNet) else {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "sequential instance without a resolvable clock")
            }
            guard let clockToQ = model.clockToQ ?? timingCell.arcs.first(where: { $0.fromPin == model.clockPin && $0.toPin == model.outputPin }) else {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing clock-to-Q arc for \(instance.cell)")
            }
            let clockSlew = 0.0
            var arrival = EdgePair(rise: 0, fall: 0)
            var early = EdgePair(rise: 0, fall: 0)
            var slew = EdgePair(rise: clockSlew, fall: clockSlew)
            for edge in [TimingEdge.rise, .fall] {
                let delay = clockToQ.delay(for: edge).lookup(inputSlew: clockSlew, outputLoad: netLoad[qNet] ?? constraints.defaultOutputLoad)
                let transition = clockToQ.transition(for: edge).lookup(inputSlew: clockSlew, outputLoad: netLoad[qNet] ?? constraints.defaultOutputLoad)
                arrival.set(delay * request.variation.lateCellDelayScale, for: edge)
                early.set(delay * request.variation.earlyCellDelayScale, for: edge)
                slew.set(transition * request.variation.lateCellDelayScale, for: edge)
            }
            lateArrival[qNet] = arrival
            earlyArrival[qNet] = early
            lateSlew[qNet] = slew
            launchDelay[qNet] = max(arrival.rise, arrival.fall)
            _ = clock
        }

        let order = try topologicalOrder(
            design: design,
            cells: cells,
            sequentialIndices: sequentialIndices,
            sources: sourceNets
        )
        for (index, instance) in order {
            guard let cell = cells[instance.name] else { continue }
            for outputPin in cell.outputPins {
                guard let outputNet = instance.connections[outputPin.name] else { continue }
                var latest = EdgePair(rise: -.infinity, fall: -.infinity)
                var earliest = EdgePair(rise: .infinity, fall: .infinity)
                var slew = EdgePair(rise: 0, fall: 0)
                var localPredecessors: [TimingEdge: Predecessor] = [:]
                for inputPin in cell.inputPins {
                    guard let inputNet = instance.connections[inputPin.name],
                          let inputLate = lateArrival[inputNet],
                          let inputEarly = earlyArrival[inputNet],
                          let inputSlew = lateSlew[inputNet] else { continue }
                    let arcs = cell.arcs(from: inputPin.name, to: outputPin.name)
                    for arc in arcs {
                        for outputEdge in [TimingEdge.rise, .fall] {
                            let inputEdges: [TimingEdge] = arc.sense.inputEdge(for: outputEdge).map { [$0] } ?? [.rise, .fall]
                            for inputEdge in inputEdges {
                                let inputSlewValue = inputSlew.value(for: inputEdge)
                                let delay = arc.delay(for: outputEdge).lookup(
                                    inputSlew: inputSlewValue,
                                    outputLoad: netLoad[outputNet] ?? constraints.defaultOutputLoad
                                )
                                let lateCandidate = inputLate.value(for: inputEdge)
                                    + delay * request.variation.lateCellDelayScale * request.variation.lateInterconnectDelayScale
                                if lateCandidate > latest.value(for: outputEdge) {
                                    latest.set(lateCandidate, for: outputEdge)
                                    let transition = arc.transition(for: outputEdge).lookup(
                                        inputSlew: inputSlewValue,
                                        outputLoad: netLoad[outputNet] ?? constraints.defaultOutputLoad
                                    )
                                    slew.set(transition, for: outputEdge)
                                    localPredecessors[outputEdge] = Predecessor(
                                        instanceIndex: index,
                                        inputPin: inputPin.name,
                                        inputNet: inputNet,
                                        inputEdge: inputEdge,
                                        delay: delay,
                                        outputSlew: transition,
                                        load: netLoad[outputNet] ?? constraints.defaultOutputLoad
                                    )
                                }
                                let earlyCandidate = inputEarly.value(for: inputEdge)
                                    + delay * request.variation.earlyCellDelayScale * request.variation.earlyInterconnectDelayScale
                                if earlyCandidate < earliest.value(for: outputEdge) {
                                    earliest.set(earlyCandidate, for: outputEdge)
                                }
                            }
                        }
                    }
                }
                guard latest.rise.isFinite || latest.fall.isFinite else { continue }
                lateArrival[outputNet] = latest
                earlyArrival[outputNet] = earliest
                lateSlew[outputNet] = slew
                predecessors[outputNet] = localPredecessors
            }
        }

        var endpoints: [STAEndpoint] = []
        var paths: [STAPath] = []
        var violations: [STAViolation] = []
        for (_, instance, _, model) in sequential {
            guard let dataNet = instance.connections[model.dataPin],
                  let late = lateArrival[dataNet],
                  let early = earlyArrival[dataNet],
                  let clockNet = instance.connections[model.clockPin],
                  let clock = constraints.clock(for: clockNet) ?? constraints.clock(named: clockNet) else {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "sequential endpoint without a propagated data path")
            }
            let pathStart = chooseStartpoint(dataNet: dataNet, lateArrival: lateArrival, predecessors: predecessors)
            if isFalsePath(startpoint: pathStart, endpoint: dataNet, exceptions: constraints.exceptions) { continue }
            if isClockGroupExcluded(startpoint: pathStart, endpointClock: clock.name, constraints: constraints) { continue }
            let cycles = multicycle(for: pathStart, endpoint: dataNet, exceptions: constraints.exceptions)
            let required = clock.period * Double(cycles) - model.setupTime - clock.uncertainty
            let latest = max(late.rise, late.fall)
            let earliest = min(early.rise, early.fall)
            let setupSlack = required - latest
            let holdSlack = earliest - model.holdTime - clock.uncertainty
            var endpoint = STAEndpoint(
                modeID: modeID,
                cornerID: cornerID,
                endpoint: dataNet,
                setupSlack: request.analysisKinds.contains(.setup) ? setupSlack : nil,
                holdSlack: request.analysisKinds.contains(.hold) ? holdSlack : nil,
                dataArrival: latest,
                requiredArrival: required
            )
            if request.analysisKinds.contains(.recovery), let recovery = model.recoveryTime {
                endpoint.recoverySlack = clock.period - recovery - clock.uncertainty
            } else if request.analysisKinds.contains(.recovery) {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "recovery analysis without recovery constraint")
            }
            if request.analysisKinds.contains(.removal), let removal = model.removalTime {
                endpoint.removalSlack = clock.period - removal - clock.uncertainty
            } else if request.analysisKinds.contains(.removal) {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "removal analysis without removal constraint")
            }
            if request.analysisKinds.contains(.pulseWidth), let pulseWidth = model.minPulseWidth {
                let high = clock.waveform.count >= 2 ? clock.waveform[1] - clock.waveform[0] : clock.period / 2
                endpoint.pulseWidthSlack = high - pulseWidth - clock.uncertainty
            } else if request.analysisKinds.contains(.pulseWidth) {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "pulse-width analysis without min pulse width constraint")
            }
            endpoints.append(endpoint)
            let path = makePath(
                modeID: modeID,
                cornerID: cornerID,
                endpoint: dataNet,
                arrival: latest,
                required: required,
                lateArrival: lateArrival,
                lateSlew: lateSlew,
                predecessors: predecessors,
                design: design,
                launchDelay: launchDelay
            )
            paths.append(path)
            appendViolationIfNeeded(.setup, slack: setupSlack, endpoint: endpoint, request: request, modeID: modeID, cornerID: cornerID, violations: &violations)
            appendViolationIfNeeded(.hold, slack: holdSlack, endpoint: endpoint, request: request, modeID: modeID, cornerID: cornerID, violations: &violations)
            if let slack = endpoint.recoverySlack { appendViolationIfNeeded(.recovery, slack: slack, endpoint: endpoint, request: request, modeID: modeID, cornerID: cornerID, violations: &violations) }
            if let slack = endpoint.removalSlack { appendViolationIfNeeded(.removal, slack: slack, endpoint: endpoint, request: request, modeID: modeID, cornerID: cornerID, violations: &violations) }
            if let slack = endpoint.pulseWidthSlack { appendViolationIfNeeded(.pulseWidth, slack: slack, endpoint: endpoint, request: request, modeID: modeID, cornerID: cornerID, violations: &violations) }
        }

        for port in design.ports where port.direction == .output || port.direction == .bidirectional {
            guard let arrival = lateArrival[port.name],
                  let delay = constraints.outputDelays.first(where: { $0.port == port.name && $0.isMax }) else { continue }
            let latest = max(arrival.rise, arrival.fall)
            let externalDelay = max(delay.rise, delay.fall)
            let required = outputRequiredArrival(delay: delay, externalDelay: externalDelay, constraints: constraints)
            let slack = required - latest
            let endpoint = STAEndpoint(modeID: modeID, cornerID: cornerID, endpoint: port.name, setupSlack: slack, dataArrival: latest, requiredArrival: required)
            endpoints.append(endpoint)
            paths.append(makePath(modeID: modeID, cornerID: cornerID, endpoint: port.name, arrival: latest, required: required, lateArrival: lateArrival, lateSlew: lateSlew, predecessors: predecessors, design: design, launchDelay: launchDelay))
            appendViolationIfNeeded(.setup, slack: slack, endpoint: endpoint, request: request, modeID: modeID, cornerID: cornerID, violations: &violations)
        }
        guard !endpoints.isEmpty else {
            throw TimingError.unsupportedSemantic(format: "STA", semantic: "no constrained timing endpoints")
        }
        return ScenarioResult(endpoints: endpoints, paths: paths, violations: violations)
    }

    private func outputRequiredArrival(
        delay: TimingConstraintSet.PortDelay,
        externalDelay: Double,
        constraints: TimingConstraintSet
    ) -> Double {
        guard let clockName = delay.clock,
              let clock = constraints.clock(named: clockName) ?? constraints.clock(for: clockName) else {
            return externalDelay
        }
        return clock.period - externalDelay - clock.uncertainty
    }

    private func topologicalOrder(
        design: TimingDesign,
        cells: [String: TimingCell],
        sequentialIndices: Set<Int>,
        sources: Set<String>
    ) throws -> [(Int, TimingDesign.Instance)] {
        var available = sources
        var remaining = design.instances.enumerated().filter { !sequentialIndices.contains($0.offset) }
        var result: [(Int, TimingDesign.Instance)] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { _, instance in
                guard let cell = cells[instance.name] else { return false }
                return cell.inputPins.allSatisfy { pin in
                    guard let net = instance.connections[pin.name] else { return false }
                    return available.contains(net)
                }
            }
            guard !ready.isEmpty else {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "combinational cycle or missing driver")
            }
            for item in ready {
                result.append(item)
                if let cell = cells[item.element.name] {
                    for pin in cell.outputPins where item.element.connections[pin.name] != nil {
                        available.insert(item.element.connections[pin.name]!)
                    }
                }
            }
            let readyIndices = Set(ready.map(\.offset))
            remaining.removeAll { readyIndices.contains($0.offset) }
        }
        return result
    }

    private func makePath(
        modeID: String,
        cornerID: String,
        endpoint: String,
        arrival: Double,
        required: Double,
        lateArrival: [String: EdgePair],
        lateSlew: [String: EdgePair],
        predecessors: [String: [TimingEdge: Predecessor]],
        design: TimingDesign,
        launchDelay: [String: Double]
    ) -> STAPath {
        var edge: TimingEdge = .rise
        if let arrivalPair = lateArrival[endpoint], arrivalPair.fall > arrivalPair.rise { edge = .fall }
        var net = endpoint
        var stages: [STAPathStage] = []
        while let predecessor = predecessors[net]?[edge] {
            let instance = design.instances[predecessor.instanceIndex]
            stages.append(STAPathStage(
                instance: instance.name,
                cell: instance.cell,
                inputPin: predecessor.inputPin,
                inputNet: predecessor.inputNet,
                outputNet: net,
                inputEdge: predecessor.inputEdge,
                outputEdge: edge,
                delay: predecessor.delay,
                outputSlew: predecessor.outputSlew,
                load: predecessor.load
            ))
            net = predecessor.inputNet
            edge = predecessor.inputEdge
        }
        stages.reverse()
        return STAPath(
            modeID: modeID,
            cornerID: cornerID,
            startpoint: net,
            endpoint: endpoint,
            arrival: arrival,
            required: required,
            slack: required - arrival,
            stages: stages
        )
    }

    private func chooseStartpoint(
        dataNet: String,
        lateArrival: [String: EdgePair],
        predecessors: [String: [TimingEdge: Predecessor]]
    ) -> String {
        var net = dataNet
        var edge: TimingEdge = .rise
        if let pair = lateArrival[dataNet], pair.fall > pair.rise { edge = .fall }
        while let predecessor = predecessors[net]?[edge] {
            net = predecessor.inputNet
            edge = predecessor.inputEdge
        }
        return net
    }

    private func appendViolationIfNeeded(
        _ kind: STAAnalysisKind,
        slack: Double,
        endpoint: STAEndpoint,
        request: STAFoundationRequest,
        modeID: String,
        cornerID: String,
        violations: inout [STAViolation]
    ) {
        guard request.analysisKinds.contains(kind), slack < 0 else { return }
        violations.append(STAViolation(
            kind: kind,
            modeID: modeID,
            cornerID: cornerID,
            endpoint: endpoint.endpoint,
            slack: slack,
            suggestedActions: kind == .setup
                ? ["reduce_logic_depth", "upsize_critical_cell", "review_clock_period"]
                : ["check_clock_skew", "add_hold_buffer", "review_minimum_delay"]
        ))
    }

    private func isFalsePath(startpoint: String, endpoint: String, exceptions: [TimingConstraintSet.PathException]) -> Bool {
        exceptions.contains { exception in
            exception.kind == .falsePath && matches(startpoint, patterns: exception.from) && matches(endpoint, patterns: exception.to)
        }
    }

    private func multicycle(for startpoint: String, endpoint: String, exceptions: [TimingConstraintSet.PathException]) -> Int {
        exceptions.first {
            $0.kind == .multicycle && matches(startpoint, patterns: $0.from) && matches(endpoint, patterns: $0.to)
        }?.cycles ?? 1
    }

    private func isClockGroupExcluded(
        startpoint: String,
        endpointClock: String,
        constraints: TimingConstraintSet
    ) -> Bool {
        guard let startClock = constraints.inputDelays.first(where: { $0.port == startpoint })?.clock else { return false }
        return constraints.clockGroups.contains { group in
            guard group.kind == .asynchronous || group.kind == .logicallyExclusive || group.kind == .physicallyExclusive else { return false }
            let startGroup = group.groups.firstIndex { $0.contains(startClock) }
            let endpointGroup = group.groups.firstIndex { $0.contains(endpointClock) }
            return startGroup != nil && endpointGroup != nil && startGroup != endpointGroup
        }
    }

    private func matches(_ value: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        return patterns.contains { pattern in
            if pattern == "*" { return true }
            if pattern.contains("*") {
                let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
                return value.hasPrefix(parts.first ?? "") && value.hasSuffix(parts.last ?? "")
            }
            return pattern == value
        }
    }

    private func blockedEnvelope(
        request: STAFoundationRequest,
        startedAt: Date,
        error: TimingError
    ) throws -> STAExecutionResult {
        STAExecutionResult(
            runID: request.runID,
            status: .blocked,
            payload: emptyPayload(request: request),
            diagnostics: [DesignDiagnostic(
                severity: .error,
                code: diagnosticCode(for: error),
                message: error.localizedDescription,
                suggestedActions: ["inspect_input_artifacts", "check_supported_semantics"]
            )],
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: STAFoundationRequest.currentSchemaVersion
        )
    }

    private func provenanceBlockedEnvelope(
        request: STAFoundationRequest,
        startedAt: Date,
        issues: [LogicDesignProvenanceValidation.Issue]
    ) throws -> STAExecutionResult {
        STAExecutionResult(
            runID: request.runID,
            status: .blocked,
            payload: emptyPayload(request: request),
            diagnostics: issues.map { issue in
                DesignDiagnostic(
                    severity: .error,
                    code: issue.diagnosticCode,
                    message: issue.message,
                    suggestedActions: ["repair_design_provenance", "recreate_design_handoff"]
                )
            },
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: STAFoundationRequest.currentSchemaVersion
        )
    }

    private func failedEnvelope(
        request: STAFoundationRequest,
        startedAt: Date,
        error: TimingError
    ) throws -> STAExecutionResult {
        STAExecutionResult(
            runID: request.runID,
            status: .failed,
            payload: emptyPayload(request: request),
            diagnostics: [DesignDiagnostic(
                severity: .error,
                code: "timing.sta.artifact_write_failed",
                message: error.localizedDescription,
                suggestedActions: ["inspect_output_directory", "retry_with_writable_artifact_store"]
            )],
            provenance: try makeProvenance(startedAt: startedAt, completedAt: Date(), inputs: request.inputs),
            schemaVersion: STAFoundationRequest.currentSchemaVersion
        )
    }

    private func emptyPayload(request: STAFoundationRequest) -> STAPayload {
        STAPayload(
            worstSetupSlack: nil,
            worstHoldSlack: nil,
            analyzedCorners: request.requestedCornerIDs,
            analyzedModes: request.requestedModeIDs,
            provenance: provenance(for: request)
        )
    }

    private func provenance(for request: STAFoundationRequest) -> TimingArtifactProvenance {
        TimingArtifactProvenance(
            designDigest: request.designRevision?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
            libraryDigests: request.libraries.map { $0.artifact.digest.hexadecimalValue },
            constraintDigest: request.constraints.digest.hexadecimalValue,
            pdkDigest: request.pdkDigest?.hexadecimalValue ?? request.pdkManifest.digest.hexadecimalValue,
            parasiticsDigest: request.parasitics?.digest.hexadecimalValue
        )
    }

    private func logicDesignReference(for request: STAFoundationRequest) -> LogicDesignReference {
        LogicDesignReference(
            artifact: request.design.locator,
            topDesignName: request.topDesignName,
            designDigest: request.designRevision?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
            provenance: LogicDesignProvenance(
                sourceDesignDigest: request.designRevision?.hexadecimalValue ?? request.design.digest.hexadecimalValue,
                inputDesignDigest: request.design.digest.hexadecimalValue,
                producerID: "timing.foundation",
                producerVersion: "1",
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
                version: "1.1.0"
            ),
            inputs: inputs,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func diagnosticCode(for error: TimingError) -> String {
        switch error {
        case .unsupportedSemantic: return "timing.sta.sta_unsupported_semantic"
        case .missingArtifact: return "timing.sta.missing_artifact"
        case .artifactDigestMismatch: return "timing.sta.artifact_digest_mismatch"
        case .artifactSizeMismatch: return "timing.sta.artifact_size_mismatch"
        case .artifactReadFailed: return "timing.sta.artifact_read_failed"
        case .parseFailure: return "timing.sta.parse_failed"
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

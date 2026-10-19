import LogicIR
import TimingCore

/// One run owns all route records. Only bounded selected reports materialize stage arrays.
internal struct NativeSTAPathAnalysis: ~Copyable {
    private struct Launch {
        let name: String
        let clock: TimingConstraintSet.Clock?
        let objects: Set<TimingPathObject>
        let clockEvent: NativeSTAClockEvent?
        let measuredLate: Bool
        let measuredEarly: Bool
        let rootPhase: Double
        var controlPulseSource: String? = nil
        var controlRootEdge: TimingEdge? = nil
    }
    private struct Step {
        let instance: Int
        let inputPin: String
        let outputPin: String
        let inputNet: Int
        let lateDelay: Double
        let earlyDelay: Double
        let load: Double
        let lateWireDelay: Double
        let earlyWireDelay: Double
        let inputSlew: Double
    }
    private struct Point {
        let net: Int
        let launch: Int
        let parent: Int?
        let step: Step?
        let edge: TimingEdge
        let late: Double
        let early: Double
        let lateSlew: Double
        let earlySlew: Double
    }
    private struct Rule {
        let fact: TimingConstraintSet.PathException
        let from: Set<TimingPathObject>
        let to: Set<TimingPathObject>
        let through: [Set<TimingPathObject>]
    }
    private struct Candidate {
        let point: Int
        let endpoint: String
        let kind: STAAnalysisKind
        let arrival: Double
        let required: Double
        let slew: Double
        var conservative: Bool = false
        var slack: Double {
            let value = kind == .setup ? required - arrival : arrival - required
            return conservative ? value.nextDown : value
        }
    }
    private let design: TimingDesign
    private let constraints: TimingConstraintSet
    private let request: STARequest
    private let limits: STAExecutionLimits
    private let stateBudget: NativeSTAStateBudget
    private let mode: String
    private let corner: String
    private let cells: [TimingCell]
    private let sourceResources: (any LibertySourceResourceAccounting)?
    private let clockCharacterization: CharacterizedTimingLibrary?
    private let source: OwnedLibertySource
    private let netNames: [String]
    private let netIndices: [String: Int]
    private var netPoints: [[Int]]
    private var points: [Point]
    private var launches: [Launch]
    private var rules: [Rule]
    private var work: UInt64
    private var candidates: [Candidate]
    private var propagatedClocks: NativeSTAClockPropagation?
    private var distributedRC: NativeSTADistributedRC?
    private var conservativeWires: NativeSTAConservativeWires?
    private var initialRCSteps: UInt64
    private var pinDelimiter: String
    private var sourceEvidence: NativeSTASourceEvidence?
    private var sequentialPlans: [Int: NativeSTASequentialExecution.Plan]
    private var controlPulses: NativeSTAControlPulsePropagation?
    private var staticStates: [Int: NativeSTASequentialExecution.StaticControls]


    init(request: STARequest, design: TimingDesign, library: TimingLibrary, source: OwnedLibertySource, constraints: TimingConstraintSet,
         clockCharacterization: CharacterizedTimingLibrary? = nil, sourceResources: (any LibertySourceResourceAccounting)? = nil, stateBudget: NativeSTAStateBudget? = nil, sourceRoles: [STASourceEvidence.Role] = [], limits: STAExecutionLimits, mode: String, corner: String, initialWork: UInt64 = 0, initialRCSteps: UInt64 = 0) throws {
        let actualBudget = stateBudget ?? NativeSTAStateBudget(maximum: request.distributedRC == nil && !request.requireStrictSourceEvidence ? Int.max : limits.maximumPathStates)
        let actualCells = try design.instances.map { try library.cell(named: $0.cell) }
        let actualNets = Array(Set(design.nets.map(\.name) + design.ports.map(\.netName))).sorted()
        try actualBudget.reserve(actualNets.count)
        var actualWork = initialWork
        var actualEvidence: NativeSTASourceEvidence? = nil
        var actualPlans: [Int: NativeSTASequentialExecution.Plan] = [:]
        if request.requireStrictSourceEvidence {
            guard clockCharacterization != nil, !sourceRoles.isEmpty else {
                throw TimingCharacterizationError.missingSourceFact("complete strict scenario role inventory")
            }
            actualEvidence = try NativeSTASourceEvidence(roles: sourceRoles, design: design,
                analysisKinds: request.analysisKinds, stateBudget: actualBudget, limits: limits, work: &actualWork)
        }
        for index in actualCells.indices {
            guard let model = actualCells[index].sequentialModel else { continue }
            if request.requireStrictSourceEvidence, case .legacy = model.definition {
                throw TimingCharacterizationError.missingSourceFact("source-qualified sequential definition")
            }
            let original = source.cells.first { $0.name == actualCells[index].name }
            let plan = try NativeSTASequentialExecution.compile(model: model, source: original, work: &actualWork,
                limits: limits, stateBudget: actualBudget, sourceResources: sourceResources)
            try actualBudget.reserve(1)
            actualPlans[index] = plan
            try actualEvidence?.mark(instance: design.instances[index].name, kind: .sequentialDefinition,
                disposition: .sourceFact, witness: "compiled exact sequential source and physical bindings",
                limits: limits, work: &actualWork)
        }
        let hasLatch = actualPlans.values.contains { $0.kind == .latch }
        let hasFF = actualPlans.values.contains { $0.kind != .latch }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Mixed FF/latch phase scheduling is not admitted.
        // Native PathAnalysis must refuse mixed state timing until actual phase interaction and cycle accounting are implemented and tested.
        guard !hasLatch || !hasFF else {
            throw TimingError.unsupportedSemantic(format: "STA", semantic: "mixed FF and latch timing profile")
        }
        self.sourceResources = sourceResources
        self.stateBudget = actualBudget
        self.clockCharacterization = clockCharacterization
        self.initialRCSteps = initialRCSteps
        self.request = request; self.design = design; self.constraints = constraints
        self.source = source
        self.limits = limits; self.mode = mode; self.corner = corner
        self.cells = actualCells
        self.netNames = actualNets
        self.netIndices = Dictionary(uniqueKeysWithValues: actualNets.enumerated().map { ($0.element, $0.offset) })
        self.netPoints = Array(repeating: [], count: actualNets.count)
        self.work = actualWork
        self.sourceEvidence = consume actualEvidence
        self.sequentialPlans = actualPlans
        self.points = []; self.launches = []; self.rules = []; self.candidates = []
        self.propagatedClocks = nil; self.distributedRC = nil; self.conservativeWires = nil; self.pinDelimiter = ":"
        self.controlPulses = nil; self.staticStates = [:]
    }

    private mutating func propagation(instance: Int, arc: TimingArc, edge: TimingEdge, inputEdge: TimingEdge,
                                      slew: Double, slewBounds: ClosedRange<Double>? = nil, load: Double, context: STASourceEvidence.Sample.Context,
                                      inputPoint: Int?, receiver: String) throws -> (delay: Double, slew: Double) {
        try charge()
        let earlyScale = request.conservativeCoupledRC == nil ? request.variation.earlyCellDelayScale : min(request.variation.earlyCellDelayScale, request.variation.lateCellDelayScale)
        let lateScale = request.conservativeCoupledRC == nil ? request.variation.lateCellDelayScale : max(request.variation.earlyCellDelayScale, request.variation.lateCellDelayScale)
        let scale = context == .late ? lateScale : earlyScale
        if request.requireStrictSourceEvidence {
            guard let characterized = clockCharacterization else {
                throw TimingCharacterizationError.missingSourceFact("strict actual propagation owner")
            }
            let range = try request.conservativeCoupledRC.map { _ in
                try characterized.evaluatePropagation(cell: cells[instance].name, fromPin: arc.fromPin, toPin: arc.toPin,
                    edge: edge, inputSlew: slewBounds ?? (slew...slew), outputLoad: load...load)
            }
            let observed = try characterized.evaluatePropagation(cell: cells[instance].name,
                fromPin: arc.fromPin, toPin: arc.toPin, edge: edge, inputSlew: slew, outputLoad: load)
            _ = try sourceEvidence!.record(observed.delay, instance: design.instances[instance].name,
                context: context, inputEdge: inputEdge, outputEdge: edge, inputPoint: inputPoint, receiver: receiver,
                scale: scale, rangeObservation: range?.delay, stateBudget: stateBudget, limits: limits, work: &work)
            _ = try sourceEvidence!.record(observed.outputSlew, instance: design.instances[instance].name,
                context: context, inputEdge: inputEdge, outputEdge: edge, inputPoint: inputPoint, receiver: receiver,
                scale: 1, rangeObservation: range?.outputSlew, stateBudget: stateBudget, limits: limits, work: &work)
            if let range {
                let delay = try NativeSTATimingBounds.scale(range.delay.result, by: scale)
                return (context == .late ? delay.upperBound : delay.lowerBound,
                        context == .late ? range.outputSlew.result.upperBound : range.outputSlew.result.lowerBound)
            }
            return (observed.delay.result * scale, observed.outputSlew.result)
        }
        return (arc.delay(for: edge).lookup(inputSlew: slew, outputLoad: load) * scale,
                arc.transition(for: edge).lookup(inputSlew: slew, outputLoad: load))
    }

    private mutating func constraint(_ check: TimingCheckArc, instance: String, slew: Double, relatedSlew: Double,
                                     slewBounds: ClosedRange<Double>? = nil, relatedBounds: ClosedRange<Double>? = nil,
                                     context: STASourceEvidence.Sample.Context, inputPoint: Int?) throws -> Double {
        try charge()
        guard request.requireStrictSourceEvidence else { return try check.value(constrainedSlew: slew, relatedSlew: relatedSlew) }
        guard let characterized = clockCharacterization,
              let index = design.instances.firstIndex(where: { $0.name == instance }),
              let plan = sequentialPlans[index], check.relatedPin == plan.clockPin else {
            throw TimingCharacterizationError.missingSourceFact("strict actual check owner")
        }
        let range = try request.conservativeCoupledRC.map { _ in
            try characterized.evaluateCheck(cell: design.instances[index].cell, kind: check.kind,
                constrainedPin: check.constrainedPin, relatedPin: check.relatedPin,
                constrainedEdge: check.constrainedEdge, relatedEdge: check.relatedEdge,
                constrainedSlew: slewBounds ?? (slew...slew), relatedSlew: relatedBounds ?? (relatedSlew...relatedSlew))
        }
        let observed = try characterized.evaluateCheck(cell: design.instances[index].cell, kind: check.kind,
            constrainedPin: check.constrainedPin, relatedPin: check.relatedPin,
            constrainedEdge: check.constrainedEdge, relatedEdge: check.relatedEdge,
            constrainedSlew: slew, relatedSlew: relatedSlew)
        _ = try sourceEvidence!.record(observed, instance: instance, context: context,
            inputEdge: check.constrainedEdge, outputEdge: check.relatedEdge, inputPoint: inputPoint,
            receiver: instance + pinDelimiter + check.constrainedPin, scale: 1,
            checkKind: check.kind, relatedEdge: check.relatedEdge, rangeObservation: range,
            stateBudget: stateBudget, limits: limits, work: &work)
        return range?.result.upperBound ?? observed.result
    }

    private mutating func completeTransfer(_ request: NativeSTASequentialExecution.TransferRequest,
                                          instance: Int, seed: Bool) throws -> NativeSTASequentialExecution.TimedOutput {
        guard let characterized = clockCharacterization,
              !request.earlyCandidates.isEmpty, !request.lateCandidates.isEmpty,
              request.earlyCandidates.count <= 2, request.lateCandidates.count <= 2 else {
            throw TimingCharacterizationError.missingSourceFact("bounded actual sequential propagation owner")
        }
        let count = request.earlyCandidates.count + request.lateCandidates.count
        try charge(UInt64(count) * 3); try stateBudget.reserve(count * 3)
        var earlySamples: [TimingSourcePropagationSample] = [], lateSamples: [TimingSourcePropagationSample] = []
        var earlyIndices: [Int] = [], lateIndices: [Int] = []
        var earlyRanges: [TimingSourcePropagationRangeSample] = [], lateRanges: [TimingSourcePropagationRangeSample] = []
        for (context, candidates) in [(STASourceEvidence.Sample.Context.early, request.earlyCandidates),
                                      (.late, request.lateCandidates)] {
            for wanted in candidates {
                try charge()
                let range = try self.request.conservativeCoupledRC.map { _ in
                    try characterized.evaluatePropagation(cell: request.cell, fromPin: wanted.pin,
                        toPin: request.output, edge: wanted.outputEdge,
                        inputSlew: wanted.inputSlewBounds ?? (wanted.inputSlew...wanted.inputSlew),
                        outputLoad: wanted.outputLoad...wanted.outputLoad)
                }
                let observed = try characterized.evaluatePropagation(cell: request.cell, fromPin: wanted.pin,
                    toPin: request.output, edge: wanted.outputEdge,
                    inputSlew: wanted.inputSlew, outputLoad: wanted.outputLoad)
                let branch: STASourceEvidence.SequentialCoordinate.Branch
                switch wanted.branch {
                case .data: branch = .data
                case .gate: branch = .gate
                case .clock: branch = .clock
                }
                let meaning: STASourceEvidence.SequentialCoordinate.Meaning
                switch wanted.coordinateMeaning {
                case .attained: meaning = .attained
                case .infimum: meaning = .infimum
                case .supremum: meaning = .supremum
                }
                let coordinate = STASourceEvidence.SequentialCoordinate(pin: wanted.pin, branch: branch, meaning: meaning,
                    selectedInputCoordinate: wanted.selectedInputCoordinate,
                    causalEarly: request.causalInput.early, causalLate: request.causalInput.late,
                    releaseTime: wanted.releaseTime, waiting: wanted.waiting, borrowedTime: wanted.borrowedTime,
                    cycle: wanted.cycle, windowOpen: wanted.windowOpen, windowClose: wanted.windowClose)
                let earlyScale = self.request.conservativeCoupledRC == nil ? self.request.variation.earlyCellDelayScale : min(self.request.variation.earlyCellDelayScale, self.request.variation.lateCellDelayScale)
                let lateScale = self.request.conservativeCoupledRC == nil ? self.request.variation.lateCellDelayScale : max(self.request.variation.earlyCellDelayScale, self.request.variation.lateCellDelayScale)
                let scale = context == .early ? earlyScale : lateScale
                let receiver = design.instances[instance].name + pinDelimiter + wanted.pin
                let index = try sourceEvidence!.record(observed.delay, instance: design.instances[instance].name,
                    context: context, inputEdge: wanted.inputEdge, outputEdge: wanted.outputEdge,
                    inputPoint: seed ? nil : wanted.parentRouteIndex, receiver: receiver,
                    scale: scale, sequentialCoordinate: coordinate, rangeObservation: range?.delay, stateBudget: stateBudget, limits: limits, work: &work)
                _ = try sourceEvidence!.record(observed.outputSlew, instance: design.instances[instance].name,
                    context: context, inputEdge: wanted.inputEdge, outputEdge: wanted.outputEdge,
                    inputPoint: seed ? nil : wanted.parentRouteIndex, receiver: receiver,
                    scale: 1, sequentialCoordinate: coordinate, rangeObservation: range?.outputSlew, stateBudget: stateBudget, limits: limits, work: &work)
                if context == .early {
                    earlySamples.append(observed); earlyIndices.append(index)
                    if let range { earlyRanges.append(range) }
                } else {
                    lateSamples.append(observed); lateIndices.append(index)
                    if let range { lateRanges.append(range) }
                }
            }
        }
        return try NativeSTASequentialExecution.complete(request, earlySamples: earlySamples, lateSamples: lateSamples,
            earlyReceiptIndices: earlyIndices, lateReceiptIndices: lateIndices, characterized: characterized,
            earlyRanges: earlyRanges, lateRanges: lateRanges,
            earlyCellScale: self.request.conservativeCoupledRC == nil ? self.request.variation.earlyCellDelayScale : min(self.request.variation.earlyCellDelayScale, self.request.variation.lateCellDelayScale),
            lateCellScale: self.request.conservativeCoupledRC == nil ? self.request.variation.lateCellDelayScale : max(self.request.variation.earlyCellDelayScale, self.request.variation.lateCellDelayScale),
            work: &work, limits: limits, stateBudget: stateBudget, sourceResources: sourceResources)
    }

    private func clockBoundary(instance: String, clock: TimingConstraintSet.Clock, edge: TimingEdge)
        -> NativeSTASequentialExecution.Boundary {
        if let received = receivingClock(instance: instance, edge: edge) {
            return .init(edge: edge, early: received.early, late: received.late,
                earlySlew: received.earlySlew, lateSlew: received.lateSlew)
        }
        let phase = clock.waveform.count == 2 ? clock.waveform[edge == .rise ? 0 : 1]
            : (edge == .rise ? 0 : clock.period / 2)
        return .init(edge: edge, early: phase, late: phase,
            earlySlew: request.conservativeCoupledRC == nil ? constraints.defaultInputSlew
                : (edge == .rise ? clock.sourceRiseTransition : clock.sourceFallTransition) ?? constraints.defaultInputSlew,
            lateSlew: request.conservativeCoupledRC == nil ? constraints.defaultInputSlew
                : (edge == .rise ? clock.sourceRiseTransition : clock.sourceFallTransition) ?? constraints.defaultInputSlew)
    }

    private func sourcePhase(_ clock: TimingConstraintSet.Clock) -> Double {
        (clock.isPropagated || request.requireStrictSourceEvidence) && clock.waveform.count == 2 ? clock.waveform[0] : 0
    }

    private mutating func transferLatch(instance: Int, plan: NativeSTASequentialExecution.Plan, loads: [Double]) throws {
        guard request.requireStrictSourceEvidence, let closingEdge = plan.closeEdge,
              let clockNet = design.instances[instance].connections[plan.clockPin], let clock = clock(on: clockNet) else {
            throw TimingError.unsupportedSemantic(format: "STA", semantic: "latch requires exact strict source clock/window evidence")
        }
        let name = design.instances[instance].name
        let opening = clockBoundary(instance: name, clock: clock, edge: plan.activeEdge)
        let closing = clockBoundary(instance: name, clock: clock, edge: closingEdge)
        let shift = closing.early <= opening.late ? clock.period : 0
        let window = NativeSTASequentialExecution.Window(open: opening,
            close: .init(edge: closingEdge,
                early: try request.conservativeCoupledRC == nil ? closing.early + shift : NativeSTATimingBounds.add(closing.early, shift, upper: false),
                late: try request.conservativeCoupledRC == nil ? closing.late + shift : NativeSTATimingBounds.add(closing.late, shift, upper: true),
                earlySlew: closing.earlySlew, lateSlew: closing.lateSlew), period: clock.period)
        for output in plan.outputs {
            guard let net = design.instances[instance].connections[output.pin], let outputNet = netIndices[net] else { continue }
            for pin in plan.dataPins {
                guard let input = design.instances[instance].connections[pin], let inputNet = netIndices[input] else {
                    throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing exact latch data binding")
                }
                guard !netPoints[inputNet].isEmpty else {
                    throw TimingError.unsupportedSemantic(format: "STA", semantic: "latch data has no measured transition")
                }
                for parent in netPoints[inputNet] {
                    let point = try received(parent, sink: name + pinDelimiter + pin)
                    let dataArcs = cells[instance].arcs(from: pin, to: output.pin).filter { !$0.isConstraint }
                    guard dataArcs.count == 1 else { throw TimingCharacterizationError.missingSourceFact("unique latch data arc") }
                    for edge in [TimingEdge.rise, .fall] where dataArcs[0].sense.inputEdge(for: edge).map({ $0 == point.edge }) ?? true {
                        let transfer = try NativeSTASequentialExecution.requestLatch(plan: plan, cell: cells[instance],
                            output: output.pin, outputEdge: edge,
                            input: .init(pin: pin, edge: point.edge, early: point.early, late: point.late,
                                earlySlew: point.earlySlew, lateSlew: point.lateSlew, parentRouteIndex: parent),
                            window: window, outputLoad: loads[outputNet], certified: request.conservativeCoupledRC != nil, work: &work, limits: limits,
                            stateBudget: stateBudget, sourceResources: sourceResources)
                        let timed = try completeTransfer(transfer, instance: instance, seed: false)
                        try append(.init(net: outputNet, launch: point.launch, parent: parent,
                            step: .init(instance: instance, inputPin: pin, outputPin: output.pin, inputNet: inputNet,
                                lateDelay: timed.late.appliedDelay, earlyDelay: timed.early.appliedDelay, load: loads[outputNet],
                                lateWireDelay: point.late - points[parent].late, earlyWireDelay: point.early - points[parent].early,
                                inputSlew: point.lateSlew), edge: edge,
                            late: timed.late.arrival, early: timed.early.arrival,
                            lateSlew: timed.late.outputSlew, earlySlew: timed.early.outputSlew))
                    }
                }
                try sourceEvidence?.mark(instance: name, kind: .propagation, pin: output.pin, relatedPin: pin,
                    disposition: .excluded, witness: "exact causal intervals do not intersect the transparent data branch",
                    limits: limits, work: &work)
            }
            try sourceEvidence?.mark(instance: name, kind: .propagation, pin: output.pin, relatedPin: plan.clockPin,
                disposition: .excluded, witness: "exact causal intervals do not intersect the gate-release branch",
                limits: limits, work: &work)
        }
    }
    private mutating func charge(_ amount: UInt64 = 1) throws {
        try sourceResources?.check()
        let next = work.addingReportingOverflow(amount)
        guard !next.overflow, next.partialValue <= limits.maximumPathWorkUnits else {
            throw STAPathAnalysisError.capacity(resource: "path work", limit: limits.maximumPathWorkUnits)
        }
        let previous = work; work = next.partialValue
        if previous / 256 != work / 256 { try Task.checkCancellation() }
    }
    private mutating func append(_ point: Point) throws {
        try charge()
        guard points.count < limits.maximumPathStates else {
            throw STAPathAnalysisError.capacity(resource: "path states", limit: UInt64(limits.maximumPathStates))
        }
        guard [point.late, point.early, point.lateSlew, point.earlySlew].allSatisfy(\.isFinite) else {
            throw TimingError.invalidInput("Nonfinite path propagation")
        }
        try stateBudget.reserve(2)
        netPoints[point.net].append(points.count); points.append(point)
    }
    private mutating func received(_ index: Int, sink: String) throws -> Point {
        let point = points[index]
        let launch = launches[point.launch]
        if let source = launch.controlPulseSource,
           let wave = controlPulses?.receiver(net: netNames[point.net], sink: sink) {
            let event = wave.event(point.edge)
            guard wave.source.sourcePort == source, event.rootEdge == launch.controlRootEdge,
                  event.rootPhase == launch.rootPhase else {
                throw TimingError.invariantViolation("Control route lost its exact periodic root event")
            }
            return .init(net: point.net, launch: point.launch, parent: point.parent, step: point.step, edge: point.edge,
                late: event.late, early: event.early, lateSlew: event.lateSlew, earlySlew: event.earlySlew)
        }
        if conservativeWires != nil {
            let result = try conservativeWires!.response(net: netNames[point.net], sink: sink, edge: point.edge,
                sourceSlew: NativeSTATimingBounds.slew(point.earlySlew, point.lateSlew), work: &work)
            let delay = try NativeSTATimingBounds.derated(result.delay, early: request.variation.earlyInterconnectDelayScale,
                late: request.variation.lateInterconnectDelayScale)
            return .init(net: point.net, launch: point.launch, parent: point.parent, step: point.step, edge: point.edge,
                late: try NativeSTATimingBounds.add(point.late, delay.upperBound, upper: true),
                early: try NativeSTATimingBounds.add(point.early, delay.lowerBound, upper: false),
                lateSlew: result.slew.upperBound, earlySlew: result.slew.lowerBound)
        }
        guard distributedRC != nil else { return point }
        let late = try distributedRC!.response(net: netNames[point.net], sink: sink,
            sourceSlew: point.lateSlew, edge: point.edge, work: &work)
        let early = try distributedRC!.response(net: netNames[point.net], sink: sink,
            sourceSlew: point.earlySlew, edge: point.edge, work: &work)
        return .init(net: point.net, launch: point.launch, parent: point.parent, step: point.step, edge: point.edge,
            late: point.late + late.delay * request.variation.lateInterconnectDelayScale,
            early: point.early + early.delay * request.variation.earlyInterconnectDelayScale,
            lateSlew: late.slew, earlySlew: early.slew)
    }
    private func clock(on net: String) -> TimingConstraintSet.Clock? {
        if let clock = propagatedClocks?.nets[net]?.rise.clock { return clock }
        for port in design.ports where port.netName == net {
            if let clock = constraints.clock(for: port.name) { return clock }
        }
        return nil
    }
    private func receivingClock(instance: String?, edge: TimingEdge) -> NativeSTAClockEvent? {
        instance.flatMap { propagatedClocks?.leaves[$0]?.event(edge) }
    }
    private mutating func commonClockCorrection(_ launch: NativeSTAClockEvent?, _ capture: NativeSTAClockEvent?) throws -> Double {
        if request.conservativeCoupledRC != nil { return 0 }
        guard let launch, let capture, launch.clock.name == capture.clock.name,
              launch.rootEdge == capture.rootEdge, launch.rootPhase == capture.rootPhase else { return 0 }
        var correction = 0.0
        for (a, b) in zip(launch.segments, capture.segments) {
            try charge()
            guard a.physicalIdentity == b.physicalIdentity, a.lateDelay == b.lateDelay, a.earlyDelay == b.earlyDelay else { break }
            correction += a.lateDelay - a.earlyDelay
        }
        guard correction.isFinite else { throw TimingError.invalidInput("Nonfinite common clock correction") }
        return correction
    }
    private func captureCycleOffset(_ kind: STAAnalysisKind, launch: Launch, capture: NativeSTAClockEvent?, idealPhase: Double? = nil, period: Double? = nil) -> Double {
        if capture == nil, request.requireStrictSourceEvidence, let phase = idealPhase, let period {
            if kind == .setup || kind == .recovery { return phase <= launch.rootPhase ? period : 0 }
            return phase > launch.rootPhase ? -period : 0
        }
        guard let capture else { return kind == .setup || kind == .recovery ? (period ?? launch.clock?.period ?? 0) : 0 }
        let launchPhase = launch.clockEvent?.rootPhase ?? launch.rootPhase
        if kind == .setup || kind == .recovery { return capture.rootPhase <= launchPhase ? capture.clock.period : 0 }
        return capture.rootPhase > launchPhase ? -capture.clock.period : 0
    }
    private mutating func glob(_ pattern: String, _ name: String) throws -> Bool {
        let p = Array(pattern); let n = Array(name)
        var i = 0; var j = 0; var star: Int?; var retry = 0
        while j < n.count {
            try charge()
            if i < p.count && (p[i] == "?" || p[i] == n[j]) { i += 1; j += 1 }
            else if i < p.count && p[i] == "*" { star = i; i += 1; retry = j }
            else if let star { retry += 1; j = retry; i = star + 1 }
            else { return false }
        }
        while i < p.count && p[i] == "*" { i += 1 }
        return i == p.count
    }
    private mutating func compileRules() throws {
        for port in design.ports {
            let input = constraints.inputDelays.filter { $0.port == port.name }
            let output = constraints.outputDelays.filter { $0.port == port.name }
            try charge(UInt64(input.count + output.count + 1))
            guard input.filter(\.isMax).count <= 1, input.filter({ !$0.isMax }).count <= 1,
                  output.filter(\.isMax).count <= 1, output.filter({ !$0.isMax }).count <= 1,
                  Set(input.map(\.clock)).count <= 1 else {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "multiple I/O clock references for " + port.name)
            }
        }
        let ports = design.ports.map { TimingPathObject(kind: .port, pattern: $0.name) }
        let clocks = (constraints.clocks.map(\.name) + constraints.generatedClocks.map(\.name))
            .map { TimingPathObject(kind: .clock, pattern: $0) }
        var sources = ports.filter { object in design.ports.contains { $0.name == object.pattern && $0.direction != .output } } + clocks
        var sinks = ports.filter { object in design.ports.contains { $0.name == object.pattern && $0.direction != .input } } + clocks
        var through = netNames.map { TimingPathObject(kind: .net, pattern: $0) }
        for i in design.instances.indices {
            let name = design.instances[i].name
            if let plan = sequentialPlans[i] {
                sources += plan.outputs.map { .init(kind: .pin, pattern: name + "/" + $0.pin) }
                sources.append(.init(kind: .instance, pattern: name))
                sinks += plan.dataPins.map { .init(kind: .pin, pattern: name + "/" + $0) }
                sinks.append(.init(kind: .instance, pattern: name))
            }
            through.append(.init(kind: .instance, pattern: name))
            through += cells[i].pins.map { .init(kind: .pin, pattern: name + "/" + $0.name) }
        }
        func invalid(_ pattern: TimingPathObject) -> TimingError {
            .invalidInput("Unmatched or unsupported path selector: " + pattern.kind.rawValue + " " + pattern.pattern)
        }
        for fact in constraints.exceptions {
            var groups: [Set<TimingPathObject>] = []
            for (patterns, inventory) in [(fact.from, sources), (fact.to, sinks)] + fact.through.map({ ($0, through) }) {
                var selected = Set<TimingPathObject>()
                for pattern in patterns {
                    try charge()
                    guard !pattern.pattern.isEmpty else { throw invalid(pattern) }
                    var matches: [TimingPathObject] = []
                    for object in inventory where pattern.kind == .name || pattern.kind == object.kind {
                        if try glob(pattern.pattern, object.pattern) { matches.append(object) }
                    }
                    guard !matches.isEmpty else { throw invalid(pattern) }
                    if pattern.kind == .name && Set(matches.map(\.kind)).count > 1 {
                        throw TimingError.invalidInput("Ambiguous untyped path selector: " + pattern.pattern)
                    }
                    selected.formUnion(matches)
                }
                groups.append(selected)
            }
            rules.append(.init(fact: fact, from: groups[0], to: groups[1], through: Array(groups.dropFirst(2))))
        }
    }
    private mutating func matches(_ rule: Rule, point: Int, endpoint: Set<TimingPathObject>) throws -> Bool {
        try charge()
        if !rule.from.isEmpty && rule.from.isDisjoint(with: launches[points[point].launch].objects) { return false }
        if !rule.to.isEmpty && rule.to.isDisjoint(with: endpoint) { return false }
        guard !rule.through.isEmpty else { return true }
        var stage = rule.through.count - 1
        // Walk the predecessor chain backwards; each physical visit consumes at most one stage.
        func visit(_ object: TimingPathObject, also other: TimingPathObject? = nil) {
            if stage >= 0 && (rule.through[stage].contains(object) || other.map({ rule.through[stage].contains($0) }) == true) { stage -= 1 }
        }
        for object in endpoint.sorted(by: { $0.pattern < $1.pattern }) where object.kind == .pin { visit(object) }
        var cursor: Int? = point
        while let index = cursor, stage >= 0 {
            try charge()
            let value = points[index]
            visit(.init(kind: .net, pattern: netNames[value.net]))
            if let step = value.step {
                let name = design.instances[step.instance].name
                let instance = TimingPathObject(kind: .instance, pattern: name)
                visit(.init(kind: .pin, pattern: name + "/" + step.outputPin), also: instance)
                visit(.init(kind: .pin, pattern: name + "/" + step.inputPin), also: instance)
            } else {
                if let pin = launches[value.launch].objects.first(where: { $0.kind == .pin }) {
                    visit(pin, also: launches[value.launch].objects.first { $0.kind == .instance })
                }
            }
            cursor = value.parent
        }
        return stage < 0
    }
    private func applies(_ fact: TimingConstraintSet.PathException, _ kind: STAAnalysisKind) -> Bool {
        if fact.kind == .maxDelay { return kind == .setup }
        if fact.kind == .minDelay { return kind == .hold }
        return fact.scope == .both || (kind == .setup ? fact.scope == .setup : fact.scope == .hold)
    }
    private func select(_ matches: [TimingConstraintSet.PathException], kind: TimingConstraintSet.PathException.Kind,
                        check: STAAnalysisKind) throws -> TimingConstraintSet.PathException? {
        var values = matches.filter { $0.kind == kind && applies($0, check) }
        if kind == .multicycle && values.contains(where: { $0.scope != .both }) { values.removeAll { $0.scope == .both } }
        guard let selected = values.first else { return nil }
        guard values.allSatisfy({ $0.cycles == selected.cycles && $0.delay == selected.delay && $0.clockReference == selected.clockReference }) else {
            throw TimingError.invalidInput("Conflicting path exceptions on one route")
        }
        return selected
    }
    private func period(_ fact: TimingConstraintSet.PathException, launch: Launch,
                        capture: TimingConstraintSet.Clock?) throws -> Double {
        guard let capture else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "multicycle without a capture clock") }
        return fact.clockReference == .start ? (launch.clock ?? capture).period : capture.period
    }
    private mutating func sequentialChecks(_ model: TimingSequentialModel, kind: STAAnalysisKind,
        point: Point, instance: String?, constrainedPin: String, pointIndex: Int,
        capture: TimingConstraintSet.Clock?) throws -> [(value: Double, phase: Double, clock: NativeSTAClockEvent?)] {
        guard let checks = model.timingChecks else {
            guard !request.requireStrictSourceEvidence else { throw TimingCharacterizationError.missingSourceFact("source sequential constraint") }
            let value = kind == .setup ? model.setupTime : model.holdTime
            guard value.isFinite else { throw TimingError.invalidInput("Nonfinite scalar sequential constraint") }
            return [(value, model.clockEdge == .fall ? (capture?.period ?? 0) / 2 : 0, receivingClock(instance: instance, edge: model.clockEdge ?? .rise))]
        }
        var values: [(Double, Double, NativeSTAClockEvent?)] = []
        for check in checks {
            try charge()
            guard check.kind.rawValue == kind.rawValue, check.constrainedPin == constrainedPin, check.constrainedEdge == point.edge else { continue }
            let clock = receivingClock(instance: instance, edge: check.relatedEdge)
            let boundary = request.conservativeCoupledRC == nil ? nil : capture.map {
                clockBoundary(instance: instance!, clock: $0, edge: check.relatedEdge)
            }
            let value = try constraint(check, instance: instance!, slew: kind == .setup ? point.lateSlew : point.earlySlew,
                relatedSlew: boundary.map { kind == .setup ? $0.earlySlew : $0.lateSlew }
                    ?? clock.map { kind == .setup ? $0.earlySlew : $0.lateSlew } ?? constraints.defaultInputSlew,
                slewBounds: NativeSTATimingBounds.slew(point.earlySlew, point.lateSlew),
                relatedBounds: boundary.map { NativeSTATimingBounds.slew($0.earlySlew, $0.lateSlew) }
                    ?? clock.map { NativeSTATimingBounds.slew($0.earlySlew, $0.lateSlew) },
                context: kind == .setup ? .late : .early, inputPoint: pointIndex)
            let phase = capture.map { clockBoundary(instance: instance!, clock: $0, edge: check.relatedEdge).early } ?? 0
            values.append((value, phase, clock))
        }
        guard !values.isEmpty else {
            throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing source-bound " + kind.rawValue + " constraint for " + constrainedPin + " " + point.edge.rawValue)
        }
        return values
    }

    private mutating func controlSlack(model: TimingSequentialModel, instance: String,
                                      capture: TimingConstraintSet.Clock, kind: STAAnalysisKind, constrainedPin: String) throws -> Double {
        guard let checks = model.timingChecks, let cell = design.instances.first(where: { $0.name == instance }) else {
            throw TimingError.unsupportedSemantic(format: "STA", semantic: "control check without source-bound pin/edge")
        }
        guard request.requireStrictSourceEvidence || capture.isPropagated || capture.waveform.isEmpty || capture.waveform == [0, capture.period / 2] else {
            throw TimingError.unsupportedSemantic(format: "STA", semantic: "nondefault control clock phase")
        }
        var worst: Double?
        var matched = false
        for check in checks where check.kind.rawValue == kind.rawValue && check.constrainedPin == constrainedPin {
            try charge(); matched = true
            guard let name = cell.connections[check.constrainedPin], let net = netIndices[name],
                  !netPoints[net].isEmpty else {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing control transition: " + check.constrainedPin)
            }
            var measured = false
            for index in netPoints[net] where points[index].edge == check.constrainedEdge {
                try charge()
                let point = try received(index, sink: cell.name + pinDelimiter + check.constrainedPin); let launch = launches[point.launch]
                guard kind == .recovery ? launch.measuredLate : launch.measuredEarly,
                      let clock = launch.clock, clock.name == capture.name else {
                    throw TimingError.unsupportedSemantic(format: "STA", semantic: "unmeasured or unrelated control arrival")
                }
                let receiving = receivingClock(instance: instance, edge: check.relatedEdge)
                let boundary = clockBoundary(instance: instance, clock: capture, edge: check.relatedEdge)
                let value = try constraint(check, instance: instance, slew: kind == .recovery ? point.lateSlew : point.earlySlew,
                    relatedSlew: request.conservativeCoupledRC != nil
                        ? (kind == .recovery ? boundary.earlySlew : boundary.lateSlew)
                        : receiving.map { kind == .recovery ? $0.earlySlew : $0.lateSlew } ?? constraints.defaultInputSlew,
                    slewBounds: NativeSTATimingBounds.slew(point.earlySlew, point.lateSlew),
                    relatedBounds: request.conservativeCoupledRC != nil
                        ? NativeSTATimingBounds.slew(boundary.earlySlew, boundary.lateSlew)
                        : receiving.map { NativeSTATimingBounds.slew($0.earlySlew, $0.lateSlew) },
                    context: kind == .recovery ? .late : .early, inputPoint: index)
                let phase = boundary.early
                let correction = try commonClockCorrection(launch.clockEvent, receiving)
                var slack = kind == .recovery
                    ? captureCycleOffset(kind, launch: launch, capture: receiving, idealPhase: phase, period: capture.period) + (receiving?.early ?? phase) - point.late - value - capture.uncertainty + correction
                    : point.early - (receiving?.late ?? phase) - captureCycleOffset(kind, launch: launch, capture: receiving, idealPhase: phase, period: capture.period) - value - capture.uncertainty + correction
                if request.conservativeCoupledRC != nil {
                    let cycle = captureCycleOffset(kind, launch: launch, capture: receiving, idealPhase: phase, period: capture.period)
                    slack = try NativeSTATimingBounds.sum(kind == .recovery
                        ? [cycle, receiving?.early ?? phase, -point.late, -value, -capture.uncertainty]
                        : [point.early, -(receiving?.late ?? phase), -cycle, -value, -capture.uncertainty], upper: false)
                }
                guard slack.isFinite else { throw TimingError.invalidInput("Nonfinite control slack") }
                worst = min(worst ?? slack, slack); measured = true
            }
            guard measured else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing control edge arrival") }
        }
        guard matched, let worst else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing " + kind.rawValue + " constraint") }
        return worst
    }

    private mutating func evaluate(name: String, net: Int, capture: TimingConstraintSet.Clock?, model: TimingSequentialModel?,
                                   instance: String?, constant: TimingDesign.Constant?, physicalSink: String? = nil, constrainedPin: String? = nil) throws -> (STAEndpoint, STAEndpoint?) {
        var endpoint = STAEndpoint(modeID: mode, cornerID: corner, endpoint: name, staticValue: constant)
        var unknown: [STAAnalysisKind] = []
        var staticChecks: [STAAnalysisKind] = []; var excluded: [STAAnalysisKind] = []
        let maxIO = constraints.outputDelays.first { $0.port == name && $0.isMax }
        let minIO = constraints.outputDelays.first { $0.port == name && !$0.isMax }
        let endpointObjects: Set<TimingPathObject> = [.init(kind: model == nil ? .port : .pin, pattern: name)]
        for kind in [STAAnalysisKind.setup, .hold] where request.analysisKinds.contains(kind) {
            let io = kind == .setup ? maxIO : minIO
            let capture = model == nil ? io?.clock.flatMap { constraints.clock(named: $0) } : capture
            var objects = endpointObjects
            if let capture { objects.insert(.init(kind: .clock, pattern: capture.name)) }
            if let instance { objects.insert(.init(kind: .instance, pattern: instance)) }
            let external = io.map { kind == .setup ? max($0.rise, $0.fall) : min($0.rise, $0.fall) } ?? 0
            let setup = model?.setupTime ?? 0; let hold = model?.holdTime ?? 0
            let uncertainty = capture?.uncertainty ?? 0
            let base: Double? = model != nil
                ? (kind == .setup ? capture!.period - setup - uncertainty : hold + uncertainty)
                : io.map { _ in kind == .setup ? (capture.map { $0.period + sourcePhase($0) - external - uncertainty } ?? external)
                    : (capture.map { sourcePhase($0) } ?? 0) - external + uncertainty }
            let relevant = model != nil || base != nil || rules.contains { rule in
                applies(rule.fact, kind) && (rule.to.isEmpty || !rule.to.isDisjoint(with: objects)) }
            guard relevant || kind == .setup else { continue }
            if constant != nil {
                // No launch exists on a binary tie. Endpoint-wide exclusions are distinct from static checks.
                let excludedTie = rules.contains { $0.fact.kind == .falsePath && applies($0.fact, kind)
                    && $0.from.isEmpty && $0.through.isEmpty && ($0.to.isEmpty || !$0.to.isDisjoint(with: objects)) }
                if excludedTie { excluded.append(kind) }
                else if base != nil || rules.contains(where: { ($0.fact.kind == .maxDelay || $0.fact.kind == .minDelay) && applies($0.fact, kind) && $0.from.isEmpty && $0.through.isEmpty && ($0.to.isEmpty || !$0.to.isDisjoint(with: objects)) }) { staticChecks.append(kind) }
                else { unknown.append(kind) }
                if let instance, let constrainedPin, let sourceKind = TimingCheckArc.Kind(rawValue: kind.rawValue) {
                    if staticChecks.contains(kind) {
                        try sourceEvidence?.mark(instance: instance, kind: .sequentialCheck, pin: constrainedPin,
                            checkKind: sourceKind, disposition: constant == .one ? .staticOne : .staticZero,
                            witness: "exact binary source data has no transition for this setup/hold check", limits: limits, work: &work)
                    } else if excluded.contains(kind) {
                        try sourceEvidence?.mark(instance: instance, kind: .sequentialCheck, pin: constrainedPin,
                            checkKind: sourceKind, disposition: .excluded, witness: "exact endpoint-wide static-data exclusion",
                            limits: limits, work: &work)
                    }
                }
                continue
            }
            guard !netPoints[net].isEmpty else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "endpoint without propagated path: " + name) }
            var best: Candidate?; var eligible = 0; var missing = false
            for index in netPoints[net] {
                try charge()
                let point = try received(index, sink: physicalSink ?? name); let launch = launches[point.launch]
                var matching: [TimingConstraintSet.PathException] = []
                for rule in rules { if try matches(rule, point: index, endpoint: objects) { matching.append(rule.fact) } }
                if matching.contains(where: { $0.kind == .falsePath && applies($0, kind) }) { continue }
                if let start = launch.clock, let capture {
                    if constraints.clockGroups.contains(where: { group in
                        let a = group.groups.firstIndex { $0.contains(start.name) }; let b = group.groups.firstIndex { $0.contains(capture.name) }
                        return a != nil && b != nil && a != b
                    }) { continue }
                    guard start.period == capture.period else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "different launch/capture periods") }
                }
                for clock in [launch.clock, capture].compactMap({ $0 }) {
                    guard request.requireStrictSourceEvidence || clock.isPropagated || clock.waveform.isEmpty || clock.waveform == [0, clock.period / 2] else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "nondefault clock phase") }
                }
                eligible += 1
                if request.requireStrictSourceEvidence && !(kind == .setup ? launch.measuredLate : launch.measuredEarly) { missing = true; continue }
                let measuredChecks = try model.map { try sequentialChecks($0, kind: kind, point: point, instance: instance, constrainedPin: constrainedPin!, pointIndex: index, capture: capture) } ?? [(0, 0, nil)]
                for measurement in measuredChecks {
                    let setup = kind == .setup ? measurement.0 : 0
                    let hold = kind == .hold ? measurement.0 : 0
                    let phase = measurement.1
                    let receiving = measurement.2
                    let correction = try commonClockCorrection(launch.clockEvent, receiving)
                    var required = model != nil
                        ? (kind == .setup ? captureCycleOffset(kind, launch: launch, capture: receiving, idealPhase: phase, period: capture!.period) + (receiving?.early ?? phase) - setup - uncertainty + correction
                            : (receiving?.late ?? phase) + captureCycleOffset(kind, launch: launch, capture: receiving, idealPhase: phase, period: capture!.period) + hold + uncertainty - correction)
                        : base
                    if request.conservativeCoupledRC != nil {
                        if model != nil {
                            let cycle = captureCycleOffset(kind, launch: launch, capture: receiving, idealPhase: phase, period: capture!.period)
                            required = try kind == .setup
                                ? NativeSTATimingBounds.sum([cycle, receiving?.early ?? phase, -setup, -uncertainty], upper: false)
                                : NativeSTATimingBounds.sum([receiving?.late ?? phase, cycle, hold, uncertainty], upper: true)
                        } else if io != nil {
                            required = try kind == .setup
                                ? NativeSTATimingBounds.sum([capture?.period ?? 0, capture.map { sourcePhase($0) } ?? 0, -external, -uncertainty], upper: false)
                                : NativeSTATimingBounds.sum([capture.map { sourcePhase($0) } ?? 0, -external, uncertainty], upper: true)
                        }
                    }
                    if let delay = try select(matching, kind: kind == .setup ? .maxDelay : .minDelay, check: kind) {
                        // FIXME(INCOMPLETE_IMPLEMENTATION): Propagated-clock max/min delay reference semantics are not admitted.
                        // The production exception path must refuse until its exact launch/capture latency relationship is specified and tested.
                        guard receiving == nil && launch.clockEvent == nil else { throw TimingError.unsupportedSemantic(format: "propagated clock STA", semantic: "max/min delay override") }
                        required = try request.conservativeCoupledRC == nil
                            ? (kind == .setup ? delay.delay! - setup - external - uncertainty : delay.delay! + hold - external + uncertainty)
                            : NativeSTATimingBounds.sum(kind == .setup ? [delay.delay!, -setup, -external, -uncertainty]
                                : [delay.delay!, hold, -external, uncertainty], upper: kind != .setup)
                    } else {
                        let setupMCP = try select(matching, kind: .multicycle, check: .setup)
                        let holdMCP = try select(matching, kind: .multicycle, check: .hold)
                        var shift = 0.0
                        if let setupMCP { shift = Double(setupMCP.cycles! - 1) * (try period(setupMCP, launch: launch, capture: capture)) }
                        if kind == .hold, let holdMCP {
                            let cycles = holdMCP.scope == .both ? 0 : holdMCP.cycles!
                            shift -= Double(cycles) * (try period(holdMCP, launch: launch, capture: capture))
                        }
                        if let value = required {
                            if request.conservativeCoupledRC != nil {
                                var shiftInterval = try TimingNumericInterval(point: 0)
                                if let setupMCP {
                                    shiftInterval = try TimingNumericInterval(point: Double(setupMCP.cycles! - 1))
                                        .multiplied(by: TimingNumericInterval(point: period(setupMCP, launch: launch, capture: capture)))
                                }
                                if kind == .hold, let holdMCP {
                                    let cycles = holdMCP.scope == .both ? 0 : holdMCP.cycles!
                                    shiftInterval = try shiftInterval.subtracting(TimingNumericInterval(point: Double(cycles))
                                        .multiplied(by: TimingNumericInterval(point: period(holdMCP, launch: launch, capture: capture))))
                                }
                                let total = try TimingNumericInterval(point: value).adding(shiftInterval)
                                required = kind == .setup ? total.lowerBound : total.upperBound
                            } else { required = value + shift }
                        }
                    }
                    guard let required else { missing = true; continue }
                    guard required.isFinite else { throw TimingError.invalidInput("Nonfinite path required time") }
                    let candidate = Candidate(point: index, endpoint: name, kind: kind,
                        arrival: kind == .setup ? point.late : point.early, required: required,
                        slew: kind == .setup ? point.lateSlew : point.earlySlew,
                        conservative: request.conservativeCoupledRC != nil)
                    guard candidate.slack.isFinite else { throw TimingError.invalidInput("Nonfinite path slack") }
                    if best == nil || candidate.slack < best!.slack { best = candidate }
                }
            }
            if eligible == 0 {
                excluded.append(kind)
                if let instance, let constrainedPin, let sourceKind = TimingCheckArc.Kind(rawValue: kind.rawValue) {
                    try sourceEvidence?.mark(instance: instance, kind: .sequentialCheck, pin: constrainedPin,
                        checkKind: sourceKind, disposition: .excluded, witness: "all exact routes excluded by scenario constraints",
                        limits: limits, work: &work)
                }
            }
            else if missing { unknown.append(kind) }
            if let best {
                if kind == .setup { endpoint.setupSlack = best.slack; endpoint.dataArrival = best.arrival; endpoint.requiredArrival = best.required; endpoint.dataSlew = best.slew }
                else { endpoint.holdSlack = best.slack }
                candidates.append(best)
            }
        }
        endpoint.staticChecks = staticChecks.isEmpty ? nil : staticChecks
        endpoint.excludedChecks = excluded.isEmpty ? nil : excluded
        var unmeasured: STAEndpoint?
        if !unknown.isEmpty { unmeasured = .init(modeID: mode, cornerID: corner, endpoint: name, staticValue: constant, unconstrainedChecks: unknown) }
        return (endpoint, unmeasured)
    }
    private mutating func staticSource(for cell: TimingCell) throws -> LibertySourceCell? {
        guard cell.sequentialModel == nil, cell.inputPins.isEmpty else { return nil }
        for candidate in source.cells {
            try charge()
            guard candidate.name == cell.name else { continue }
            try charge(UInt64(candidate.pins.count) + 1)
            guard candidate.sequential.isEmpty, candidate.unsupportedFunctionalGroups.isEmpty,
                  candidate.pins.allSatisfy({ pin in
                      guard pin.direction == .output, pin.threeState == nil, pin.xFunction == nil, pin.stateFunction == nil,
                            let function = pin.function, case .normalized(let facts) = function.content else { return false }
                      return facts.symbols.isEmpty
                  }) else { return nil }
            return candidate
        }
        throw TimingError.invariantViolation("The selected timing cell lost its owned Liberty source")
    }

    private mutating func staticValue(_ pin: LibertySourcePin) throws -> TimingDesign.Constant? {
        guard pin.direction == .output, pin.threeState == nil, pin.xFunction == nil, pin.stateFunction == nil,
              let function = pin.function, case .normalized(let facts) = function.content,
              facts.symbols.isEmpty else { return nil }
        let capacity = points.count.addingReportingOverflow(facts.operations.count)
        guard !capacity.overflow, capacity.partialValue <= limits.maximumPathStates else {
            throw STAPathAnalysisError.capacity(resource: "path states including static function slots", limit: UInt64(limits.maximumPathStates))
        }
        guard !facts.operations.isEmpty, facts.operations.indices.contains(facts.output.rawValue) else {
            throw TimingError.invariantViolation("Invalid owned constant function output")
        }
        if request.distributedRC != nil || request.conservativeCoupledRC != nil { try stateBudget.reserve(facts.operations.count) }
        // This invocation owns admitted temporary slots; they never escape the source traversal.
        var values: [LogicBit] = []
        values.reserveCapacity(facts.operations.count)
        func prior(_ index: LogicBooleanNodeIndex) throws -> LogicBit {
            guard values.indices.contains(index.rawValue) else {
                throw TimingError.invariantViolation("Owned constant function edge is not a prior node")
            }
            return values[index.rawValue]
        }
        for operation in facts.operations {
            try charge()
            let value: LogicBit
            switch operation {
            case .constant(let binary): value = binary ? .one : .zero
            case .input: return nil
            case .invert(let a): value = try prior(a).inverted
            case .and(let a, let b): value = try prior(a).and(prior(b))
            case .or(let a, let b): value = try prior(a).or(prior(b))
            case .xor(let a, let b): value = try prior(a).xor(prior(b))
            }
            values.append(value)
        }
        switch values[facts.output.rawValue] {
        case .zero: return .zero
        case .one: return .one
        case .unknown, .highImpedance: return nil
        }
    }

    private mutating func resolveStaticCombinational(constants: inout [String: TimingDesign.Constant],
                                                       available: inout Set<Int>) throws {
        var changed = true
        while changed {
            changed = false
            for index in design.instances.indices where cells[index].sequentialModel == nil {
                let instance = design.instances[index]
                guard let original = source.cells.first(where: { $0.name == cells[index].name }),
                      original.unsupportedFunctionalGroups.isEmpty else { continue }
                try charge(UInt64(original.pins.count)); try stateBudget.reserve(original.pins.count)
                var inputs: [String: TimingDesign.Constant] = [:]
                for pin in original.pins where pin.direction == .input {
                    if let net = instance.connections[pin.name], let value = constants[net] { inputs[pin.name] = value }
                }
                for pin in original.pins where pin.direction == .output {
                    guard let net = instance.connections[pin.name], constants[net] == nil,
                          pin.threeState == nil, pin.xFunction == nil, pin.stateFunction == nil,
                          let function = pin.function else { continue }
                    if let value = try NativeSTASequentialExecution.constantOutput(function, inputs: inputs,
                        work: &work, limits: limits, stateBudget: stateBudget, sourceResources: sourceResources) {
                        try stateBudget.reserve(2); constants[net] = value; available.insert(netIndices[net]!)
                        changed = true
                        try sourceEvidence?.mark(instance: instance.name, kind: .pin, pin: pin.name,
                            disposition: value == .one ? .staticOne : .staticZero,
                            witness: "exact source Boolean function under proved constant input slots", limits: limits, work: &work)
                        try sourceEvidence?.mark(instance: instance.name, kind: .propagation, pin: pin.name,
                            disposition: value == .one ? .staticOne : .staticZero,
                            witness: "source output is constant under exact candidate input slots", limits: limits, work: &work)
                    }
                }
            }
        }
    }

    private mutating func evaluateStaticControls(constants: inout [String: TimingDesign.Constant],
                                                 available: inout Set<Int>) throws {
        guard request.requireStrictSourceEvidence else { return }
        for index in sequentialPlans.keys.sorted() {
            let plan = sequentialPlans[index], instance = design.instances[index]
            guard let plan else { throw TimingError.invariantViolation("Missing static state plan") }
            try charge(UInt64(plan.inputPinNames.count + request.operatingSupplyAssumptions.count))
            try stateBudget.reserve(plan.inputPinNames.count + plan.powerPinNames.count + 1)
            var inputs: [String: TimingDesign.Constant] = [:], powers: [String: TimingDesign.Constant] = [:]
            for pin in plan.inputPinNames {
                if let net = instance.connections[pin], let value = constants[net] { inputs[pin] = value }
            }
            for assumption in request.operatingSupplyAssumptions where assumption.instance == instance.name && assumption.cornerID == corner {
                powers[assumption.pin] = assumption.value
            }
            let state = try NativeSTASequentialExecution.staticControls(plan: plan, inputs: inputs, powerValues: powers,
                work: &work, limits: limits, stateBudget: stateBudget, sourceResources: sourceResources)
            staticStates[index] = state
            if state.effect == .unknown {
                // FIXME(INCOMPLETE_IMPLEMENTATION): Dynamic asynchronous Q event propagation is not admitted.
                // Strict data timing callers must fail until directional event/state scheduling is implemented and verified.
                guard !request.analysisKinds.contains(.setup) && !request.analysisKinds.contains(.hold) else {
                    throw TimingError.unsupportedSemantic(format: "strict source STA", semantic: "dynamic asynchronous output timing is not qualified")
                }
                try sourceEvidence?.mark(instance: instance.name, kind: .propagation, disposition: .unrequested,
                    witness: "check-only mode does not request asynchronous state output timing", limits: limits, work: &work)
                for output in plan.outputs { if let net = instance.connections[output.pin] { available.insert(netIndices[net]!) } }
            }
            let effect: STASourceEvidence.StaticStateSample.Effect
            switch state.effect {
            case .inactive: effect = .inactive
            case .clear: effect = .clear
            case .preset: effect = .preset
            case .unknown: effect = .unknown
            }
            try sourceEvidence?.recordStatic(instance: instance.name, effect: effect, clear: state.clear, preset: state.preset,
                inputs: inputs, powers: powers, outputs: state.outputs, stateBudget: stateBudget, limits: limits, work: &work)
            for (pin, value) in state.outputs {
                guard let net = instance.connections[pin] else { continue }
                if let prior = constants[net], prior != value { throw TimingError.invalidInput("Static reset contradicts candidate net constant") }
                try stateBudget.reserve(2); constants[net] = value; available.insert(netIndices[net]!)
                try sourceEvidence?.mark(instance: instance.name, kind: .pin, pin: pin,
                    disposition: value == .one ? .staticOne : .staticZero,
                    witness: "source clear/preset and original state output binding determine a held constant", limits: limits, work: &work)
                try sourceEvidence?.mark(instance: instance.name, kind: .propagation, pin: pin,
                    disposition: value == .one ? .staticOne : .staticZero,
                    witness: "asserted source asynchronous state action holds output; no clock-to-Q transition", limits: limits, work: &work)
            }
            for arc in cells[index].directionalControlArcs {
                let constant = instance.connections[arc.fromPin].flatMap { constants[$0] }
                if let constant {
                    try sourceEvidence?.mark(instance: instance.name, kind: .directionalControlPropagation,
                        pin: arc.toPin, relatedPin: arc.fromPin, disposition: constant == .one ? .staticOne : .staticZero,
                        witness: "exact source directional control arc has no control event under the held operating condition",
                        limits: limits, work: &work)
                } else if !request.analysisKinds.contains(.setup) && !request.analysisKinds.contains(.hold) {
                    try sourceEvidence?.mark(instance: instance.name, kind: .directionalControlPropagation,
                        pin: arc.toPin, relatedPin: arc.fromPin, disposition: .unrequested,
                        witness: "check-only execution does not request asynchronous output propagation", limits: limits, work: &work)
                }
            }
        }
    }

    private mutating func pulseEndpoints(instance index: Int, constants: [String: TimingDesign.Constant]) throws -> [String: STAEndpoint] {
        guard request.requireStrictSourceEvidence, request.analysisKinds.contains(.pulseWidth) else { return [:] }
        let instance = design.instances[index], plan = sequentialPlans[index]
        guard let characterized = clockCharacterization else { throw TimingCharacterizationError.missingSourceFact("pulse law owner") }
        var endpoints: [String: STAEndpoint] = [:]
        for law in try characterized.pulseWidthConstraints(cell: cells[index].name) {
            try charge()
            guard let identity = law.sourceIdentity, let net = instance.connections[law.pin],
                  law.relatedPin == nil || law.relatedPin == law.pin else {
                throw TimingError.unsupportedSemantic(format: "strict pulse STA", semantic: "missing pin or unsupported cross-pin pulse reference")
            }
            var endpoint = endpoints[law.pin] ?? STAEndpoint(modeID: mode, cornerID: corner, endpoint: instance.name + "/" + law.pin)
            if let value = constants[net] {
                endpoint.staticValue = value
                endpoint.notApplicableChecks = [.pulseWidth]
                try sourceEvidence?.mark(instance: instance.name, kind: .pulseWidth, pin: law.pin,
                    disposition: .staticControlNotApplicable,
                    witness: "exact candidate constant pin has no opening or closing pulse events", limits: limits, work: &work)
                endpoints[law.pin] = endpoint
                continue
            }
            let opening: NativeSTAControlPulsePropagation.Event, closing: NativeSTAControlPulsePropagation.Event
            let period: Double, uncertainty: Double, root: String
            let opposite: TimingEdge = law.openingEdge == .rise ? .fall : .rise
            if let plan, law.pin == plan.clockPin {
                guard let clock = clock(on: net),
                      let open = receivingClock(instance: instance.name, edge: law.openingEdge),
                      let close = receivingClock(instance: instance.name, edge: opposite),
                      open.clock.name == close.clock.name else {
                    throw TimingError.unsupportedSemantic(format: "strict pulse STA", semantic: "clock pulse requires both actual receiving edges")
                }
                opening = .init(edge: open.edge, rootEdge: open.rootEdge, rootPhase: open.rootPhase,
                    early: open.early, late: open.late, earlySlew: open.earlySlew, lateSlew: open.lateSlew, segments: open.segments)
                closing = .init(edge: close.edge, rootEdge: close.rootEdge, rootPhase: close.rootPhase,
                    early: close.early, late: close.late, earlySlew: close.earlySlew, lateSlew: close.lateSlew, segments: close.segments)
                period = clock.period; uncertainty = clock.uncertainty; root = clock.name
            } else {
                guard let wave = controlPulses?.receiver(net: net, sink: instance.name + pinDelimiter + law.pin),
                      let reference = constraints.clock(named: wave.source.referenceClock) else {
                    throw TimingError.unsupportedSemantic(format: "strict pulse STA", semantic: "control pulse requires an explicit propagated primary waveform")
                }
                opening = wave.event(law.openingEdge); closing = wave.event(opposite)
                period = wave.source.period; uncertainty = reference.uncertainty; root = wave.source.sourcePort
            }
            for context in [STASourceEvidence.Sample.Context.early, .late] {
                let slew = context == .early ? opening.earlySlew : opening.lateSlew
                let range = try request.conservativeCoupledRC.map { _ in
                    try characterized.evaluatePulseWidth(cell: cells[index].name, pin: law.pin,
                        openingEdge: law.openingEdge, sourceIdentity: identity,
                        inputSlew: NativeSTATimingBounds.slew(opening.earlySlew, opening.lateSlew))
                }
                let observed = try characterized.evaluatePulseWidth(cell: cells[index].name, pin: law.pin,
                    openingEdge: law.openingEdge, sourceIdentity: identity, inputSlew: slew)
                try characterized.validate(observed)
                let slack = try sourceEvidence!.recordPulse(instance: instance.name, observation: observed,
                    context: context, rootSource: root, openingSlew: slew,
                    openingSegments: opening.segments, closingSegments: closing.segments,
                    openingArrival: opening.late, closingArrival: closing.early,
                    openingRootEdge: opening.rootEdge, closingRootEdge: closing.rootEdge,
                    openingRootPhase: opening.rootPhase, closingRootPhase: closing.rootPhase,
                    period: period, uncertainty: uncertainty, rangeObservation: range, stateBudget: stateBudget, limits: limits, work: &work)
                endpoint.pulseWidthSlack = min(endpoint.pulseWidthSlack ?? slack, slack)
            }
            endpoints[law.pin] = endpoint
        }
        if cells[index].pulseWidthConstraints.isEmpty, let plan {
            endpoints[plan.clockPin] = STAEndpoint(modeID: mode, cornerID: corner,
                endpoint: instance.name + "/" + plan.clockPin, notApplicableChecks: [.pulseWidth])
        }
        return endpoints
    }

    private mutating func initialConstants() throws -> ([String: TimingDesign.Constant], Set<Int>) {
        try Task.checkCancellation(); try compileRules()
        var constants = Dictionary(uniqueKeysWithValues: design.nets.compactMap { net in net.constant.map { (net.name, $0) } })
        var available = Set(design.nets.filter { $0.constant != nil }.map { netIndices[$0.name]! })
        if request.requireStrictSourceEvidence { try resolveStaticCombinational(constants: &constants, available: &available) }
        if request.requireStrictSourceEvidence || !request.operatingSupplyAssumptions.isEmpty {
            guard let reference = request.libraries.first(where: { $0.cornerIDs.contains(corner) })?.artifact.reference else {
                throw TimingError.invariantViolation("Missing exact normal-power library binding")
            }
            let netSlots = design.nets.count.multipliedReportingOverflow(by: 2)
            let supplySlots = netSlots.partialValue.addingReportingOverflow(request.operatingSupplyAssumptions.count)
            guard !netSlots.overflow, !supplySlots.overflow else { throw TimingError.invalidInput("Normal-power workspace overflow") }
            try charge(UInt64(supplySlots.partialValue)); try stateBudget.reserve(supplySlots.partialValue)
            var consumed = Set<STAOperatingSupplyAssumption>()
            for instance in design.instances {
                try charge()
                let receipt = try NativeSTASequentialExecution.validateNormalPower(source:source,cell:instance.cell,
                    instance:instance.name,cornerID:corner,library:reference,assumptions:request.operatingSupplyAssumptions,
                    work:&work,limits:limits,stateBudget:stateBudget,sourceResources:sourceResources)
                try sourceEvidence?.recordNormalPower(instance:instance.name,checked:receipt.checked,
                    stateBudget:stateBudget,limits:limits,work:&work)
                for assumption in receipt.assumptions {
                    consumed.insert(assumption)
                    try sourceEvidence?.mark(instance: instance.name, kind: .powerPin, pin: assumption.pin,
                        disposition: assumption.value == .one ? .staticOne : .staticZero,
                        witness: "explicit caller supply condition joined to exact source PG declaration",
                        limits: limits, work: &work)
                }
            }
            guard consumed == Set(request.operatingSupplyAssumptions.filter { $0.cornerID == corner }) else {
                throw TimingError.invalidInput("Foreign or unconsumed operating supply assumptions")
            }
        }
        if request.conservativeCoupledRC != nil {
            try evaluateStaticControls(constants: &constants, available: &available)
            try resolveStaticCombinational(constants: &constants, available: &available)
        }
        return (constants, available)
    }

    private func initialLoads(parasitics: TimingLumpedParasitics?) throws -> [Double] {
        var loads = Array(repeating: 0.0, count: netNames.count)
        var knownLoads = Set<Int>()
        for i in design.instances.indices {
            for pin in cells[i].inputPins { if let net = design.instances[i].connections[pin.name] { loads[netIndices[net]!] += pin.capacitance; knownLoads.insert(netIndices[net]!) } }
        }
        for net in design.nets { loads[netIndices[net.name]!] += net.capacitance; knownLoads.insert(netIndices[net.name]!) }
        if let parasitics { for (net, load) in parasitics.effectiveLoads { if let n = netIndices[net] { loads[n] += load; knownLoads.insert(n) } } }
        for n in netNames.indices where !knownLoads.contains(n) { loads[n] = constraints.defaultOutputLoad }
        guard loads.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw TimingError.invalidInput("Invalid path load") }
        return loads
    }

    mutating func initialSourceContext(parasitics: TimingLumpedParasitics?, parasiticSource: TimingParasitics?,
        binding: STAConservativeSourceContextRecord.Binding, control: NativeSTAInitialSourceControl,
        cumulativeWork: inout UInt64) throws -> STAConservativeSourceContext {
        // Admission for the existing preparation transforms precedes their arrays/maps.
        // This is logical construction work/storage, not a whole-transform RSS claim.
        let netSlots = netNames.count.multipliedReportingOverflow(by: 8)
        guard !netSlots.overflow else { throw LibertySourceError.arithmeticOverflow }
        try stateBudget.reserve(netSlots.partialValue)
        try charge(UInt64(netSlots.partialValue))
        for instance in design.instances {
            try charge(UInt64(instance.connections.count) + 1)
        }
        for cell in cells { try charge(UInt64(cell.pins.count) + 1) }
        let (constants, _) = try initialConstants()
        let loads = try initialLoads(parasitics: parasitics)
        guard let options = request.conservativeCoupledRC, let parasiticSource,
              let characterized = clockCharacterization else {
            throw TimingError.unsupportedSemantic(format: "initial source context", semantic: "exact conservative preparation required")
        }
        var sourceLoads: [String: Double] = [:]
        try stateBudget.reserve(netNames.count)
        for index in netNames.indices { try charge(); sourceLoads[netNames[index]] = loads[index] }
        let result = try NativeSTAConservativeWires.initialContext(options: options, design: design, cells: cells,
            source: source, characterized: characterized, constraints: constraints, pulseSources: request.controlPulseSources,
            constants: constants, loads: sourceLoads, parasitics: parasiticSource, mode: mode, corner: corner,
            binding: binding, control: control, work: &work)
        cumulativeWork = work
        return result
    }

    mutating func run(parasitics: TimingLumpedParasitics?, parasiticSource: TimingParasitics? = nil) throws -> STAPathAnalysisResult {
        var (constants, available) = try initialConstants()
        if let options = request.distributedRC {
            guard let parasiticSource else { throw TimingError.unsupportedSemantic(format: "distributed RC STA", semantic: "missing exact parasitics") }
            pinDelimiter = parasiticSource.pinDelimiter
            distributedRC = try NativeSTADistributedRC(options: options, limits: limits, parasitics: parasiticSource,
                design: design, cells: cells, source: source, sourceResources: sourceResources, stateBudget: stateBudget, mode: mode, corner: corner, initialSteps: initialRCSteps, work: &work)
        }
        let loads = try initialLoads(parasitics: parasitics)
        if let options = request.conservativeCoupledRC {
            guard let parasiticSource, let characterized = clockCharacterization else {
                throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "exact parasitic/source owner required")
            }
            pinDelimiter = parasiticSource.pinDelimiter
            var conservativeLoads: [String: Double] = [:]
            for index in netNames.indices {
                try charge()
                try stateBudget.reserve(1)
                conservativeLoads[netNames[index]] = loads[index]
            }
            conservativeWires = try .init(options: options, design: design, cells: cells, source: source,
                characterized: characterized, constraints: constraints, pulseSources: request.controlPulseSources,
                constants: constants, loads: conservativeLoads,
                parasitics: parasiticSource, limits: limits, budget: stateBudget,
                resources: sourceResources, mode: mode, corner: corner, work: &work)
        }
        if distributedRC != nil || conservativeWires != nil {
            propagatedClocks = try NativeSTAClockPropagation(design: design, cells: cells, source: source, constraints: constraints,
                sequentialPlans: sequentialPlans,
                normalPowerValidated: request.requireStrictSourceEvidence || !request.operatingSupplyAssumptions.isEmpty,
                sourceEvidence: &sourceEvidence,
                loads: Dictionary(uniqueKeysWithValues: netNames.indices.map { (netNames[$0], loads[$0]) }),
                characterized: clockCharacterization, sourceResources: sourceResources, stateBudget: stateBudget, variation: request.variation, limits: limits, delimiter: pinDelimiter, mode: mode, corner: corner,
                rc: &distributedRC, conservative: &conservativeWires, work: &work)
            for clock in constraints.clocks where !clock.isPropagated {
                let net = design.ports.first { $0.name == clock.source }?.netName ?? clock.source
                if distributedRC?.contains(net) == true || conservativeWires?.contains(net) == true { throw TimingError.unsupportedSemantic(format: "distributed RC STA", semantic: "finite-R clock requires explicit propagated source") }
            }
            for i in design.instances.indices {
                if let plan = sequentialPlans[i], let net = design.instances[i].connections[plan.clockPin],
                   (distributedRC?.contains(net) == true || conservativeWires?.contains(net) == true), propagatedClocks?.leaves[design.instances[i].name] == nil {
                    throw TimingError.unsupportedSemantic(format: "distributed RC STA", semantic: "finite-R FF clock lacks propagated source")
                }
            }
        } else if constraints.clocks.contains(where: \.isPropagated) {
            throw TimingError.unsupportedSemantic(format: "STA", semantic: "propagated clock requires explicit distributed RC options")
        }
        if request.requireStrictSourceEvidence {
            if request.conservativeCoupledRC == nil {
                try evaluateStaticControls(constants: &constants, available: &available)
                try resolveStaticCombinational(constants: &constants, available: &available)
            }
            guard let characterized = clockCharacterization else { throw TimingCharacterizationError.missingSourceFact("control pulse characterization") }
            controlPulses = try NativeSTAControlPulsePropagation(design: design, cells: cells, source: source,
                plans: sequentialPlans, sources: request.controlPulseSources, constants: constants,
                loads: Dictionary(uniqueKeysWithValues: netNames.indices.map { (netNames[$0], loads[$0]) }),
                characterized: characterized, variation: request.variation, mode: mode, delimiter: pinDelimiter,
                resources: sourceResources, limits: limits, budget: stateBudget, evidence: &sourceEvidence,
                rc: &distributedRC, conservative: &conservativeWires, work: &work)
        }
        for port in design.ports where port.direction != .output {
            let n = netIndices[port.netName]!; available.insert(n)
            if constants[port.netName] != nil { continue }
            if let pulse = request.controlPulseSources.first(where: { $0.modeID == mode && $0.sourcePort == port.name }),
               let reference = constraints.clock(named: pulse.referenceClock) {
                for edge in [TimingEdge.rise, .fall] {
                    let phase = edge == .rise ? pulse.risePhase : pulse.fallPhase
                    let slew = edge == .rise ? pulse.riseTransition : pulse.fallTransition
                    try stateBudget.reserve(1)
                    launches.append(.init(name: port.name, clock: reference,
                        objects: [.init(kind: .port, pattern: port.name), .init(kind: .clock, pattern: reference.name)],
                        clockEvent: nil, measuredLate: true, measuredEarly: true, rootPhase: phase,
                        controlPulseSource: port.name, controlRootEdge: edge))
                    try append(.init(net: n, launch: launches.count - 1, parent: nil, step: nil, edge: edge,
                        late: phase, early: phase, lateSlew: slew, earlySlew: slew))
                }
                continue
            }
            let maxDelay = constraints.inputDelays.first { $0.port == port.name && $0.isMax }
            let minDelay = constraints.inputDelays.first { $0.port == port.name && !$0.isMax }
            let clock = maxDelay?.clock.flatMap { constraints.clock(named: $0) } ?? minDelay?.clock.flatMap { constraints.clock(named: $0) } ?? constraints.clock(for: port.name)
            var objects: Set<TimingPathObject> = [.init(kind: .port, pattern: port.name)]
            if let clock { objects.insert(.init(kind: .clock, pattern: clock.name)) }
            launches.append(.init(name: port.name, clock: clock, objects: objects, clockEvent: nil, measuredLate: maxDelay != nil, measuredEarly: minDelay != nil,
                rootPhase: clock.map { sourcePhase($0) } ?? 0))
            for edge in [TimingEdge.rise, .fall] {
                let phase = clock.map { sourcePhase($0) } ?? 0
                let maximum = maxDelay.map { edge == .rise ? $0.rise : $0.fall } ?? 0
                let minimum = minDelay.map { edge == .rise ? $0.rise : $0.fall } ?? 0
                var slew = constraints.defaultInputSlew
                if request.conservativeCoupledRC != nil {
                    let primaryClock = constraints.clocks.first { $0.source == port.name }
                    if let explicit = edge == .rise ? primaryClock?.sourceRiseTransition : primaryClock?.sourceFallTransition {
                        guard explicit.isFinite, explicit > 0 else { throw TimingError.invalidInput("Invalid explicit clock source slew") }
                        slew = explicit
                    } else {
                        guard case .allInputsBothEdges(let explicit)? = constraints.inputTransition,
                              explicit.isFinite, explicit > 0, explicit == constraints.defaultInputSlew else {
                            throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "Explicit primary source transition required")
                        }
                        slew = explicit
                    }
                }
                let late = try request.conservativeCoupledRC == nil ? maximum + phase : NativeSTATimingBounds.add(maximum, phase, upper: true)
                let early = try request.conservativeCoupledRC == nil ? minimum + phase : NativeSTATimingBounds.add(minimum, phase, upper: false)
                try append(.init(net: n, launch: launches.count - 1, parent: nil, step: nil, edge: edge,
                    late: late, early: early, lateSlew: slew, earlySlew: slew))
            }
        }
        for i in design.instances.indices {
            guard let model = cells[i].sequentialModel, let plan = sequentialPlans[i], plan.kind != .latch else { continue }
            let instance = design.instances[i]
            if let state = staticStates[i], state.effect != .inactive { continue }
            guard let clockNet = instance.connections[plan.clockPin], let clock = clock(on: clockNet) else {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing source sequential clock")
            }
            let receiving = receivingClock(instance: instance.name, edge: plan.activeEdge)
            let boundary = clockBoundary(instance: instance.name, clock: clock, edge: plan.activeEdge)
            for output in plan.outputs {
                guard let net = instance.connections[output.pin] else { continue }
                let arcs = cells[i].arcs(from: plan.clockPin, to: output.pin)
                guard arcs.count <= 1, let arc = arcs.first ?? (plan.kind == .legacyFlipFlop ? model.clockToQ : nil) else {
                    throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing source clock-to-Q")
                }
                let n = netIndices[net]!; available.insert(n)
                launches.append(.init(name: instance.name + "/" + output.pin, clock: clock,
                    objects: [.init(kind: .pin, pattern: instance.name + "/" + output.pin), .init(kind: .instance, pattern: instance.name), .init(kind: .clock, pattern: clock.name)],
                    clockEvent: receiving, measuredLate: true, measuredEarly: true,
                    rootPhase: receiving?.rootPhase ?? boundary.early))
                var historyRise: (arrival: ClosedRange<Double>, slew: ClosedRange<Double>)?
                var historyFall: (arrival: ClosedRange<Double>, slew: ClosedRange<Double>)?
                for edge in [TimingEdge.rise, .fall] {
                    let late: Double, early: Double, lateSlew: Double, earlySlew: Double
                    if request.requireStrictSourceEvidence {
                        let transfer = try NativeSTASequentialExecution.requestFF(plan: plan, cell: cells[i], output: output.pin,
                            outputEdge: edge, clock: .init(pin: plan.clockPin, edge: plan.activeEdge,
                                early: boundary.early, late: boundary.late, earlySlew: boundary.earlySlew,
                                lateSlew: boundary.lateSlew, parentRouteIndex: 0), outputLoad: loads[n],
                            work: &work, limits: limits, stateBudget: stateBudget, sourceResources: sourceResources)
                        let timed = try completeTransfer(transfer, instance: i, seed: true)
                        late = timed.late.arrival; early = timed.early.arrival
                        lateSlew = timed.late.outputSlew; earlySlew = timed.early.outputSlew
                    } else if receiving != nil {
                        guard let characterized = clockCharacterization else { throw TimingError.invariantViolation("Missing retained clock characterization") }
                        let lateSample = try characterized.evaluate(cell: cells[i].name, fromPin: plan.clockPin, toPin: output.pin,
                            edge: edge, inputSlew: boundary.lateSlew, outputLoad: loads[n])
                        let earlySample = try characterized.evaluate(cell: cells[i].name, fromPin: plan.clockPin, toPin: output.pin,
                            edge: edge, inputSlew: boundary.earlySlew, outputLoad: loads[n])
                        late = boundary.late + lateSample.delay * request.variation.lateCellDelayScale
                        early = boundary.early + earlySample.delay * request.variation.earlyCellDelayScale
                        lateSlew = lateSample.outputSlew; earlySlew = earlySample.outputSlew
                    } else {
                        let lateSample = try propagation(instance: i, arc: arc, edge: edge, inputEdge: plan.activeEdge,
                            slew: boundary.lateSlew, load: loads[n], context: .late, inputPoint: nil,
                            receiver: instance.name + pinDelimiter + plan.clockPin)
                        let earlySample = try propagation(instance: i, arc: arc, edge: edge, inputEdge: plan.activeEdge,
                            slew: boundary.earlySlew, load: loads[n], context: .early, inputPoint: nil,
                            receiver: instance.name + pinDelimiter + plan.clockPin)
                        late = boundary.late + lateSample.delay; early = boundary.early + earlySample.delay
                        lateSlew = lateSample.slew; earlySlew = earlySample.slew
                    }
                    if request.requireStrictSourceEvidence && conservativeWires != nil {
                        let envelope = (arrival: early...late, slew: NativeSTATimingBounds.slew(earlySlew, lateSlew))
                        if edge == .rise { historyRise = envelope } else { historyFall = envelope }
                    }
                    try append(.init(net: n, launch: launches.count - 1, parent: nil, step: nil, edge: edge,
                        late: late, early: early, lateSlew: lateSlew, earlySlew: earlySlew))
                }
                if request.requireStrictSourceEvidence, conservativeWires != nil,
                   plan.kind == .flipFlop, let declaration = plan.declaration,
                   declaration.clear == nil, declaration.preset == nil, declaration.additionalControl == nil,
                   let clockWave = propagatedClocks?.leaves[instance.name],
                   let historyRise, let historyFall {
                    guard let identity = arc.sourceIdentity else {
                        throw TimingCharacterizationError.missingSourceFact("qualified sequential history arc")
                    }
                    // All receiving clocks completed before this source can restrict later DATA histories.
                    try conservativeWires!.publishSequentialPlateau(net: net, instance: i, period: clockWave.rise.clock.period,
                        riseArrival: historyRise.arrival, fallArrival: historyFall.arrival,
                        riseSlew: historyRise.slew, fallSlew: historyFall.slew, load: loads[n],
                        sourceIdentity: identity, work: &work)
                }
            }
        }
        var remaining = design.instances.indices.filter {
            (cells[$0].sequentialModel == nil || (sequentialPlans[$0]?.kind == .latch && (staticStates[$0] == nil || staticStates[$0]?.effect == .inactive)))
                && propagatedClocks?.instances.contains($0) != true
        }
        while !remaining.isEmpty {
            var ready: [Int] = []
            for i in remaining {
                try charge(UInt64(cells[i].inputPins.count) + 1)
                let pins = sequentialPlans[i].map { $0.dataPins + [$0.clockPin] } ?? cells[i].inputPins.map(\.name)
                if pins.allSatisfy({ pin in design.instances[i].connections[pin].map { available.contains(netIndices[$0]!) } ?? false }) { ready.append(i) }
            }
            guard !ready.isEmpty else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "combinational cycle or missing driver") }
            for i in ready {
                let instance = design.instances[i]; let cell = cells[i]
                if let plan = sequentialPlans[i], plan.kind == .latch {
                    try transferLatch(instance: i, plan: plan, loads: loads)
                    for output in plan.outputs { if let net = instance.connections[output.pin] { available.insert(netIndices[net]!) } }
                    continue
                }
                let constantSource = try staticSource(for: cell)
                for output in cell.outputPins {
                    guard let net = instance.connections[output.name] else { continue }
                    let n = netIndices[net]!
                    if request.requireStrictSourceEvidence, constants[net] != nil { available.insert(n); continue }
                    if let constantSource {
                        for pin in constantSource.pins {
                            try charge()
                            if pin.name == output.name {
                                if let value = try staticValue(pin) {
                                    constants[net] = value
                                    try sourceEvidence?.mark(instance: instance.name, kind: .pin, pin: output.name,
                                        disposition: value == .one ? .staticOne : .staticZero,
                                        witness: "exact owned zero-symbol binary output function", limits: limits, work: &work)
                                }
                                break
                            }
                        }
                    }
                    for input in cell.inputPins {
                        let inputNet = netIndices[instance.connections[input.name]!]!
                        for arc in cell.arcs(from: input.name, to: output.name) where !arc.isConstraint {
                            if let value = constants[netNames[inputNet]] {
                                try sourceEvidence?.mark(instance: instance.name, kind: .propagation, pin: output.name,
                                    relatedPin: input.name, disposition: value == .one ? .staticOne : .staticZero,
                                    witness: "exact static input has no transition on this propagation arc", limits: limits, work: &work)
                            }
                            for parent in netPoints[inputNet] {
                                let p = try received(parent, sink: instance.name + pinDelimiter + input.name)
                                for edge in [TimingEdge.rise, .fall] where arc.sense.inputEdge(for: edge).map({ $0 == p.edge }) ?? true {
                                    try charge()
                                    let lateSample = try propagation(instance: i, arc: arc, edge: edge, inputEdge: p.edge,
                                        slew: p.lateSlew, slewBounds: NativeSTATimingBounds.slew(p.earlySlew, p.lateSlew), load: loads[n], context: .late, inputPoint: parent,
                                        receiver: instance.name + pinDelimiter + input.name)
                                    let earlySample = try propagation(instance: i, arc: arc, edge: edge, inputEdge: p.edge,
                                        slew: p.earlySlew, slewBounds: NativeSTATimingBounds.slew(p.earlySlew, p.lateSlew), load: loads[n], context: .early, inputPoint: parent,
                                        receiver: instance.name + pinDelimiter + input.name)
                                    let late = lateSample.delay, early = earlySample.delay
                                    let lateSlew = lateSample.slew, earlySlew = earlySample.slew
                                    try append(.init(net: n, launch: p.launch, parent: parent,
                                        step: .init(instance: i, inputPin: input.name, outputPin: output.name, inputNet: inputNet, lateDelay: late, earlyDelay: early, load: loads[n],
                                            lateWireDelay: p.late - points[parent].late, earlyWireDelay: p.early - points[parent].early,
                                            inputSlew: p.lateSlew),
                                        edge: edge,
                                        late: try request.conservativeCoupledRC == nil ? p.late + late : NativeSTATimingBounds.add(p.late, late, upper: true),
                                        early: try request.conservativeCoupledRC == nil ? p.early + early : NativeSTATimingBounds.add(p.early, early, upper: false), lateSlew: lateSlew, earlySlew: earlySlew))
                                }
                            }
                        }
                    }
                    available.insert(n)
                }
            }
            let done = Set(ready); remaining.removeAll { done.contains($0) }
        }
        var endpoints: [STAEndpoint] = []; var unknown: [STAEndpoint] = []
        for i in design.instances.indices {
            guard let model = cells[i].sequentialModel, let plan = sequentialPlans[i] else { continue }
            let instance = design.instances[i]
            guard let clockNet = instance.connections[plan.clockPin], let capture = clock(on: clockNet) else {
                throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing exact sequential clock")
            }
            var byPin: [String: STAEndpoint] = [:]
            for pin in plan.dataPins {
                guard let data = instance.connections[pin], let net = netIndices[data] else {
                    throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing referenced sequential data input")
                }
                if let state = staticStates[i], state.effect == .clear || state.effect == .preset {
                    let kinds = [STAAnalysisKind.setup, .hold].filter { request.analysisKinds.contains($0) }
                    byPin[pin] = STAEndpoint(modeID: mode, cornerID: corner, endpoint: instance.name + "/" + pin,
                        notApplicableChecks: kinds.isEmpty ? nil : kinds)
                    for kind in kinds {
                        try sourceEvidence?.mark(instance: instance.name, kind: .sequentialCheck, pin: pin,
                            checkKind: TimingCheckArc.Kind(rawValue: kind.rawValue), disposition: .staticStateNotApplicable,
                            witness: "proved asserted source clear/preset holds state independent of data transitions", limits: limits, work: &work)
                    }
                    continue
                }
                let (endpoint, missing) = try evaluate(name: instance.name + "/" + pin, net: net, capture: capture,
                    model: model, instance: instance.name, constant: constants[data],
                    physicalSink: instance.name + pinDelimiter + pin, constrainedPin: pin)
                byPin[pin] = endpoint
                if let missing { unknown.append(missing) }
            }
            for kind in [STAAnalysisKind.recovery, .removal] where request.analysisKinds.contains(kind) {
                var controlPins = plan.controlPins
                if !request.requireStrictSourceEvidence {
                    controlPins = []
                    for check in model.timingChecks ?? [] where check.kind.rawValue == kind.rawValue {
                        try charge(UInt64(controlPins.count) + 1)
                        if !controlPins.contains(check.constrainedPin) {
                            try stateBudget.reserve(1); controlPins.append(check.constrainedPin)
                        }
                    }
                    guard !controlPins.isEmpty else {
                        throw TimingError.unsupportedSemantic(format: "STA", semantic: "missing " + kind.rawValue + " constraint")
                    }
                }
                for pin in controlPins {
                    // Ordinary reports retain their historical per-kind worst control summary.
                    let endpointPin = request.requireStrictSourceEvidence ? pin : (model.dataPin ?? pin)
                    var endpoint = byPin[endpointPin] ?? STAEndpoint(modeID: mode, cornerID: corner,
                        endpoint: instance.name + "/" + endpointPin)
                    if request.requireStrictSourceEvidence {
                        if !(model.timingChecks ?? []).contains(where: { $0.kind.rawValue == kind.rawValue && $0.constrainedPin == pin }) {
                            endpoint.notApplicableChecks = (endpoint.notApplicableChecks ?? []) + [kind]
                            byPin[endpointPin] = endpoint
                            continue
                        }
                        if let net = instance.connections[pin], constants[net] != nil {
                            endpoint.notApplicableChecks = (endpoint.notApplicableChecks ?? []) + [kind]
                            try sourceEvidence?.mark(instance: instance.name, kind: .sequentialCheck, pin: pin,
                                checkKind: TimingCheckArc.Kind(rawValue: kind.rawValue), disposition: .staticControlNotApplicable,
                                witness: "exact candidate constant control has no recovery/removal transition", limits: limits, work: &work)
                            byPin[endpointPin] = endpoint
                            continue
                        }
                    }
                    let slack = try controlSlack(model: model, instance: instance.name,
                        capture: capture, kind: kind, constrainedPin: pin)
                    if kind == .recovery { endpoint.recoverySlack = min(endpoint.recoverySlack ?? slack, slack) }
                    else { endpoint.removalSlack = min(endpoint.removalSlack ?? slack, slack) }
                    byPin[endpointPin] = endpoint
                }
            }
            if request.requireStrictSourceEvidence {
                for (pin, pulse) in try pulseEndpoints(instance: i, constants: constants) {
                    if var endpoint = byPin[pin] {
                        endpoint.pulseWidthSlack = pulse.pulseWidthSlack
                        if let kinds = pulse.notApplicableChecks {
                            for kind in kinds where !(endpoint.notApplicableChecks ?? []).contains(kind) {
                                endpoint.notApplicableChecks = (endpoint.notApplicableChecks ?? []) + [kind]
                            }
                        }
                        byPin[pin] = endpoint
                    } else { byPin[pin] = pulse }
                }
            } else if request.analysisKinds.contains(.pulseWidth) {
                guard let minimum = model.minPulseWidth else {
                    throw TimingError.unsupportedSemantic(format: "STA", semantic: "pulse width without exact source constraint")
                }
                let rise = clockBoundary(instance: instance.name, clock: capture, edge: .rise)
                let fall = clockBoundary(instance: instance.name, clock: capture, edge: .fall)
                let high = fall.early - rise.late + (fall.early <= rise.late ? capture.period : 0)
                let endpointPin = request.requireStrictSourceEvidence ? plan.clockPin : (model.dataPin ?? plan.clockPin)
                var endpoint = byPin[endpointPin] ?? STAEndpoint(modeID: mode, cornerID: corner,
                    endpoint: instance.name + "/" + endpointPin)
                endpoint.pulseWidthSlack = high - minimum - capture.uncertainty
                byPin[endpointPin] = endpoint
            }
            endpoints.append(contentsOf: byPin.keys.sorted().compactMap { byPin[$0] })
        }
        for index in design.instances.indices where cells[index].sequentialModel == nil {
            let pulsed = try pulseEndpoints(instance: index, constants: constants)
            endpoints.append(contentsOf: pulsed.keys.sorted().compactMap { pulsed[$0] })
        }
        for port in design.ports where port.direction != .input {
            let delay = constraints.outputDelays.first { $0.port == port.name }
            let capture = delay?.clock.flatMap { constraints.clock(named: $0) }
            let (endpoint, missing) = try evaluate(name: port.name, net: netIndices[port.netName]!, capture: capture, model: nil, instance: nil, constant: constants[port.netName])
            if endpoint.setupSlack != nil || endpoint.holdSlack != nil || endpoint.staticChecks != nil || endpoint.excludedChecks != nil { endpoints.append(endpoint) }
            if let missing { unknown.append(missing) }
        }
        guard !endpoints.isEmpty else { throw TimingError.unsupportedSemantic(format: "STA", semantic: "no constrained timing endpoints") }
        var violations: [STAViolation] = []
        for endpoint in endpoints {
            for (kind, value) in [(STAAnalysisKind.setup, endpoint.setupSlack), (.hold, endpoint.holdSlack), (.recovery, endpoint.recoverySlack), (.removal, endpoint.removalSlack), (.pulseWidth, endpoint.pulseWidthSlack)] {
                if let value, value < 0 { violations.append(.init(kind: kind, modeID: mode, cornerID: corner, endpoint: endpoint.endpoint, slack: value)) }
            }
        }
        candidates.sort { a, b in
            if a.slack != b.slack { return a.slack < b.slack }
            if a.endpoint != b.endpoint { return a.endpoint < b.endpoint }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            return a.point < b.point
        }
        var reports: [STAPath] = []
        for candidate in candidates.prefix(request.maxPaths) {
            var stages: [STAPathStage] = []; var cursor = candidate.point
            while let step = points[cursor].step, let parent = points[cursor].parent {
                try charge()
                stages.append(.init(instance: design.instances[step.instance].name, cell: cells[step.instance].name,
                    inputPin: step.inputPin, inputNet: netNames[step.inputNet], outputNet: netNames[points[cursor].net],
                    inputEdge: points[parent].edge, outputEdge: points[cursor].edge,
                    delay: candidate.kind == .setup ? step.lateDelay : step.earlyDelay,
                    outputSlew: candidate.kind == .setup ? points[cursor].lateSlew : points[cursor].earlySlew, load: step.load, inputWireDelay: candidate.kind == .setup ? step.lateWireDelay : step.earlyWireDelay))
                cursor = parent
            }
            reports.append(.init(modeID: mode, cornerID: corner, startpoint: launches[points[candidate.point].launch].name,
                endpoint: candidate.endpoint, arrival: candidate.arrival, required: candidate.required, slack: candidate.slack,
                stages: stages.reversed(), analysisKind: candidate.kind))
        }
        var coverage: [STAWireCoverage] = []
        if let distributedRC {
            let clocks = Set((constraints.clocks.map(\.source) + constraints.generatedClocks.map(\.source)).map { clock in
                design.ports.first { $0.name == clock }?.netName ?? clock
            })
            coverage = netNames.map { net in
                let model: STAWireCoverage.Model = constants[net] != nil ? .staticNoTransition
                    : propagatedClocks?.nets[net] != nil ? .propagatedClock
                    : distributedRC.contains(net) ? .distributedRC : clocks.contains(net) ? .idealClock : .uncovered
                return .init(modeID: mode, cornerID: corner, net: net, model: model)
            }
        }
        if let conservativeWires {
            coverage = netNames.map { net in
                .init(modeID: mode, cornerID: corner, net: net,
                      model: constants[net] != nil ? .staticNoTransition : conservativeWires.contains(net) ? .conservativeCoupledRC : .uncovered)
            }
        }
        try Task.checkCancellation()
        if request.requireStrictSourceEvidence && !unknown.isEmpty {
            throw TimingError.unsupportedSemantic(format: "strict source STA", semantic: "unconstrained required execution coverage")
        }
        let sourceCoverage = try sourceEvidence?.finish(stateBudget: stateBudget, limits: limits, work: &work) ?? []
        return .init(clockObservations: propagatedClocks?.observations ?? [], rcSteps: distributedRC?.steps ?? initialRCSteps,
            wireCoverage: coverage, wireObservations: distributedRC?.observations ?? [],
            conservativeWireObservations: conservativeWires?.observations ?? [], workUnits: work,
            endpoints: endpoints, unconstrainedEndpoints: unknown, paths: reports, violations: violations,
            sourceCoverage: sourceCoverage, sourceSamples: sourceEvidence?.samples ?? [],
            pulseWidthSamples: sourceEvidence?.pulseWidthSamples ?? [], staticStateSamples: sourceEvidence?.staticStateSamples ?? [],
            normalPowerSamples:sourceEvidence?.normalPowerSamples ?? [],normalPowerOwners:sourceEvidence?.normalPowerOwners ?? [])
    }
}

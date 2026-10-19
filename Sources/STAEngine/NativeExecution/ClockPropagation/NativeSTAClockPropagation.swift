import LogicIR
import TimingCore

/// Scenario-local primary clock composition; every physical segment keeps its actual timing identity.
internal struct NativeSTAClockPropagation {
    private struct Buffer { let instance: Int; let input: String; let output: String; let inputNet: String; let outputNet: String; let arc: TimingArc }
    private(set) var nets: [String: NativeSTAClockWave] = [:]
    private(set) var leaves: [String: NativeSTAClockWave] = [:]
    private(set) var instances: Set<Int> = []
    private(set) var observations: [STAClockObservation] = []
    private let stateBudget: NativeSTAStateBudget

    static func characterizationCells(design: TimingDesign, library: TimingLibrary, constraints: [TimingConstraintSet],
                                      plans: [Int: NativeSTASequentialExecution.Plan],
                                      resources: any LibertySourceResourceAccounting, delimiter: String) throws -> (buffers: [String], sequential: [String], receivers: [(root: String, receiver: String)]) {
        let clocks = constraints.flatMap(\.clocks)
        let roots = Set(clocks.compactMap { clock in design.ports.first { $0.name == clock.source }?.netName })
        let selectedRoots = Set(clocks.filter(\.isPropagated).compactMap { clock in design.ports.first { $0.name == clock.source }?.netName })
        var drivers: [String: Int] = [:], buffers = Set<String>(), sequential = Set<String>()
        var receivers: [(String, String)] = []
        let cells = try design.instances.map { try library.cell(named: $0.cell) }
        for i in design.instances.indices { for pin in cells[i].outputPins { if let net = design.instances[i].connections[pin.name] { drivers[net] = i } } }
        for i in design.instances.indices {
            guard cells[i].sequentialModel != nil else { continue }
            guard let plan = plans[i] else { throw Self.unsupported("missing compiled clock/gate receiver") }
            let clockPin = plan.clockPin
            guard let net = design.instances[i].connections[clockPin] else { throw Self.unsupported("missing exact clock receiver binding") }
            var cursor = net, path: [String] = [], seen = Set<String>()
            while !roots.contains(cursor) {
                try resources.check(); try resources.chargeWork(UInt64(cursor.utf8.count) + 1)
                guard seen.insert(cursor).inserted, let driver = drivers[cursor], cells[driver].sequentialModel == nil,
                      cells[driver].inputPins.count == 1, cells[driver].outputPins.count == 1,
                      let input = design.instances[driver].connections[cells[driver].inputPins[0].name] else { throw Self.unsupported("unresolved clock characterization cone") }
                path.append(cells[driver].name); cursor = input
            }
            if selectedRoots.contains(cursor) {
                buffers.formUnion(path); sequential.insert(cells[i].name)
                guard let clock = clocks.first(where: { clock in clock.isPropagated && design.ports.first(where: { $0.name == clock.source })?.netName == cursor }) else { throw Self.unsupported("missing primary clock") }
                receivers.append((clock.name, design.instances[i].name + delimiter + clockPin))
            }
        }
        return (buffers.sorted(), sequential.sorted(), receivers)
    }

    init(design: TimingDesign, cells: [TimingCell], source: OwnedLibertySource, constraints: TimingConstraintSet,
         sequentialPlans: [Int: NativeSTASequentialExecution.Plan], normalPowerValidated: Bool,
         sourceEvidence: inout NativeSTASourceEvidence?,
         loads: [String: Double], characterized: CharacterizedTimingLibrary?, sourceResources: (any LibertySourceResourceAccounting)?, stateBudget: NativeSTAStateBudget, variation: STAVariation, limits: STAExecutionLimits, delimiter: String,
         mode: String, corner: String, rc: inout NativeSTADistributedRC?, conservative: inout NativeSTAConservativeWires?, work: inout UInt64) throws {
        self.stateBudget = stateBudget
        let selected = constraints.clocks.filter(\.isPropagated)
        guard !selected.isEmpty else { return }
        guard let characterized else { throw Self.unsupported("missing retained strict clock characterization") }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Native propagated clocks have no generated-clock edge/ratio model.
        // This execution entrypoint must reject that profile until actual root/edge phase semantics are implemented and tested.
        guard constraints.generatedClocks.isEmpty else { throw Self.unsupported("generated clocks") }
        var roots: [String: TimingConstraintSet.Clock] = [:]
        var rootPublications: [NativeSTAConservativeWires.ClockPublication] = []
        for clock in constraints.clocks {
            guard let port = design.ports.first(where: { $0.name == clock.source }), roots[port.netName] == nil else { throw Self.unsupported("ambiguous clock source") }
            roots[port.netName] = clock
            if clock.isPropagated {
                guard clock.hasValidPropagatedSource else { throw Self.unsupported("missing explicit clock waveform/edge transition") }
                let rise = NativeSTAClockEvent(clock: clock, edge: .rise, rootEdge: .rise, rootPhase: clock.waveform[0],
                    late: clock.waveform[0], early: clock.waveform[0], lateSlew: clock.sourceRiseTransition!, earlySlew: clock.sourceRiseTransition!, segments: [])
                let fall = NativeSTAClockEvent(clock: clock, edge: .fall, rootEdge: .fall, rootPhase: clock.waveform[1],
                    late: clock.waveform[1], early: clock.waveform[1], lateSlew: clock.sourceFallTransition!, earlySlew: clock.sourceFallTransition!, segments: [])
                let wave = NativeSTAClockWave(rise: rise, fall: fall)
                try stateBudget.reserve(3); nets[port.netName] = wave
                if conservative != nil {
                    try stateBudget.reserve(1)
                    rootPublications.append(.init(net: port.netName, wave: wave))
                }
            }
        }
        if !rootPublications.isEmpty { try conservative!.publishClockHistories(rootPublications, work: &work) }
        var pendingBuffers: [String: Buffer] = [:]
        var pendingLeaves: [(instance: Int, net: String, pin: String, clock: TimingConstraintSet.Clock)] = []
        var drivers: [String: (Int, String)] = [:]
        for i in design.instances.indices {
            for pin in cells[i].outputPins {
                if let net = design.instances[i].connections[pin.name] {
                    guard drivers[net] == nil else { throw Self.unsupported("multiple clock drivers") }
                    drivers[net] = (i, pin.name)
                }
            }
        }
        var usedRoots = Set<String>()
        for i in design.instances.indices {
            guard cells[i].sequentialModel != nil else { continue }
            guard let plan = sequentialPlans[i] else { throw Self.unsupported("missing compiled clock/gate receiver") }
            let clockPin = plan.clockPin
            guard let clockNet = design.instances[i].connections[clockPin] else { throw Self.unsupported("missing exact clock receiver binding") }
            try sourceResources?.check()
            var chain: [Buffer] = [], visited = Set<String>(), cursor = clockNet
            while roots[cursor] == nil {
                try sourceResources?.check()
                try Self.charge(1, work: &work, limits: limits)
                guard visited.insert(cursor).inserted, let (driver, output) = drivers[cursor], cells[driver].sequentialModel == nil else {
                    throw Self.unsupported("clock loop, sequential driver or missing primary root")
                }
                let cell = cells[driver], instance = design.instances[driver]
                // FIXME(INCOMPLETE_IMPLEMENTATION): This production clock cone supports only source-backed buffers/inverters.
                // Gated or multiinput clock behavior must remain unsupported until its conditional edge/control semantics are implemented and tested.
                guard cell.inputPins.count == 1, cell.outputPins.count == 1, cell.outputPins[0].name == output,
                      let inputNet = instance.connections[cell.inputPins[0].name] else { throw Self.unsupported("gated/multiinput clock profile") }
                let input = cell.inputPins[0].name, arcs = cell.arcs(from: input, to: output)
                guard arcs.count == 1, arcs[0].sense != .nonUnate,
                      let facts = source.cells.first(where: { $0.name == cell.name }), facts.sequential.isEmpty,
                      facts.unsupportedFunctionalGroups.isEmpty,
                      let pin = facts.pins.first(where: { $0.name == output }), pin.threeState == nil, pin.xFunction == nil, pin.stateFunction == nil,
                      let function = pin.function else { throw Self.unsupported("uncharacterized/ambiguous clock buffer") }
                let sense = try Self.functionSense(function, symbol: input, sourceResources: sourceResources, work: &work, limits: limits)
                guard sense == arcs[0].sense else { throw Self.unsupported("clock function/timing polarity mismatch") }
                guard chain.count < limits.maximumPathStates else { throw STAPathAnalysisError.capacity(resource: "clock topology", limit: UInt64(limits.maximumPathStates)) }
                chain.append(.init(instance: driver, input: input, output: output, inputNet: inputNet, outputNet: cursor, arc: arcs[0])); cursor = inputNet
            }
            let clock = roots[cursor]!
            guard clock.isPropagated else {
                if rc?.contains(clockNet) == true || conservative?.contains(clockNet) == true || !chain.isEmpty { throw Self.unsupported("finite-R/buffered clock lacks explicit propagated source") }
                continue
            }
            usedRoots.insert(clock.name)
            guard let declaration = source.cells.first(where: { $0.name == cells[i].name }), plan.declaration != nil else {
                throw Self.unsupported("missing exact sequential source clock/gate plan")
            }
            guard normalPowerValidated || (declaration.sequential.allSatisfy { $0.powerDownFunction == nil }
                && declaration.pins.allSatisfy { $0.powerDownFunction == nil }) else {
                throw Self.unsupported("clock receiver requires explicit normal-power conditions")
            }
            for output in plan.outputs where design.instances[i].connections[output.pin] != nil {
                let arcs = cells[i].arcs(from: clockPin, to: output.pin).filter { !$0.isConstraint }
                guard arcs.count == 1, let identity = arcs[0].sourceIdentity,
                      identity.timingType == (plan.activeEdge == .rise ? "rising_edge" : "falling_edge") else {
                    throw Self.unsupported("missing exact clock/gate-to-output source arc")
                }
            }
            if conservative != nil {
                for buffer in chain {
                    try Self.charge(1, work: &work, limits: limits)
                    if pendingBuffers[buffer.outputNet] == nil { try stateBudget.reserve(1) }
                    pendingBuffers[buffer.outputNet] = buffer
                }
                try stateBudget.reserve(1)
                pendingLeaves.append((i, clockNet, clockPin, clock))
                continue
            }
            for buffer in chain.reversed() {
                try sourceResources?.check()
                instances.insert(buffer.instance)
                if nets[buffer.outputNet] != nil { continue }
                nets[buffer.outputNet] = try bufferWave(buffer, design: design, cells: cells, loads: loads,
                    characterized: characterized, sourceEvidence: &sourceEvidence, sourceResources: sourceResources,
                    variation: variation, limits: limits, delimiter: delimiter, rc: &rc, conservative: &conservative, work: &work)
            }
            guard let upstream = nets[clockNet] else { throw Self.unsupported("missing FF clock predecessor") }
            let receiver = design.instances[i].name + delimiter + clockPin
            let leaf = try receive(upstream, net: clockNet, sink: receiver, variation: variation, limits: limits, rc: &rc, conservative: &conservative, work: &work)
            try stateBudget.reserve(3)
            leaves[design.instances[i].name] = leaf
            for event in [leaf.rise, leaf.fall] {
                observations.append(.init(modeID: mode, cornerID: corner, receiver: receiver, rootClock: clock.name,
                    edge: event.edge, rootEdge: event.rootEdge, rootPhase: event.rootPhase, period: clock.period,
                    lateArrival: event.late, earlyArrival: event.early, lateSlew: event.lateSlew, earlySlew: event.earlySlew, segments: event.segments))
            }
        }
        while !pendingBuffers.isEmpty {
            try sourceResources?.check()
            try Self.charge(1, work: &work, limits: limits)
            try stateBudget.reserve(pendingBuffers.count)
            var frontier: [Buffer] = []
            for index in design.instances.indices {
                try sourceResources?.check()
                try Self.charge(1, work: &work, limits: limits)
                for pin in cells[index].outputPins {
                    try Self.charge(UInt64(pin.name.utf8.count) + 1, work: &work, limits: limits)
                    guard let net = design.instances[index].connections[pin.name] else { continue }
                    try Self.charge(UInt64(net.utf8.count), work: &work, limits: limits)
                    if let buffer = pendingBuffers[net], nets[buffer.inputNet] != nil { frontier.append(buffer) }
                }
            }
            guard !frontier.isEmpty else { throw Self.unsupported("unresolved checked clock frontier") }
            try stateBudget.reserve(frontier.count)
            var publications: [NativeSTAConservativeWires.ClockPublication] = []
            for buffer in frontier {
                try Self.charge(1, work: &work, limits: limits)
                let wave = try bufferWave(buffer, design: design, cells: cells, loads: loads,
                    characterized: characterized, sourceEvidence: &sourceEvidence, sourceResources: sourceResources,
                    variation: variation, limits: limits, delimiter: delimiter, rc: &rc, conservative: &conservative, work: &work)
                guard let load = loads[buffer.outputNet], let identity = buffer.arc.sourceIdentity else {
                    throw Self.unsupported("missing checked clock source load/identity")
                }
                publications.append(.init(net: buffer.outputNet, wave: wave, load: load, sourceIdentity: identity))
            }
            // Every wave above was proved with the previous complete source history.
            try conservative!.publishClockHistories(publications, work: &work)
            try stateBudget.reserve(publications.count)
            for publication in publications {
                try Self.charge(1, work: &work, limits: limits)
                nets[publication.net] = publication.wave
            }
            for buffer in frontier {
                try Self.charge(1, work: &work, limits: limits)
                try stateBudget.reserve(1); instances.insert(buffer.instance)
                pendingBuffers.removeValue(forKey: buffer.outputNet)
            }
        }
        for pending in pendingLeaves {
            try Self.charge(1, work: &work, limits: limits)
            guard let upstream = nets[pending.net] else { throw Self.unsupported("missing FF clock predecessor") }
            let receiver = design.instances[pending.instance].name + delimiter + pending.pin
            let leaf = try receive(upstream, net: pending.net, sink: receiver, variation: variation,
                limits: limits, rc: &rc, conservative: &conservative, work: &work)
            try stateBudget.reserve(3)
            leaves[design.instances[pending.instance].name] = leaf
            for event in [leaf.rise, leaf.fall] {
                observations.append(.init(modeID: mode, cornerID: corner, receiver: receiver, rootClock: pending.clock.name,
                    edge: event.edge, rootEdge: event.rootEdge, rootPhase: event.rootPhase, period: pending.clock.period,
                    lateArrival: event.late, earlyArrival: event.early, lateSlew: event.lateSlew,
                    earlySlew: event.earlySlew, segments: event.segments))
            }
        }
        guard usedRoots == Set(selected.map(\.name)) else { throw Self.unsupported("propagated clock without actual FF receiver") }
        for i in design.instances.indices {
            for pin in cells[i].inputPins {
                guard let net = design.instances[i].connections[pin.name], nets[net] != nil else { continue }
                // FIXME(INCOMPLETE_IMPLEMENTATION): Clock-as-data fanout is outside the primary clock profile.
                // This production consumer must refuse until periodic data/output timing semantics are implemented and tested.
                guard instances.contains(i) || sequentialPlans[i]?.clockPin == pin.name else { throw Self.unsupported("clock-as-data fanout") }
            }
        }
        if conservative != nil {
            try stateBudget.reserve(pendingLeaves.count)
            var checked: [(instance: Int, period: Double)] = []
            for pending in pendingLeaves {
                try Self.charge(1, work: &work, limits: limits)
                checked.append((pending.instance, pending.clock.period))
            }
            try conservative!.markProvedClockReceivers(checked, work: &work)
        }
    }

    private mutating func bufferWave(_ buffer: Buffer, design: TimingDesign, cells: [TimingCell],
        loads: [String: Double], characterized: CharacterizedTimingLibrary,
        sourceEvidence: inout NativeSTASourceEvidence?, sourceResources: (any LibertySourceResourceAccounting)?,
        variation: STAVariation, limits: STAExecutionLimits, delimiter: String,
        rc: inout NativeSTADistributedRC?, conservative: inout NativeSTAConservativeWires?,
        work: inout UInt64) throws -> NativeSTAClockWave {
        guard let upstream = nets[buffer.inputNet] else { throw Self.unsupported("missing characterized clock predecessor") }
        let name = design.instances[buffer.instance].name
        let input = try receive(upstream, net: buffer.inputNet, sink: name + delimiter + buffer.input,
            variation: variation, limits: limits, rc: &rc, conservative: &conservative, work: &work)
        let load = loads[buffer.outputNet] ?? 0
        let earlyCellScale = conservative == nil ? variation.earlyCellDelayScale : min(variation.earlyCellDelayScale, variation.lateCellDelayScale)
        let lateCellScale = conservative == nil ? variation.lateCellDelayScale : max(variation.earlyCellDelayScale, variation.lateCellDelayScale)
        func output(_ edge: TimingEdge) throws -> NativeSTAClockEvent {
            let incoming = input.event(buffer.arc.sense.inputEdge(for: edge)!)
            let range = try conservative.map { _ in
                try characterized.evaluatePropagation(cell: cells[buffer.instance].name, fromPin: buffer.input,
                    toPin: buffer.output, edge: edge,
                    inputSlew: NativeSTATimingBounds.slew(incoming.earlySlew, incoming.lateSlew), outputLoad: load...load)
            }
            let lateSample = try characterized.evaluatePropagation(cell: cells[buffer.instance].name, fromPin: buffer.input,
                toPin: buffer.output, edge: edge, inputSlew: incoming.lateSlew, outputLoad: load)
            let earlySample = try characterized.evaluatePropagation(cell: cells[buffer.instance].name, fromPin: buffer.input,
                toPin: buffer.output, edge: edge, inputSlew: incoming.earlySlew, outputLoad: load)
            let receiver = name + delimiter + buffer.input
            for (sample, context, scale) in [(lateSample, STASourceEvidence.Sample.Context.late, lateCellScale),
                                            (earlySample, .early, earlyCellScale)] {
                _ = try sourceEvidence?.record(sample.delay, instance: name, context: context,
                    inputEdge: incoming.edge, outputEdge: edge, inputPoint: nil, receiver: receiver,
                    scale: scale, rangeObservation: range?.delay, stateBudget: stateBudget, limits: limits, work: &work)
                _ = try sourceEvidence?.record(sample.outputSlew, instance: name, context: context,
                    inputEdge: incoming.edge, outputEdge: edge, inputPoint: nil, receiver: receiver,
                    scale: 1, rangeObservation: range?.outputSlew, stateBudget: stateBudget, limits: limits, work: &work)
            }
            let late = try range.map { try NativeSTATimingBounds.scale($0.delay.result, by: lateCellScale).upperBound }
                ?? lateSample.delay.result * variation.lateCellDelayScale
            let early = try range.map { try NativeSTATimingBounds.scale($0.delay.result, by: earlyCellScale).lowerBound }
                ?? earlySample.delay.result * variation.earlyCellDelayScale
            let lateSlew = range?.outputSlew.result.upperBound ?? lateSample.outputSlew.result
            let earlySlew = range?.outputSlew.result.lowerBound ?? earlySample.outputSlew.result
            guard [late, early, lateSlew, earlySlew].allSatisfy(\.isFinite), lateSlew > 0, earlySlew > 0 else { throw Self.unsupported("invalid characterized clock arc") }
            return .init(clock: incoming.clock, edge: edge, rootEdge: incoming.rootEdge, rootPhase: incoming.rootPhase,
                late: try range == nil ? incoming.late + late : NativeSTATimingBounds.add(incoming.late, late, upper: true),
                early: try range == nil ? incoming.early + early : NativeSTATimingBounds.add(incoming.early, early, upper: false), lateSlew: lateSlew, earlySlew: earlySlew,
                segments: incoming.segments + [.init(physicalIdentity: "cell:" + name + ":" + buffer.input + ":" + buffer.output + ":" + edge.rawValue, lateDelay: late, earlyDelay: early)])
        }
        try Self.charge(2, work: &work, limits: limits)
        try stateBudget.reserve(input.rise.segments.count + input.fall.segments.count + 5)
        let wave = try NativeSTAClockWave(rise: output(.rise), fall: output(.fall))
        return wave
    }

    private mutating func receive(_ wave: NativeSTAClockWave, net: String, sink: String, variation: STAVariation,
                                  limits: STAExecutionLimits, rc: inout NativeSTADistributedRC?, conservative: inout NativeSTAConservativeWires?, work: inout UInt64) throws -> NativeSTAClockWave {
        if conservative != nil {
            try conservative!.validatePeriodic(net: net, riseEarly: wave.rise.early, riseLate: wave.rise.late,
                fallEarly: wave.fall.early, fallLate: wave.fall.late,
                riseSlew: NativeSTATimingBounds.slew(wave.rise.earlySlew, wave.rise.lateSlew),
                fallSlew: NativeSTATimingBounds.slew(wave.fall.earlySlew, wave.fall.lateSlew),
                riseRootPhase: wave.rise.rootPhase, fallRootPhase: wave.fall.rootPhase, period: wave.rise.clock.period, work: &work)
            let rise = try conservative!.response(net: net, sink: sink, edge: .rise,
                sourceSlew: NativeSTATimingBounds.slew(wave.rise.earlySlew, wave.rise.lateSlew), work: &work)
            let fall = try conservative!.response(net: net, sink: sink, edge: .fall,
                sourceSlew: NativeSTATimingBounds.slew(wave.fall.earlySlew, wave.fall.lateSlew), work: &work)
            func event(_ edge: TimingEdge) throws -> NativeSTAClockEvent {
                let input = wave.event(edge), result = edge == .rise ? rise : fall
                let delay = try NativeSTATimingBounds.derated(result.delay, early: variation.earlyInterconnectDelayScale, late: variation.lateInterconnectDelayScale)
                let early = delay.lowerBound, late = delay.upperBound
                return .init(clock: input.clock, edge: edge, rootEdge: input.rootEdge, rootPhase: input.rootPhase,
                    late: try NativeSTATimingBounds.add(input.late, late, upper: true),
                    early: try NativeSTATimingBounds.add(input.early, early, upper: false),
                    lateSlew: result.slew.upperBound, earlySlew: result.slew.lowerBound,
                    segments: input.segments + [.init(physicalIdentity: "wire:" + net + ":" + sink + ":" + edge.rawValue,
                        lateDelay: late, earlyDelay: early)])
            }
            try stateBudget.reserve(wave.rise.segments.count + wave.fall.segments.count + 4)
            return try .init(rise: event(.rise), fall: event(.fall))
        }
        guard rc != nil else { throw Self.unsupported("missing wire timing model") }
        let late = try rc!.periodicResponse(net: net, sink: sink, source: wave.lateSource, work: &work)
        let early = try rc!.periodicResponse(net: net, sink: sink, source: wave.earlySource, work: &work)
        func event(_ edge: TimingEdge) -> NativeSTAClockEvent {
            let incoming = wave.event(edge)
            let lateDelay = (edge == .rise ? late.riseDelay : late.fallDelay) * variation.lateInterconnectDelayScale
            let earlyDelay = (edge == .rise ? early.riseDelay : early.fallDelay) * variation.earlyInterconnectDelayScale
            return .init(clock: incoming.clock, edge: edge, rootEdge: incoming.rootEdge, rootPhase: incoming.rootPhase,
                late: incoming.late + lateDelay, early: incoming.early + earlyDelay,
                lateSlew: edge == .rise ? late.riseSlew : late.fallSlew, earlySlew: edge == .rise ? early.riseSlew : early.fallSlew,
                segments: incoming.segments + [.init(physicalIdentity: "wire:" + net + ":" + sink + ":" + edge.rawValue,
                    lateDelay: lateDelay, earlyDelay: earlyDelay)])
        }
        try stateBudget.reserve(wave.rise.segments.count + wave.fall.segments.count + 4)
        return NativeSTAClockWave(rise: event(.rise), fall: event(.fall))
    }
    static func functionSense(_ function: LibertySourceFunction, symbol: String, sourceResources: (any LibertySourceResourceAccounting)?, work: inout UInt64,
                                      limits: STAExecutionLimits) throws -> TimingSense {
        guard case .normalized(let facts) = function.content, facts.symbols == [symbol],
              facts.operations.count <= limits.maximumPathStates else { throw unsupported("unsupported clock function") }
        var outputs: [Bool] = []
        for input in [false, true] {
            var values: [Bool] = []; values.reserveCapacity(facts.operations.count)
            func prior(_ index: LogicBooleanNodeIndex) throws -> Bool {
                guard values.indices.contains(index.rawValue) else { throw unsupported("invalid clock function edge") }; return values[index.rawValue]
            }
            for operation in facts.operations {
                try sourceResources?.check()
                try charge(1, work: &work, limits: limits)
                switch operation {
                case .constant(let value): values.append(value)
                case .input(let slot): guard slot == 0 else { throw unsupported("invalid clock function symbol") }; values.append(input)
                case .invert(let a): values.append(try !prior(a))
                case .and(let a, let b): values.append(try prior(a) && prior(b))
                case .or(let a, let b): values.append(try prior(a) || prior(b))
                case .xor(let a, let b): values.append(try prior(a) != prior(b))
                }
            }
            outputs.append(try prior(facts.output))
        }
        guard outputs[0] != outputs[1] else { throw unsupported("constant clock function") }
        return outputs[0] ? .negativeUnate : .positiveUnate
    }
    private static func charge(_ amount: UInt64, work: inout UInt64, limits: STAExecutionLimits) throws {
        try Task.checkCancellation()
        let sum = work.addingReportingOverflow(amount)
        guard !sum.overflow, sum.partialValue <= limits.maximumPathWorkUnits else { throw STAPathAnalysisError.capacity(resource: "clock path work", limit: limits.maximumPathWorkUnits) }
        work = sum.partialValue
    }
    private static func unsupported(_ semantic: String) -> TimingError { .unsupportedSemantic(format: "propagated clock STA", semantic: semantic) }
}

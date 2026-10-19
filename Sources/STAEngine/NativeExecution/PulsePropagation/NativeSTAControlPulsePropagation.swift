import TimingCore

/// Conditional primary pulse sources propagated through the exact candidate, never receiver overrides.
internal struct NativeSTAControlPulsePropagation {
    struct Event {
        let edge: TimingEdge
        let rootEdge: TimingEdge
        let rootPhase: Double
        let early: Double
        let late: Double
        let earlySlew: Double
        let lateSlew: Double
        let segments: [STAClockObservation.Segment]
    }
    struct Wave {
        let source: STAControlPulseSource
        let rise: Event
        let fall: Event
        func event(_ edge: TimingEdge) -> Event { edge == .rise ? rise : fall }
        var earlySource: STAPeriodicRCSource {
            .init(period: source.period, risePhase: rise.early, fallPhase: fall.early,
                riseSlew: rise.earlySlew, fallSlew: fall.earlySlew)
        }
        var lateSource: STAPeriodicRCSource {
            .init(period: source.period, risePhase: rise.late, fallPhase: fall.late,
                riseSlew: rise.lateSlew, fallSlew: fall.lateSlew)
        }
    }
    private struct Buffer {
        let instance: Int
        let input: String
        let output: String
        let inputNet: String
        let outputNet: String
        let arc: TimingArc
    }
    private var nets: [String: Wave] = [:]
    private var receivers: [String: (net: String, wave: Wave)] = [:]

    func receiver(net: String, sink: String) -> Wave? {
        guard let receiver = receivers[sink], receiver.net == net else { return nil }
        return receiver.wave
    }

    init(design: TimingDesign, cells: [TimingCell], source: OwnedLibertySource,
         plans: [Int: NativeSTASequentialExecution.Plan], sources: [STAControlPulseSource],
         constants: [String: TimingDesign.Constant], loads: [String: Double],
         characterized: CharacterizedTimingLibrary, variation: STAVariation, mode: String, delimiter: String,
         resources: (any LibertySourceResourceAccounting)?, limits: STAExecutionLimits, budget: NativeSTAStateBudget,
         evidence: inout NativeSTASourceEvidence?, rc: inout NativeSTADistributedRC?, conservative: inout NativeSTAConservativeWires?, work: inout UInt64) throws {
        func charge(_ n: Int) throws {
            try NativeSTASequentialExecution.charge(UInt64(n), work: &work, limits: limits, sourceResources: resources)
        }
        var roots: [String: STAControlPulseSource] = [:]
        for definition in sources where definition.modeID == mode {
            try charge(design.ports.count + 1)
            guard let port = design.ports.first(where: { $0.name == definition.sourcePort }), port.direction == .input,
                  roots[port.netName] == nil else { throw Self.failure("ambiguous primary control pulse source") }
            func event(_ edge: TimingEdge) -> Event {
                let phase = edge == .rise ? definition.risePhase : definition.fallPhase
                let slew = edge == .rise ? definition.riseTransition : definition.fallTransition
                return .init(edge: edge, rootEdge: edge, rootPhase: phase, early: phase, late: phase,
                    earlySlew: slew, lateSlew: slew, segments: [])
            }
            try budget.reserve(4)
            roots[port.netName] = definition
            nets[port.netName] = .init(source: definition, rise: event(.rise), fall: event(.fall))
        }
        var drivers: [String: (Int, String)] = [:]
        for index in design.instances.indices {
            for pin in cells[index].outputPins {
                try charge(1)
                if let net = design.instances[index].connections[pin.name] {
                    try budget.reserve(1); drivers[net] = (index, pin.name)
                }
            }
        }
        func receive(_ wave: Wave, net: String, sink: String) throws -> Wave {
            if let cached = receivers[sink], cached.net == net { return cached.wave }
            if conservative != nil {
                try conservative!.validatePeriodic(net: net, riseEarly: wave.rise.early, riseLate: wave.rise.late,
                    fallEarly: wave.fall.early, fallLate: wave.fall.late,
                    riseSlew: NativeSTATimingBounds.slew(wave.rise.earlySlew, wave.rise.lateSlew),
                    fallSlew: NativeSTATimingBounds.slew(wave.fall.earlySlew, wave.fall.lateSlew),
                    riseRootPhase: wave.rise.rootPhase, fallRootPhase: wave.fall.rootPhase, period: wave.source.period, work: &work)
                let rise = try conservative!.response(net: net, sink: sink, edge: .rise,
                    sourceSlew: NativeSTATimingBounds.slew(wave.rise.earlySlew, wave.rise.lateSlew), work: &work)
                let fall = try conservative!.response(net: net, sink: sink, edge: .fall,
                    sourceSlew: NativeSTATimingBounds.slew(wave.fall.earlySlew, wave.fall.lateSlew), work: &work)
                func event(_ edge: TimingEdge) throws -> Event {
                    let input = wave.event(edge), result = edge == .rise ? rise : fall
                    let delay = try NativeSTATimingBounds.derated(result.delay, early: variation.earlyInterconnectDelayScale, late: variation.lateInterconnectDelayScale)
                    let early = delay.lowerBound, late = delay.upperBound
                    return .init(edge: edge, rootEdge: input.rootEdge, rootPhase: input.rootPhase,
                        early: try NativeSTATimingBounds.add(input.early, early, upper: false),
                        late: try NativeSTATimingBounds.add(input.late, late, upper: true),
                        earlySlew: result.slew.lowerBound, lateSlew: result.slew.upperBound,
                        segments: input.segments + [.init(physicalIdentity: "control-wire:" + net + ":" + sink + ":" + edge.rawValue,
                            lateDelay: late, earlyDelay: early)])
                }
                try budget.reserve(wave.rise.segments.count + wave.fall.segments.count + 5)
                let result = try Wave(source: wave.source, rise: event(.rise), fall: event(.fall))
                receivers[sink] = (net, result)
                return result
            }
            guard rc != nil else {
                try budget.reserve(1); receivers[sink] = (net, wave)
                return wave
            }
            let early = try rc!.periodicResponse(net: net, sink: sink, source: wave.earlySource, work: &work)
            let late = try rc!.periodicResponse(net: net, sink: sink, source: wave.lateSource, work: &work)
            func event(_ edge: TimingEdge) -> Event {
                let input = wave.event(edge)
                let earlyDelay = (edge == .rise ? early.riseDelay : early.fallDelay) * variation.earlyInterconnectDelayScale
                let lateDelay = (edge == .rise ? late.riseDelay : late.fallDelay) * variation.lateInterconnectDelayScale
                return .init(edge: edge, rootEdge: input.rootEdge, rootPhase: input.rootPhase,
                    early: input.early + earlyDelay, late: input.late + lateDelay,
                    earlySlew: edge == .rise ? early.riseSlew : early.fallSlew,
                    lateSlew: edge == .rise ? late.riseSlew : late.fallSlew,
                    segments: input.segments + [.init(physicalIdentity: "control-wire:" + net + ":" + sink + ":" + edge.rawValue,
                        lateDelay: lateDelay, earlyDelay: earlyDelay)])
            }
            try budget.reserve(wave.rise.segments.count + wave.fall.segments.count + 4)
            let received = Wave(source: wave.source, rise: event(.rise), fall: event(.fall))
            try budget.reserve(1); receivers[sink] = (net, received)
            return received
        }
        var used = Set<String>()
        for index in design.instances.indices {
            var pins = plans[index]?.controlPins ?? []
            for law in cells[index].pulseWidthConstraints where law.pin != plans[index]?.clockPin {
                try charge(pins.count + 1)
                if !pins.contains(law.pin) { try budget.reserve(1); pins.append(law.pin) }
            }
            for pin in pins {
                guard let net = design.instances[index].connections[pin] else { throw Self.failure("missing control pulse receiver binding") }
                if constants[net] != nil { continue }
                // No explicit waveform means unknown, even if an input-delay constraint exists.
                var cursor = net, visited = Set<String>(), chain: [Buffer] = []
                while roots[cursor] == nil {
                    try charge(cells.count + 1); try budget.reserve(2)
                    guard visited.insert(cursor).inserted, let (driver, output) = drivers[cursor],
                          cells[driver].sequentialModel == nil else { throw Self.failure("missing explicit pulse source or unsupported control driver") }
                    let cell = cells[driver], instance = design.instances[driver]
                    // FIXME(INCOMPLETE_IMPLEMENTATION): General logic/control pulse scheduling is not implemented.
                    // Production strict pulse propagation admits only source-backed buffers/inverters; multiinput controls require actual event semantics and behavioral proof before admission.
                    guard cell.inputPins.count == 1, cell.outputPins.count == 1,
                          let inputNet = instance.connections[cell.inputPins[0].name],
                          let original = source.cells.first(where: { $0.name == cell.name }),
                          original.unsupportedFunctionalGroups.isEmpty,
                          let outputPin = original.pins.first(where: { $0.name == output }),
                          outputPin.threeState == nil, outputPin.xFunction == nil, outputPin.stateFunction == nil,
                          let function = outputPin.function else {
                        throw Self.failure("control pulse path is not an admitted source buffer/inverter")
                    }
                    let input = cell.inputPins[0].name, arcs = cell.arcs(from: input, to: output)
                    guard arcs.count == 1, arcs[0].sense != .nonUnate,
                          try NativeSTAClockPropagation.functionSense(function, symbol: input,
                              sourceResources: resources, work: &work, limits: limits) == arcs[0].sense else {
                        throw Self.failure("control source function and timing polarity disagree")
                    }
                    chain.append(.init(instance: driver, input: input, output: output,
                        inputNet: inputNet, outputNet: cursor, arc: arcs[0]))
                    cursor = inputNet
                }
                used.insert(roots[cursor]!.sourcePort)
                for buffer in chain.reversed() {
                    if nets[buffer.outputNet] != nil { continue }
                    guard let upstream = nets[buffer.inputNet] else { throw Self.failure("missing control pulse predecessor") }
                    let name = design.instances[buffer.instance].name
                    let input = try receive(upstream, net: buffer.inputNet, sink: name + delimiter + buffer.input)
                    let load = loads[buffer.outputNet] ?? 0
                let earlyCellScale = conservative == nil ? variation.earlyCellDelayScale : min(variation.earlyCellDelayScale, variation.lateCellDelayScale)
                let lateCellScale = conservative == nil ? variation.lateCellDelayScale : max(variation.earlyCellDelayScale, variation.lateCellDelayScale)
                    func output(_ edge: TimingEdge) throws -> Event {
                        let incoming = input.event(buffer.arc.sense.inputEdge(for: edge)!)
                        let range = try conservative.map { _ in
                            try characterized.evaluatePropagation(cell: cells[buffer.instance].name, fromPin: buffer.input,
                                toPin: buffer.output, edge: edge,
                                inputSlew: NativeSTATimingBounds.slew(incoming.earlySlew, incoming.lateSlew), outputLoad: load...load)
                        }
                        let early = try characterized.evaluatePropagation(cell: cells[buffer.instance].name,
                            fromPin: buffer.input, toPin: buffer.output, edge: edge, inputSlew: incoming.earlySlew, outputLoad: load)
                        let late = try characterized.evaluatePropagation(cell: cells[buffer.instance].name,
                            fromPin: buffer.input, toPin: buffer.output, edge: edge, inputSlew: incoming.lateSlew, outputLoad: load)
                        for (sample, context, scale) in [(early, STASourceEvidence.Sample.Context.early, earlyCellScale),
                                                       (late, .late, lateCellScale)] {
                            _ = try evidence?.record(sample.delay, instance: name, context: context,
                                inputEdge: incoming.edge, outputEdge: edge, inputPoint: nil, receiver: name + delimiter + buffer.input,
                                scale: scale, rangeObservation: range?.delay, stateBudget: budget, limits: limits, work: &work)
                            _ = try evidence?.record(sample.outputSlew, instance: name, context: context,
                                inputEdge: incoming.edge, outputEdge: edge, inputPoint: nil, receiver: name + delimiter + buffer.input,
                                scale: 1, rangeObservation: range?.outputSlew, stateBudget: budget, limits: limits, work: &work)
                        }
                        let earlyDelay = try range.map { try NativeSTATimingBounds.scale($0.delay.result, by: earlyCellScale).lowerBound }
                            ?? early.delay.result * variation.earlyCellDelayScale
                        let lateDelay = try range.map { try NativeSTATimingBounds.scale($0.delay.result, by: lateCellScale).upperBound }
                            ?? late.delay.result * variation.lateCellDelayScale
                        return .init(edge: edge, rootEdge: incoming.rootEdge, rootPhase: incoming.rootPhase,
                            early: try range == nil ? incoming.early + earlyDelay : NativeSTATimingBounds.add(incoming.early, earlyDelay, upper: false),
                            late: try range == nil ? incoming.late + lateDelay : NativeSTATimingBounds.add(incoming.late, lateDelay, upper: true),
                            earlySlew: range?.outputSlew.result.lowerBound ?? early.outputSlew.result,
                            lateSlew: range?.outputSlew.result.upperBound ?? late.outputSlew.result,
                            segments: incoming.segments + [.init(physicalIdentity: "control-cell:" + name + ":" + edge.rawValue,
                                lateDelay: lateDelay, earlyDelay: earlyDelay)])
                    }
                    try charge(4); try budget.reserve(input.rise.segments.count + input.fall.segments.count + 4)
                    nets[buffer.outputNet] = try .init(source: input.source, rise: output(.rise), fall: output(.fall))
                }
                guard let upstream = nets[net] else { throw Self.failure("missing control pulse root") }
                let receiver = design.instances[index].name + delimiter + pin
                let received = try receive(upstream, net: net, sink: receiver)
                try budget.reserve(1); receivers[receiver] = (net, received)
            }
        }
        guard used == Set(sources.filter { $0.modeID == mode }.map(\.sourcePort)) else { throw Self.failure("unused explicit control pulse source") }
    }

    private static func failure(_ reason: String) -> TimingError {
        .unsupportedSemantic(format: "control pulse STA", semantic: reason)
    }
}

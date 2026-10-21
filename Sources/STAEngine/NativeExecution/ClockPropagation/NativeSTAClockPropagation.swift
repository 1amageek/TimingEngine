import LogicIR
import TimingCore

/// Scenario-local primary clock composition; every physical segment keeps its actual timing identity.
internal struct NativeSTAClockPropagation {
    private struct Buffer: Sendable { let instance: Int; let input: String; let output: String; let inputNet: String; let outputNet: String; let arc: TimingArc }
    private(set) var nets: [String: NativeSTAClockWave] = [:]
    private(set) var leaves: [String: NativeSTAClockWave] = [:]
    private(set) var instances: Set<Int> = []
    private(set) var observations: [STAClockObservation] = []
    private let stateBudget: NativeSTAStateBudget
    private let transformStorage: NativeSTATransformStorage
    private var transformFinished = false
    mutating func finishTransformRetention() throws -> NativeSTATransformRetention? {
        if !transformFinished {
            try transformStorage.hold((nets, leaves, instances, observations)); transformFinished = true
        }
        return try transformStorage.finish()
    }

    static func characterizationCells(design: TimingDesign, library: TimingLibrary, constraints: [TimingConstraintSet],
        plans: [Int: NativeSTASequentialExecution.Plan], resources: any LibertySourceResourceAccounting,
        delimiter: String, transformResources: (any LibertySourceResourceAccounting)? = nil) throws -> NativeSTAClockCharacterization {
        guard let control = transformResources else {
            let value = try legacyCharacterizationCells(design: design, library: library, constraints: constraints,
                plans: plans, resources: resources, delimiter: delimiter)
            return .init(buffers: value.buffers, sequential: value.sequential, receivers: value.receivers)
        }
        let storage = try NativeSTAClockCharacterization.Storage(resources: control, resultCapacity: design.instances.count)
        func step(_ count: Int = 1) throws { try storage.step(count) }
        var clockCount = 0
        for constraint in constraints {
            try step()
            let sum = clockCount.addingReportingOverflow(constraint.clocks.count)
            guard !sum.overflow else { throw LibertySourceError.arithmeticOverflow }; clockCount = sum.partialValue
        }
        try storage.scratch(TimingConstraintSet.Clock.self, count: clockCount)
        var clocks: [TimingConstraintSet.Clock] = []; clocks.reserveCapacity(clockCount)
        for constraint in constraints { for clock in constraint.clocks { try step(); clocks.append(clock) } }
        try storage.scratchSet(String.self, count: clockCount)
        try storage.scratchSet(String.self, count: clockCount)
        var roots = Set<String>(), selectedRoots = Set<String>()
        roots.reserveCapacity(clockCount); selectedRoots.reserveCapacity(clockCount)
        for clock in clocks {
            for port in design.ports { try step(); if port.name == clock.source {
                roots.insert(port.netName); if clock.isPropagated { selectedRoots.insert(port.netName) }; break
            } }
        }
        try storage.scratch(TimingCell.self, count: design.instances.count)
        var cells: [TimingCell] = []; cells.reserveCapacity(design.instances.count)
        var driverCount = 0
        for instance in design.instances {
            try step(); let cell = try library.cell(named: instance.cell); cells.append(cell)
            var outputs = 0
            for pin in cell.pins { try step(); if pin.direction == .output || pin.direction == .bidirectional { outputs += 1 } }
            let sum = driverCount.addingReportingOverflow(outputs)
            guard !sum.overflow else { throw LibertySourceError.arithmeticOverflow }; driverCount = sum.partialValue
        }
        try storage.scratchDictionary(String.self, Int.self, count: driverCount)
        try storage.scratchSet(String.self, count: design.instances.count)
        try storage.scratchSet(String.self, count: design.instances.count)
        var drivers: [String: Int] = [:], buffers = Set<String>(), sequential = Set<String>()
        drivers.reserveCapacity(driverCount); buffers.reserveCapacity(design.instances.count); sequential.reserveCapacity(design.instances.count)
        try storage.result((String, String).self, count: design.instances.count)
        var receivers: [(String, String)] = []; receivers.reserveCapacity(design.instances.count)
        for i in design.instances.indices { for pin in cells[i].pins where pin.direction == .output || pin.direction == .bidirectional {
            try step(); if let net = design.instances[i].connections[pin.name] { drivers[net] = i }
        } }
        for i in design.instances.indices {
            try step(); guard cells[i].sequentialModel != nil else { continue }
            guard let plan = plans[i] else { throw Self.unsupported("missing compiled clock/gate receiver") }
            let clockPin = plan.clockPin
            guard let net = design.instances[i].connections[clockPin] else { throw Self.unsupported("missing exact clock receiver binding") }
            let cone = try storage.coneStorage(count: driverCount)
            defer { withExtendedLifetime(cone) {} }
            var cursor = net, path: [String] = [], seen = Set<String>()
            let seenCapacity = driverCount.addingReportingOverflow(1)
            guard !seenCapacity.overflow else { throw LibertySourceError.arithmeticOverflow }
            path.reserveCapacity(driverCount); seen.reserveCapacity(seenCapacity.partialValue)
            while !roots.contains(cursor) {
                try resources.check(); try resources.chargeWork(UInt64(cursor.utf8.count) + 1); try step()
                guard seen.insert(cursor).inserted, let driver = drivers[cursor], cells[driver].sequentialModel == nil else { throw Self.unsupported("unresolved clock characterization cone") }
                for _ in cells[driver].pins { try step() }
                guard let unary = try Self.unaryPins(cells[driver], budget: nil),
                    let input = design.instances[driver].connections[unary.input.name] else { throw Self.unsupported("unresolved clock characterization cone") }
                path.append(cells[driver].name); cursor = input
            }
            if selectedRoots.contains(cursor) {
                for item in path { try step(); buffers.insert(item) }; sequential.insert(cells[i].name)
                var selected: TimingConstraintSet.Clock?
                for clock in clocks {
                    try step(); guard clock.isPropagated else { continue }
                    for port in design.ports { try step(); if port.name == clock.source { if port.netName == cursor { selected = clock }; break } }
                    if selected != nil { break }
                }
                guard let clock = selected else { throw Self.unsupported("missing primary clock") }
                let name = try storage.receiver(design.instances[i].name, delimiter: delimiter, pin: clockPin)
                receivers.append((clock.name, name))
            }
        }
        let bufferNames = try storage.sortedResult(buffers)
        let sequentialNames = try storage.sortedResult(sequential)
        return .init(buffers: bufferNames, sequential: sequentialNames, receivers: receivers, retention: storage.finish())
    }

    private static func legacyCharacterizationCells(design: TimingDesign, library: TimingLibrary, constraints: [TimingConstraintSet],
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
        transformStorage = NativeSTATransformStorage(budget: stateBudget, kind: .liveOwnedBytes)
        let scratch = NativeSTATransformStorage(budget: stateBudget, kind: .temporaryBytes)
        defer { withExtendedLifetime(scratch) {} }
        let selected = try scratch.filter(constraints.clocks, \.isPropagated)
        guard !selected.isEmpty else { return }
        guard let characterized else { throw Self.unsupported("missing retained strict clock characterization") }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Native propagated clocks have no generated-clock edge/ratio model.
        // This execution entrypoint must reject that profile until actual root/edge phase semantics are implemented and tested.
        guard constraints.generatedClocks.isEmpty else { throw Self.unsupported("generated clocks") }
        var outputCount = 0
        if stateBudget.transformResources != nil { for cell in cells {
            try stateBudget.chargeScheduledWork(1)
            var outputs = 0
            for pin in cell.pins { try stateBudget.chargeScheduledWork(1); if pin.direction == .output || pin.direction == .bidirectional { outputs += 1 } }
            let count = outputCount.addingReportingOverflow(outputs)
            guard !count.overflow else { throw LibertySourceError.arithmeticOverflow }; outputCount = count.partialValue
        } }
        let netCapacity = outputCount.addingReportingOverflow(design.ports.count)
        guard !netCapacity.overflow else { throw LibertySourceError.arithmeticOverflow }
        try transformStorage.reserveDictionary(String.self, NativeSTAClockWave.self, capacity: netCapacity.partialValue)
        try transformStorage.reserveDictionary(String.self, NativeSTAClockWave.self, capacity: design.instances.count)
        try transformStorage.reserveSet(Int.self, capacity: design.instances.count)
        try scratch.reserveDictionary(String.self, TimingConstraintSet.Clock.self, capacity: constraints.clocks.count)
        try scratch.reserveDictionary(String.self, Buffer.self, capacity: outputCount)
        try scratch.reserveDictionary(String.self, (Int, String).self, capacity: outputCount)
        try scratch.reserveSet(String.self, capacity: constraints.clocks.count)
        var roots: [String: TimingConstraintSet.Clock] = [:]
        if stateBudget.transformResources != nil {
            nets.reserveCapacity(netCapacity.partialValue); leaves.reserveCapacity(design.instances.count)
            instances.reserveCapacity(design.instances.count); roots.reserveCapacity(constraints.clocks.count)
        }
        var rootPublications: [NativeSTAConservativeWires.ClockPublication] = []
        for clock in constraints.clocks {
            try stateBudget.chargeScheduledWork(1)
            guard let port = try design.ports.first(where: { try stateBudget.chargeScheduledWork(1); return $0.name == clock.source }), roots[port.netName] == nil else { throw Self.unsupported("ambiguous clock source") }
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
                    try scratch.append(NativeSTAConservativeWires.ClockPublication(net: port.netName, wave: wave), to: &rootPublications)
                }
            }
        }
        if !rootPublications.isEmpty { try conservative!.publishClockHistories(rootPublications, work: &work) }
        let observationSite = #line
        var pendingBuffers: [String: Buffer] = [:]
        var pendingLeaves: [(instance: Int, net: String, pin: String, clock: TimingConstraintSet.Clock)] = []
        var drivers: [String: (Int, String)] = [:]
        if stateBudget.transformResources != nil {
            pendingBuffers.reserveCapacity(outputCount); drivers.reserveCapacity(outputCount)
        }
        for i in design.instances.indices {
            try stateBudget.chargeScheduledWork(1)
            for pin in cells[i].pins where pin.direction == .output || pin.direction == .bidirectional {
                try stateBudget.chargeScheduledWork(1)
                if let net = design.instances[i].connections[pin.name] {
                    guard drivers[net] == nil else { throw Self.unsupported("multiple clock drivers") }
                    drivers[net] = (i, pin.name)
                }
            }
        }
        var usedRoots = Set<String>()
        if stateBudget.transformResources != nil { usedRoots.reserveCapacity(constraints.clocks.count) }
        for i in design.instances.indices {
            try stateBudget.chargeScheduledWork(1)
            guard cells[i].sequentialModel != nil else { continue }
            guard let plan = sequentialPlans[i] else { throw Self.unsupported("missing compiled clock/gate receiver") }
            let clockPin = plan.clockPin
            guard let clockNet = design.instances[i].connections[clockPin] else { throw Self.unsupported("missing exact clock receiver binding") }
            try sourceResources?.check()
            let coneStorage = NativeSTATransformStorage(budget: stateBudget, kind: .temporaryBytes)
            defer { withExtendedLifetime(coneStorage) {} }
            let seenCapacity = outputCount.addingReportingOverflow(1)
            guard !seenCapacity.overflow else { throw LibertySourceError.arithmeticOverflow }
            try coneStorage.reserveSet(String.self, capacity: seenCapacity.partialValue)
            var chain: [Buffer] = [], visited = Set<String>(), cursor = clockNet
            if stateBudget.transformResources != nil { visited.reserveCapacity(seenCapacity.partialValue) }
            while roots[cursor] == nil {
                try sourceResources?.check()
                try Self.charge(1, work: &work, limits: limits, budget: stateBudget)
                guard visited.insert(cursor).inserted, let (driver, output) = drivers[cursor], cells[driver].sequentialModel == nil else {
                    throw Self.unsupported("clock loop, sequential driver or missing primary root")
                }
                let cell = cells[driver], instance = design.instances[driver]
                let unary = try Self.unaryPins(cell, budget: stateBudget)
                // FIXME(INCOMPLETE_IMPLEMENTATION): This production clock cone supports only source-backed buffers/inverters.
                // Gated or multiinput clock behavior must remain unsupported until its conditional edge/control semantics are implemented and tested.
                guard let unary, unary.output.name == output,
                      let inputNet = instance.connections[unary.input.name] else { throw Self.unsupported("gated/multiinput clock profile") }
                let input = unary.input.name
                let arcStorage = NativeSTATransformStorage(budget: stateBudget, kind: .temporaryBytes)
                defer { withExtendedLifetime(arcStorage) {} }
                let arcs = try arcStorage.filter(cell.arcs) { $0.fromPin == input && $0.toPin == output && !$0.isConstraint }
                guard arcs.count == 1, arcs[0].sense != .nonUnate,
                      let facts = try source.cells.first(where: { try stateBudget.chargeScheduledWork(1); return $0.name == cell.name }), facts.sequential.isEmpty,
                      facts.unsupportedFunctionalGroups.isEmpty,
                      let pin = try facts.pins.first(where: { try stateBudget.chargeScheduledWork(1); return $0.name == output }), pin.threeState == nil, pin.xFunction == nil, pin.stateFunction == nil,
                      let function = pin.function else { throw Self.unsupported("uncharacterized/ambiguous clock buffer") }
                let sense = try Self.functionSense(function, symbol: input, sourceResources: sourceResources, work: &work, limits: limits, budget: stateBudget)
                guard sense == arcs[0].sense else { throw Self.unsupported("clock function/timing polarity mismatch") }
                guard chain.count < limits.maximumPathStates else { throw STAPathAnalysisError.capacity(resource: "clock topology", limit: UInt64(limits.maximumPathStates)) }
                try coneStorage.append(Buffer(instance: driver, input: input, output: output, inputNet: inputNet, outputNet: cursor, arc: arcs[0]), to: &chain); cursor = inputNet
            }
            let clock = roots[cursor]!
            guard clock.isPropagated else {
                if rc?.contains(clockNet) == true || conservative?.contains(clockNet) == true || !chain.isEmpty { throw Self.unsupported("finite-R/buffered clock lacks explicit propagated source") }
                continue
            }
            usedRoots.insert(clock.name)
            guard let declaration = try source.cells.first(where: { try stateBudget.chargeScheduledWork(1); return $0.name == cells[i].name }), plan.declaration != nil else {
                throw Self.unsupported("missing exact sequential source clock/gate plan")
            }
            guard try normalPowerValidated || (declaration.sequential.allSatisfy { try stateBudget.chargeScheduledWork(1); return $0.powerDownFunction == nil }
                && declaration.pins.allSatisfy { try stateBudget.chargeScheduledWork(1); return $0.powerDownFunction == nil }) else {
                throw Self.unsupported("clock receiver requires explicit normal-power conditions")
            }
            for output in plan.outputs where design.instances[i].connections[output.pin] != nil {
                let arcStorage = NativeSTATransformStorage(budget: stateBudget, kind: .temporaryBytes)
                defer { withExtendedLifetime(arcStorage) {} }
                let arcs = try arcStorage.filter(cells[i].arcs) { $0.fromPin == clockPin && $0.toPin == output.pin && !$0.isConstraint }
                guard arcs.count == 1, let identity = arcs[0].sourceIdentity,
                      identity.timingType == (plan.activeEdge == .rise ? "rising_edge" : "falling_edge") else {
                    throw Self.unsupported("missing exact clock/gate-to-output source arc")
                }
            }
            if conservative != nil {
                for buffer in chain {
                    try Self.charge(1, work: &work, limits: limits, budget: stateBudget)
                    if pendingBuffers[buffer.outputNet] == nil { try stateBudget.reserve(1) }
                    pendingBuffers[buffer.outputNet] = buffer
                }
                try stateBudget.reserve(1)
                try scratch.append((i, clockNet, clockPin, clock), to: &pendingLeaves)
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
            let receiver = try transformStorage.joined(design.instances[i].name, delimiter, clockPin)
            let leaf = try receive(upstream, net: clockNet, sink: receiver, variation: variation, limits: limits, rc: &rc, conservative: &conservative, work: &work)
            try stateBudget.reserve(3)
            leaves[design.instances[i].name] = leaf
            for edgeIndex in 0..<2 {
                let event = edgeIndex == 0 ? leaf.rise : leaf.fall
                try transformStorage.append(STAClockObservation(modeID: mode, cornerID: corner, receiver: receiver, rootClock: clock.name,
                    edge: event.edge, rootEdge: event.rootEdge, rootPhase: event.rootPhase, period: clock.period,
                    lateArrival: event.late, earlyArrival: event.early, lateSlew: event.lateSlew, earlySlew: event.earlySlew, segments: event.segments), to: &observations, site: observationSite)
            }
        }
        while !pendingBuffers.isEmpty {
            try sourceResources?.check()
            try Self.charge(1, work: &work, limits: limits, budget: stateBudget)
            try stateBudget.reserve(pendingBuffers.count)
            let frontierStorage = NativeSTATransformStorage(budget: stateBudget, kind: .temporaryBytes)
            defer { withExtendedLifetime(frontierStorage) {} }
            var frontier: [Buffer] = []
            for index in design.instances.indices {
                try sourceResources?.check()
                try Self.charge(1, work: &work, limits: limits, budget: stateBudget)
                for pin in cells[index].pins where pin.direction == .output || pin.direction == .bidirectional {
                    try Self.charge(UInt64(pin.name.utf8.count) + 1, work: &work, limits: limits, budget: stateBudget)
                    guard let net = design.instances[index].connections[pin.name] else { continue }
                    try Self.charge(UInt64(net.utf8.count), work: &work, limits: limits, budget: stateBudget)
                    if let buffer = pendingBuffers[net], nets[buffer.inputNet] != nil { try frontierStorage.append(buffer, to: &frontier) }
                }
            }
            guard !frontier.isEmpty else { throw Self.unsupported("unresolved checked clock frontier") }
            try stateBudget.reserve(frontier.count)
            var publications: [NativeSTAConservativeWires.ClockPublication] = []
            for buffer in frontier {
                try Self.charge(1, work: &work, limits: limits, budget: stateBudget)
                let wave = try bufferWave(buffer, design: design, cells: cells, loads: loads,
                    characterized: characterized, sourceEvidence: &sourceEvidence, sourceResources: sourceResources,
                    variation: variation, limits: limits, delimiter: delimiter, rc: &rc, conservative: &conservative, work: &work)
                guard let load = loads[buffer.outputNet], let identity = buffer.arc.sourceIdentity else {
                    throw Self.unsupported("missing checked clock source load/identity")
                }
                try frontierStorage.append(NativeSTAConservativeWires.ClockPublication(net: buffer.outputNet, wave: wave, load: load, sourceIdentity: identity), to: &publications)
            }
            // Every wave above was proved with the previous complete source history.
            try conservative!.publishClockHistories(publications, work: &work)
            try stateBudget.reserve(publications.count)
            for publication in publications {
                try Self.charge(1, work: &work, limits: limits, budget: stateBudget)
                nets[publication.net] = publication.wave
            }
            for buffer in frontier {
                try Self.charge(1, work: &work, limits: limits, budget: stateBudget)
                try stateBudget.reserve(1); instances.insert(buffer.instance)
                pendingBuffers.removeValue(forKey: buffer.outputNet)
            }
        }
        for pending in pendingLeaves {
            try Self.charge(1, work: &work, limits: limits, budget: stateBudget)
            guard let upstream = nets[pending.net] else { throw Self.unsupported("missing FF clock predecessor") }
            let receiver = try transformStorage.joined(design.instances[pending.instance].name, delimiter, pending.pin)
            let leaf = try receive(upstream, net: pending.net, sink: receiver, variation: variation,
                limits: limits, rc: &rc, conservative: &conservative, work: &work)
            try stateBudget.reserve(3)
            leaves[design.instances[pending.instance].name] = leaf
            for edgeIndex in 0..<2 {
                let event = edgeIndex == 0 ? leaf.rise : leaf.fall
                try transformStorage.append(STAClockObservation(modeID: mode, cornerID: corner, receiver: receiver, rootClock: pending.clock.name,
                    edge: event.edge, rootEdge: event.rootEdge, rootPhase: event.rootPhase, period: pending.clock.period,
                    lateArrival: event.late, earlyArrival: event.early, lateSlew: event.lateSlew,
                    earlySlew: event.earlySlew, segments: event.segments), to: &observations, site: observationSite)
            }
        }
        let selectedNames = try scratch.map(selected) { $0.name }
        try scratch.reserveSet(String.self, capacity: selectedNames.count)
        guard usedRoots == Set(selectedNames) else { throw Self.unsupported("propagated clock without actual FF receiver") }
        for i in design.instances.indices {
            try stateBudget.chargeScheduledWork(1)
            for pin in cells[i].pins where pin.direction == .input || pin.direction == .bidirectional {
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
                try Self.charge(1, work: &work, limits: limits, budget: stateBudget)
                try scratch.append((pending.instance, pending.clock.period), to: &checked)
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
        let input = try receive(upstream, net: buffer.inputNet, sink: try transformStorage.joined(name, delimiter, buffer.input),
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
            let receiver = try transformStorage.joined(name, delimiter, buffer.input)
                _ = try sourceEvidence?.record(lateSample.delay, instance: name, context: .late,
                    inputEdge: incoming.edge, outputEdge: edge, inputPoint: nil, receiver: receiver,
                    scale: lateCellScale, rangeObservation: range?.delay, stateBudget: stateBudget, limits: limits, work: &work)
                _ = try sourceEvidence?.record(lateSample.outputSlew, instance: name, context: .late,
                    inputEdge: incoming.edge, outputEdge: edge, inputPoint: nil, receiver: receiver,
                    scale: 1, rangeObservation: range?.outputSlew, stateBudget: stateBudget, limits: limits, work: &work)
                _ = try sourceEvidence?.record(earlySample.delay, instance: name, context: .early,
                    inputEdge: incoming.edge, outputEdge: edge, inputPoint: nil, receiver: receiver,
                    scale: earlyCellScale, rangeObservation: range?.delay, stateBudget: stateBudget, limits: limits, work: &work)
                _ = try sourceEvidence?.record(earlySample.outputSlew, instance: name, context: .early,
                    inputEdge: incoming.edge, outputEdge: edge, inputPoint: nil, receiver: receiver,
                    scale: 1, rangeObservation: range?.outputSlew, stateBudget: stateBudget, limits: limits, work: &work)
            let late = try range.map { try NativeSTATimingBounds.scale($0.delay.result, by: lateCellScale).upperBound }
                ?? lateSample.delay.result * variation.lateCellDelayScale
            let early = try range.map { try NativeSTATimingBounds.scale($0.delay.result, by: earlyCellScale).lowerBound }
                ?? earlySample.delay.result * variation.earlyCellDelayScale
            let lateSlew = range?.outputSlew.result.upperBound ?? lateSample.outputSlew.result
            let earlySlew = range?.outputSlew.result.lowerBound ?? earlySample.outputSlew.result
            guard late.isFinite, early.isFinite, lateSlew.isFinite, earlySlew.isFinite, lateSlew > 0, earlySlew > 0 else { throw Self.unsupported("invalid characterized clock arc") }
            let appended = try Self.appendSegment(incoming.segments, text: incoming.textRetention,
                prefix: "cell:", first: name, second: buffer.input, third: buffer.output, edge: edge,
                late: late, early: early, budget: stateBudget)
            return .init(clock: incoming.clock, edge: edge, rootEdge: incoming.rootEdge, rootPhase: incoming.rootPhase,
                late: try range == nil ? incoming.late + late : NativeSTATimingBounds.add(incoming.late, late, upper: true),
                early: try range == nil ? incoming.early + early : NativeSTATimingBounds.add(incoming.early, early, upper: false), lateSlew: lateSlew, earlySlew: earlySlew,
                segments: appended.segments, segmentPayload: appended.payload, textRetention: appended.text)
        }
        try Self.charge(2, work: &work, limits: limits, budget: stateBudget)
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
                let appended = try Self.appendSegment(input.segments, text: input.textRetention,
                    prefix: "wire:", first: net, second: sink, edge: edge, late: late, early: early, budget: stateBudget)
                return .init(clock: input.clock, edge: edge, rootEdge: input.rootEdge, rootPhase: input.rootPhase,
                    late: try NativeSTATimingBounds.add(input.late, late, upper: true),
                    early: try NativeSTATimingBounds.add(input.early, early, upper: false),
                    lateSlew: result.slew.upperBound, earlySlew: result.slew.lowerBound,
                    segments: appended.segments, segmentPayload: appended.payload, textRetention: appended.text)
            }
            try stateBudget.reserve(wave.rise.segments.count + wave.fall.segments.count + 4)
            return try .init(rise: event(.rise), fall: event(.fall))
        }
        guard rc != nil else { throw Self.unsupported("missing wire timing model") }
        let late = try rc!.periodicResponse(net: net, sink: sink, source: wave.lateSource, work: &work)
        let early = try rc!.periodicResponse(net: net, sink: sink, source: wave.earlySource, work: &work)
        func event(_ edge: TimingEdge) throws -> NativeSTAClockEvent {
            let incoming = wave.event(edge)
            let lateDelay = (edge == .rise ? late.riseDelay : late.fallDelay) * variation.lateInterconnectDelayScale
            let earlyDelay = (edge == .rise ? early.riseDelay : early.fallDelay) * variation.earlyInterconnectDelayScale
            let appended = try Self.appendSegment(incoming.segments, text: incoming.textRetention,
                prefix: "wire:", first: net, second: sink, edge: edge, late: lateDelay, early: earlyDelay, budget: stateBudget)
            return .init(clock: incoming.clock, edge: edge, rootEdge: incoming.rootEdge, rootPhase: incoming.rootPhase,
                late: incoming.late + lateDelay, early: incoming.early + earlyDelay,
                lateSlew: edge == .rise ? late.riseSlew : late.fallSlew, earlySlew: edge == .rise ? early.riseSlew : early.fallSlew,
                segments: appended.segments, segmentPayload: appended.payload, textRetention: appended.text)
        }
        try stateBudget.reserve(wave.rise.segments.count + wave.fall.segments.count + 4)
        return try NativeSTAClockWave(rise: event(.rise), fall: event(.fall))
    }
    static func unaryPins(_ cell: TimingCell, budget: NativeSTAStateBudget?) throws -> (input: TimingPin, output: TimingPin)? {
        var input: TimingPin?, output: TimingPin?
        var inputs = 0, outputs = 0
        for pin in cell.pins {
            try budget?.chargeScheduledWork(1)
            if pin.direction == .input || pin.direction == .bidirectional { input = pin; inputs += 1 }
            if pin.direction == .output || pin.direction == .bidirectional { output = pin; outputs += 1 }
        }
        guard inputs == 1, outputs == 1, let input, let output else { return nil }; return (input, output)
    }

    static func appendSegment(_ previous: [STAClockObservation.Segment], text: NativeSTATransformRetention?,
        prefix: String, first: String, second: String? = nil, third: String? = nil, edge: TimingEdge,
        late: Double, early: Double, budget: NativeSTAStateBudget) throws
        -> (segments: [STAClockObservation.Segment], payload: LibertySourceStorageReservation?, text: NativeSTATransformRetention?) {
        let count = previous.count.addingReportingOverflow(1)
        guard !count.overflow else { throw LibertySourceError.arithmeticOverflow }
        let payload = try budget.reservePayload(STAClockObservation.Segment.self, capacity: count.partialValue, kind: .liveOwnedBytes)
        let names = NativeSTATransformStorage(budget: budget, kind: .liveOwnedBytes)
        try names.hold(text)
        var bytes = prefix.utf8.count
        func add(_ value: String) throws {
            let sum = bytes.addingReportingOverflow(value.utf8.count)
            guard !sum.overflow else { throw LibertySourceError.arithmeticOverflow }; bytes = sum.partialValue
        }
        try add(first); try add(":"); try add(edge.rawValue)
        if let second { try add(":"); try add(second) }
        if let third { try add(":"); try add(third) }
        try names.reserve(UInt8.self, capacity: bytes); try budget.chargeScheduledWork(UInt64(bytes))
        var identity = String(); identity.reserveCapacity(bytes)
        identity.append(prefix); identity.append(first)
        if let second { identity.append(":"); identity.append(second) }
        if let third { identity.append(":"); identity.append(third) }
        identity.append(":"); identity.append(edge.rawValue)
        try names.hold(identity)
        var segments: [STAClockObservation.Segment] = []; segments.reserveCapacity(count.partialValue)
        for segment in previous { try budget.chargeScheduledWork(1); segments.append(segment) }
        try budget.chargeScheduledWork(1)
        segments.append(.init(physicalIdentity: identity, lateDelay: late, earlyDelay: early))
        return (segments, payload, try names.finish())
    }

    static func functionSense(_ function: LibertySourceFunction, symbol: String, sourceResources: (any LibertySourceResourceAccounting)?, work: inout UInt64,
                                      limits: STAExecutionLimits, budget: NativeSTAStateBudget? = nil) throws -> TimingSense {
        guard case .normalized(let facts) = function.content, facts.symbols.count == 1, facts.symbols.first == symbol,
              facts.operations.count <= limits.maximumPathStates else { throw unsupported("unsupported clock function") }
        var first = false, second = false
        for inputIndex in 0..<2 {
            let input = inputIndex != 0
            let payload = try budget?.reservePayload(Bool.self, capacity: facts.operations.count, kind: .temporaryBytes)
            defer { withExtendedLifetime(payload) {} }
            var values: [Bool] = []; values.reserveCapacity(facts.operations.count)
            func prior(_ index: LogicBooleanNodeIndex) throws -> Bool {
                guard values.indices.contains(index.rawValue) else { throw unsupported("invalid clock function edge") }; return values[index.rawValue]
            }
            for operation in facts.operations {
                try sourceResources?.check()
                try charge(1, work: &work, limits: limits, budget: budget)
                switch operation {
                case .constant(let value): values.append(value)
                case .input(let slot): guard slot == 0 else { throw unsupported("invalid clock function symbol") }; values.append(input)
                case .invert(let a): values.append(try !prior(a))
                case .and(let a, let b): values.append(try prior(a) && prior(b))
                case .or(let a, let b): values.append(try prior(a) || prior(b))
                case .xor(let a, let b): values.append(try prior(a) != prior(b))
                }
            }
            if inputIndex == 0 { first = try prior(facts.output) } else { second = try prior(facts.output) }
        }
        guard first != second else { throw unsupported("constant clock function") }
        return first ? .negativeUnate : .positiveUnate
    }
    private static func charge(_ amount: UInt64, work: inout UInt64, limits: STAExecutionLimits, budget: NativeSTAStateBudget? = nil) throws {
        try Task.checkCancellation()
        let sum = work.addingReportingOverflow(amount)
        guard !sum.overflow, sum.partialValue <= limits.maximumPathWorkUnits else { throw STAPathAnalysisError.capacity(resource: "clock path work", limit: limits.maximumPathWorkUnits) }
        try budget?.chargeScheduledWork(amount)
        work = sum.partialValue
    }
    private static func unsupported(_ semantic: String) -> TimingError { .unsupportedSemantic(format: "propagated clock STA", semantic: semantic) }
}

import TimingCore

/// Canonical source authority and invocation-local query receipts for the coupled solver.
internal struct NativeSTAConservativeWires {
    private struct Query: Hashable {
        let net: String
        let sink: String
        let edge: TimingEdge
        let lower: UInt64
        let upper: UInt64
        let generation: UInt64
    }
    struct ClockPublication {
        let net: String
        let wave: NativeSTAClockWave
        let load: Double?
        let sourceIdentity: LibertyTimingSourceIdentity?
        init(net: String, wave: NativeSTAClockWave, load: Double? = nil,
             sourceIdentity: LibertyTimingSourceIdentity? = nil) {
            self.net = net; self.wave = wave; self.load = load; self.sourceIdentity = sourceIdentity
        }
    }
    private struct Driver {
        let endpoint: TimingParasitics.Endpoint
        let authorityIndex: Int
        let instance: Int?
        let pin: String
    }
    private var cached: [Query: Int] = [:]
    private let limits: STAExecutionLimits
    private let resources: (any LibertySourceResourceAccounting)?
    private let declaredClocks: [TimingConstraintSet.Clock]
    private let thresholds: TimingCharacterizationThresholds
    private let solver = NativeSTAConservativeCoupling()
    private var prepared: NativeSTAConservativeCoupling.Prepared
    private let drivers: [String: Driver]
    private let mode: String
    private let corner: String
    private let budget: NativeSTAStateBudget
    private var sourceAuthorities: [STAConservativeSourceAuthority]
    private var historyGeneration: UInt64 = 0
    private var provedClockPeriods: [Int: Double] = [:]
    private(set) var observations: [STAConservativeWireObservation] = []

    private struct InitialSources {
        let thresholds: TimingCharacterizationThresholds
        let drivers: [String: Driver]
        let sources: [NativeSTAConservativeCoupling.Source]
        let receiverLoads: [TimingParasitics.Endpoint: Double]
        let authorities: [STAConservativeSourceAuthority]
        let roots: [TimingParasitics.Endpoint: STAConservativeSourceContextRecord.Clock]
    }

    private static func cellDomain(index: Int, output: String, load: Double,
        inputDomains: [String: ClosedRange<Double>]?, recordIdentities: Bool,
        identities: inout [LibertyTimingSourceIdentity], design: TimingDesign, cells: [TimingCell],
        characterized: CharacterizedTimingLibrary, constants: [String: TimingDesign.Constant],
        limits: STAExecutionLimits, budget: NativeSTAStateBudget,
        resources: (any LibertySourceResourceAccounting)?, work: inout UInt64
    ) throws -> (rise: ClosedRange<Double>, fall: ClosedRange<Double>)? {
        func charge() throws {
            try NativeSTASequentialExecution.charge(1, work: &work, limits: limits, sourceResources: resources)
        }
        let cell = cells[index]
        var riseDomain: ClosedRange<Double>?, fallDomain: ClosedRange<Double>?
        for arc in cell.arcs {
            try charge()
            guard !arc.isConstraint, arc.toPin == output else { continue }
            guard let identity = arc.sourceIdentity else { throw TimingError.invalidInput("Missing characterized driver source identity") }
            let fullInput = Self.covering(Self.covering(Self.inputDomain(arc.delayRise), Self.inputDomain(arc.delayFall)),
                Self.covering(Self.inputDomain(arc.transitionRise), Self.inputDomain(arc.transitionFall)))
            guard let input = inputDomains == nil ? fullInput : inputDomains?[arc.fromPin] else { return nil }
            for edge in [TimingEdge.rise, .fall] {
                try charge()
                let sample = try characterized.evaluatePropagation(cell: cell.name, fromPin: arc.fromPin,
                    toPin: arc.toPin, edge: edge, inputSlew: input, outputLoad: load...load)
                guard sample.outputSlew.source == identity else {
                    throw TimingError.invalidInput("Mismatched characterized driver source identity")
                }
                try Self.requirePositive(sample.outputSlew.result)
                if edge == .rise {
                    riseDomain = riseDomain.map { Self.covering($0, sample.outputSlew.result) } ?? sample.outputSlew.result
                } else {
                    fallDomain = fallDomain.map { Self.covering($0, sample.outputSlew.result) } ?? sample.outputSlew.result
                }
            }
            if recordIdentities { try budget.reserve(1); identities.append(identity) }
        }
        for arc in try characterized.directionalControlArcs(cell: cell.name) {
            try charge()
            guard arc.toPin == output else { continue }
            if let controlNet = design.instances[index].connections[arc.fromPin], constants[controlNet] != nil { continue }
            if inputDomains != nil && inputDomains?[arc.fromPin] == nil { return nil }
            let identity = arc.sourceIdentity
            var hasDirection = false
            for edge in [TimingEdge.rise, .fall] {
                try charge()
                let delay = edge == .rise ? arc.delayRise : arc.delayFall
                let transition = edge == .rise ? arc.transitionRise : arc.transitionFall
                guard (delay == nil) == (transition == nil) else {
                    throw TimingCharacterizationError.missingSourceFact("directional transition slope authority")
                }
                guard let delay, let transition else { continue }
                hasDirection = true
                let sample = try characterized.evaluateDirectionalControl(cell: cell.name,
                    fromPin: arc.fromPin, toPin: arc.toPin, kind: arc.kind, outputEdge: edge,
                    sourceIdentity: identity,
                    inputSlew: inputDomains?[arc.fromPin] ?? Self.covering(Self.inputDomain(delay), Self.inputDomain(transition)),
                    outputLoad: load...load)
                try Self.requirePositive(sample.outputSlew.result)
                if edge == .rise {
                    riseDomain = riseDomain.map { Self.covering($0, sample.outputSlew.result) } ?? sample.outputSlew.result
                } else {
                    fallDomain = fallDomain.map { Self.covering($0, sample.outputSlew.result) } ?? sample.outputSlew.result
                }
            }
            guard hasDirection else {
                throw TimingCharacterizationError.missingSourceFact("directional transition slope authority")
            }
            if recordIdentities { try budget.reserve(1); identities.append(identity) }
        }
        guard let riseDomain, let fallDomain else { throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "unknown cell output-edge transition domain") }
        return (riseDomain, fallDomain)
    }

    private static func initialSources(options: STAConservativeCoupledRCOptions, design: TimingDesign, cells: [TimingCell],
         source: OwnedLibertySource, characterized: CharacterizedTimingLibrary,
         constraints: TimingConstraintSet, pulseSources: [STAControlPulseSource],
         constants: [String: TimingDesign.Constant], loads: [String: Double], parasitics: TimingParasitics,
         limits: STAExecutionLimits, budget: NativeSTAStateBudget,
         resources: (any LibertySourceResourceAccounting)?, mode: String, corner: String,
         work: inout UInt64, includeRootHistories: Bool = false) throws -> InitialSources {
        guard let thresholds = source.thresholds, !source.hasPinThresholdOverrides,
              parasitics.hasDistributedTopology else {
            throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "exact topology and common source thresholds required")
        }
        var drivers: [String: Driver] = [:]
        var sources: [NativeSTAConservativeCoupling.Source] = []
        var receiverLoads: [TimingParasitics.Endpoint: Double] = [:]
        var authorities: [STAConservativeSourceAuthority] = []
        var roots: [TimingParasitics.Endpoint: STAConservativeSourceContextRecord.Clock] = [:]
        func charge(_ amount: UInt64 = 1) throws {
            try NativeSTASequentialExecution.charge(amount, work: &work, limits: limits, sourceResources: resources)
        }
        func cellDomain(index: Int, output: String, load: Double,
            inputDomains: [String: ClosedRange<Double>]?, recordIdentities: Bool,
            identities: inout [LibertyTimingSourceIdentity]) throws -> (rise: ClosedRange<Double>, fall: ClosedRange<Double>)? {
            try Self.cellDomain(index: index, output: output, load: load, inputDomains: inputDomains,
                recordIdentities: recordIdentities, identities: &identities, design: design, cells: cells,
                characterized: characterized, constants: constants, limits: limits, budget: budget,
                resources: resources, work: &work)
        }
        for network in parasitics.networks {
            try charge()
            for net in design.nets {
                try charge()
                if net.name == network.name {
                    guard net.capacitance == 0 else {
                        throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "unattached canonical capacitance")
                    }
                    break
                }
            }
            var candidate: (endpoint: TimingParasitics.Endpoint, isPort: Bool, instance: Int?, pin: String)?
            for port in design.ports {
                try charge()
                guard port.netName == network.name else { continue }
                try budget.reserve(1)
                let endpoint = TimingParasitics.Endpoint(name: port.name, ownerNet: network.name)
                if port.direction != .output {
                    guard candidate == nil else {
                        throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "unique exact canonical driver required for " + network.name)
                    }
                    candidate = (endpoint, true, nil, port.name)
                }
                if port.direction != .input {
                    if receiverLoads[endpoint] == nil { try budget.reserve(1) }
                    receiverLoads[endpoint] = 0
                }
            }
            for index in design.instances.indices {
                try charge()
                for pin in cells[index].pins {
                    try charge()
                    guard design.instances[index].connections[pin.name] == network.name else { continue }
                    try budget.reserve(1)
                    try charge(UInt64(design.instances[index].name.utf8.count))
                    try charge(UInt64(parasitics.pinDelimiter.utf8.count))
                    try charge(UInt64(pin.name.utf8.count))
                    let endpoint = TimingParasitics.Endpoint(name: design.instances[index].name + parasitics.pinDelimiter + pin.name, ownerNet: network.name)
                    if pin.direction == .output {
                        guard candidate == nil else {
                            throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "unique exact canonical driver required for " + network.name)
                        }
                        candidate = (endpoint, false, index, pin.name)
                    } else if pin.direction == .input {
                        if receiverLoads[endpoint] == nil { try budget.reserve(1) }
                        receiverLoads[endpoint] = pin.capacitance
                    } else {
                        throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "bidirectional driver or receiver")
                    }
                }
            }
            guard let driver = candidate else {
                throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "unique exact canonical driver required for " + network.name)
            }
            var connected = false
            for endpoint in network.connections {
                try charge()
                if endpoint == driver.endpoint { connected = true; break }
            }
            guard connected else {
                throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "exact canonical driver connection required for " + network.name)
            }
            // The dictionary entry, source record and authority record are admitted before any grows.
            try budget.reserve(3)
            drivers[network.name] = .init(endpoint: driver.endpoint, authorityIndex: authorities.count,
                instance: driver.instance, pin: driver.pin)
            if let constant = constants[network.name] {
                let voltage = constant == .one ? 1.0 : 0.0
                sources.append(.constant(endpoint: driver.endpoint, voltage: voltage))
                authorities.append(.init(endpoint: driver.endpoint, sourceIsPort: driver.isPort, constantVoltage: voltage,
                    riseSlew: nil, fallSlew: nil, sourceArcs: [], prescribedBoundaryLoad: driver.isPort ? nil : loads[network.name]))
                continue
            }
            let rise: ClosedRange<Double>, fall: ClosedRange<Double>
            var identities: [LibertyTimingSourceIdentity] = []
            if driver.isPort {
                var clock: TimingConstraintSet.Clock?
                for selected in constraints.clocks {
                    try charge()
                    if selected.source == driver.pin { clock = selected; break }
                }
                if let clock {
                    guard clock.hasValidPropagatedSource, let r = clock.sourceRiseTransition, let f = clock.sourceFallTransition else {
                        throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "explicit clock transitions required")
                    }
                    rise = r...r; fall = f...f
                    if includeRootHistories {
                        try charge(); try budget.reserve(1)
                        roots[driver.endpoint] = .init(rootIdentity: clock.name, period: clock.period,
                            riseReference: clock.waveform[0]...clock.waveform[0],
                            fallReference: clock.waveform[1]...clock.waveform[1])
                    }
                } else {
                    var pulse: STAControlPulseSource?
                    for selected in pulseSources {
                        try charge()
                        if selected.modeID == mode && selected.sourcePort == driver.pin { pulse = selected; break }
                    }
                    if let pulse {
                        rise = pulse.riseTransition...pulse.riseTransition; fall = pulse.fallTransition...pulse.fallTransition
                        if includeRootHistories {
                            try charge(); try budget.reserve(1)
                            roots[driver.endpoint] = .init(rootIdentity: pulse.referenceClock, period: pulse.period,
                                riseReference: pulse.risePhase...pulse.risePhase,
                                fallReference: pulse.fallPhase...pulse.fallPhase)
                        }
                    } else {
                        guard case .allInputsBothEdges(let value)? = constraints.inputTransition,
                              value == constraints.defaultInputSlew, value.isFinite, value > 0 else {
                            throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "positive explicit primary input transition required")
                        }
                        rise = value...value; fall = value...value
                    }
                }
            } else {
                guard let index = driver.instance else { throw TimingError.invariantViolation("Missing canonical cell driver") }
                guard let load = loads[network.name], load.isFinite, load >= 0 else {
                    throw TimingError.invalidInput("Missing finite prescribed cell source load")
                }
                guard let domain = try cellDomain(index: index, output: driver.pin, load: load,
                    inputDomains: nil, recordIdentities: true, identities: &identities) else {
                    throw TimingError.invariantViolation("Missing initial cell source domain")
                }
                rise = domain.rise; fall = domain.fall
            }
            sources.append(.dynamic(endpoint: driver.endpoint, sourceIsPort: driver.isPort, riseSlew: rise, fallSlew: fall))
            authorities.append(.init(endpoint: driver.endpoint, sourceIsPort: driver.isPort, constantVoltage: nil,
                riseSlew: rise, fallSlew: fall, sourceArcs: identities, prescribedBoundaryLoad: driver.isPort ? nil : loads[network.name]))
        }
        return InitialSources(thresholds: thresholds, drivers: drivers, sources: sources,
            receiverLoads: receiverLoads, authorities: authorities, roots: roots)
    }

    static func initialContext(options: STAConservativeCoupledRCOptions, design: TimingDesign, cells: [TimingCell],
        source: OwnedLibertySource, characterized: CharacterizedTimingLibrary, constraints: TimingConstraintSet,
        pulseSources: [STAControlPulseSource], constants: [String: TimingDesign.Constant], loads: [String: Double],
        parasitics: TimingParasitics, mode: String, corner: String,
        binding: STAConservativeSourceContextRecord.Binding, control: NativeSTAInitialSourceControl,
        work: inout UInt64) throws -> STAConservativeSourceContext {
        let initial = try initialSources(options: options, design: design, cells: cells, source: source,
            characterized: characterized, constraints: constraints, pulseSources: pulseSources,
            constants: constants, loads: loads, parasitics: parasitics, limits: control.limits,
            budget: control.stateBudget, resources: control.resources, mode: mode, corner: corner,
            work: &work, includeRootHistories: true)
        func tick(_ count: UInt64 = 1) throws {
            try NativeSTASequentialExecution.charge(count, work: &work, limits: control.limits,
                sourceResources: control.resources)
        }
        // COW input strings/tables remain retained by the record: charge their logical
        // payload once for this independently retained result, including aliases/arcs.
        let base = initial.authorities.count.multipliedReportingOverflow(by: MemoryLayout<STAConservativeSourceContextRecord.Source>.stride)
        guard !base.overflow else { throw LibertySourceError.arithmeticOverflow }
        var bytes = base.partialValue
        func add(_ count: Int) throws {
            try tick()
            let next = bytes.addingReportingOverflow(count)
            guard count >= 0, !next.overflow else { throw LibertySourceError.arithmeticOverflow }
            bytes = next.partialValue
        }
        func text(_ value: String) throws { try tick(UInt64(value.utf8.count) + 1); try add(value.utf8.count) }
        try add(MemoryLayout<STAConservativeSourceContextRecord>.stride)
        try text(mode); try text(corner); try text(STAConservativeCoupledRCOptions.modelIdentity)
        try text(binding.input.hexadecimalValue); try text(binding.configuration.hexadecimalValue)
        try text(binding.library.digest.hexadecimalValue)
        try text(binding.library.descriptor.role.rawValue); try text(binding.library.descriptor.kind.rawValue)
        try text(binding.library.descriptor.format.rawValue)
        for a in initial.authorities {
            try tick(); try text(a.endpoint.name); try text(a.endpoint.ownerNet)
            let arcs = a.sourceArcs.count.multipliedReportingOverflow(by: MemoryLayout<LibertyTimingSourceIdentity>.stride)
            guard !arcs.overflow else { throw LibertySourceError.arithmeticOverflow }; try add(arcs.partialValue)
            for arc in a.sourceArcs {
                try text(arc.cell); try text(arc.pin); if let kind = arc.timingType { try text(kind) }
                let tables = arc.tables.count.multipliedReportingOverflow(by: MemoryLayout<LibertyTimingTableIdentity>.stride)
                guard !tables.overflow else { throw LibertySourceError.arithmeticOverflow }; try add(tables.partialValue)
                for table in arc.tables { try text(table.name) }
            }
            if let root = initial.roots[a.endpoint] { try text(root.rootIdentity) }
        }
        let lease = try control.reserve(bytes: bytes, slots: initial.authorities.count)
        try tick(UInt64(initial.authorities.count) + 1)
        var entries: [STAConservativeSourceContextRecord.Source] = []
        entries.reserveCapacity(initial.authorities.count)
        for a in initial.authorities {
            try tick()
            entries.append(.init(authority: a, origin: a.sourceIsPort ? .primaryPort : .prescribedCellOutput,
                history: initial.roots[a.endpoint].map { .clock($0) } ?? .unrestricted))
        }
        let record = try STAConservativeSourceContextRecord(input: binding.input, configuration: binding.configuration,
            library: binding.library, mode: mode, corner: corner, thresholds: initial.thresholds, sources: entries, lease: lease)
        try record.validate { try tick() }
        try tick(0)
        return STAConservativeSourceContext(record: record, control: control, lease: lease)
    }

    init(options: STAConservativeCoupledRCOptions, design: TimingDesign, cells: [TimingCell],
         source: OwnedLibertySource, characterized: CharacterizedTimingLibrary,
         constraints: TimingConstraintSet, pulseSources: [STAControlPulseSource],
         constants: [String: TimingDesign.Constant], loads: [String: Double], parasitics: TimingParasitics,
         limits: STAExecutionLimits, budget: NativeSTAStateBudget,
         resources: (any LibertySourceResourceAccounting)?, mode: String, corner: String,
         work: inout UInt64) throws {
        let initial = try Self.initialSources(options: options, design: design, cells: cells, source: source,
            characterized: characterized, constraints: constraints, pulseSources: pulseSources,
            constants: constants, loads: loads, parasitics: parasitics, limits: limits, budget: budget,
            resources: resources, mode: mode, corner: corner, work: &work)
        let thresholds = initial.thresholds, drivers = initial.drivers, receiverLoads = initial.receiverLoads
        var sources = initial.sources, authorities = initial.authorities
        self.mode = mode; self.corner = corner; self.budget = budget
        self.limits = limits; self.resources = resources; self.thresholds = thresholds
        self.declaredClocks = constraints.clocks
        let solver = NativeSTAConservativeCoupling()
        func charge(_ amount: UInt64 = 1) throws {
            try NativeSTASequentialExecution.charge(amount, work: &work, limits: limits, sourceResources: resources)
        }
        func cellDomain(index: Int, output: String, load: Double,
            inputDomains: [String: ClosedRange<Double>]?, recordIdentities: Bool,
            identities: inout [LibertyTimingSourceIdentity]) throws -> (rise: ClosedRange<Double>, fall: ClosedRange<Double>)? {
            try Self.cellDomain(index: index, output: output, load: load, inputDomains: inputDomains,
                recordIdentities: recordIdentities, identities: &identities, design: design, cells: cells,
                characterized: characterized, constants: constants, limits: limits, budget: budget,
                resources: resources, work: &work)
        }
        var current = try solver.prepare(parasitics: parasitics, sources: sources, receiverLoads: receiverLoads,
            thresholds: thresholds, options: options, limits: limits, stateBudget: budget,
            sourceResources: resources, work: &work)
        while true {
            try charge()
            // Copy-on-write snapshots keep every query in this round on the previous complete box.
            try budget.reserve(sources.count)
            try budget.reserve(authorities.count)
            var nextSources = sources, nextAuthorities = authorities
            var changed = false
            for position in sources.indices {
                try charge()
                let previous = authorities[position]
                guard !previous.sourceIsPort, previous.constantVoltage == nil,
                      let driver = drivers[previous.endpoint.ownerNet], driver.authorityIndex == position,
                      let instance = driver.instance else { continue }
                var inputs: [String: ClosedRange<Double>] = [:]
                var complete = true
                func prove(_ pin: String) throws {
                    try charge(UInt64(pin.utf8.count) + 1)
                    if inputs[pin] != nil { return }
                    guard let net = design.instances[instance].connections[pin] else {
                        throw TimingError.invalidInput("Missing cell source input connection")
                    }
                    guard let upstream = drivers[net] else { complete = false; return }
                    let sourceAuthority = authorities[upstream.authorityIndex]
                    guard let rise = sourceAuthority.riseSlew, let fall = sourceAuthority.fallSlew else {
                        complete = false; return
                    }
                    try budget.reserve(2)
                    try charge(UInt64(design.instances[instance].name.utf8.count))
                    try charge(UInt64(parasitics.pinDelimiter.utf8.count))
                    let endpoint = TimingParasitics.Endpoint(name: design.instances[instance].name + parasitics.pinDelimiter + pin, ownerNet: net)
                    do {
                        let r = try solver.bounds(prepared: current, source: sourceAuthority.endpoint,
                            sink: endpoint, edge: .rise, sourceSlew: rise, work: &work)
                        let f = try solver.bounds(prepared: current, source: sourceAuthority.endpoint,
                            sink: endpoint, edge: .fall, sourceSlew: fall, work: &work)
                        inputs[pin] = Self.covering(r.slew, f.slew)
                    } catch NativeSTAConservativeCouplingError.unprovedCrossing {
                        complete = false
                    } catch NativeSTAConservativeCouplingError.unprovedUniqueTransition {
                        complete = false
                    } catch is NativeSTAConservativeCandidateNotCertified {
                        complete = false
                    }
                }
                let cell = cells[instance]
                for arc in cell.arcs {
                    try charge()
                    guard !arc.isConstraint, arc.toPin == driver.pin else { continue }
                    try prove(arc.fromPin)
                }
                for arc in try characterized.directionalControlArcs(cell: cell.name) {
                    try charge()
                    guard arc.toPin == driver.pin else { continue }
                    if let net = design.instances[instance].connections[arc.fromPin], constants[net] != nil { continue }
                    try prove(arc.fromPin)
                }
                guard complete, let load = previous.prescribedBoundaryLoad,
                      let oldRise = previous.riseSlew, let oldFall = previous.fallSlew else { continue }
                var unused: [LibertyTimingSourceIdentity] = []
                guard let domain = try cellDomain(index: instance, output: driver.pin,
                    load: load, inputDomains: inputs, recordIdentities: false, identities: &unused) else { continue }
                let narrowedRise = try Self.intersection(domain.rise, oldRise)
                let narrowedFall = try Self.intersection(domain.fall, oldFall)
                if narrowedRise != oldRise || narrowedFall != oldFall {
                    changed = true
                    nextSources[position] = .dynamic(endpoint: previous.endpoint, sourceIsPort: false,
                        riseSlew: narrowedRise, fallSlew: narrowedFall)
                    nextAuthorities[position] = .init(endpoint: previous.endpoint, sourceIsPort: false,
                        constantVoltage: nil, riseSlew: narrowedRise, fallSlew: narrowedFall,
                        sourceArcs: previous.sourceArcs, prescribedBoundaryLoad: load)
                }
            }
            guard changed else { break }
            current = try solver.restrictSources(prepared: current, to: nextSources, work: &work)
            sources = nextSources; authorities = nextAuthorities
        }
        self.drivers = drivers
        self.sourceAuthorities = authorities
        self.prepared = current
    }

    func contains(_ net: String) -> Bool { drivers[net] != nil }

    mutating func publishClockHistories(_ publications: [ClockPublication], work: inout UInt64) throws {
        try NativeSTASequentialExecution.charge(UInt64(publications.count) + 1, work: &work, limits: limits, sourceResources: resources)
        try budget.reserve(sourceAuthorities.count)
        var nextAuthorities = sourceAuthorities
        var histories: [TimingParasitics.Endpoint: NativeSTAConservativeSourceHistory] = [:]
        for publication in publications {
            try NativeSTASequentialExecution.charge(32, work: &work, limits: limits, sourceResources: resources)
            guard let driver = drivers[publication.net] else { continue }
            let previous = sourceAuthorities[driver.authorityIndex], wave = publication.wave
            try NativeSTASequentialExecution.charge(UInt64(declaredClocks.count), work: &work, limits: limits, sourceResources: resources)
            guard previous.constantVoltage == nil, wave.rise.clock == wave.fall.clock, declaredClocks.contains(wave.rise.clock),
                  wave.rise.edge == .rise, wave.fall.edge == .fall,
                  wave.rise.clock.hasValidPropagatedSource else {
                throw NativeSTAConservativeCouplingError.invalidSourceAuthority("invalid clock-history source")
            }
            try budget.reserve(2)
            for event in [wave.rise, wave.fall] {
                guard event.early.isFinite, event.late.isFinite, event.early <= event.late,
                      event.earlySlew.isFinite, event.lateSlew.isFinite,
                      event.earlySlew > 0, event.lateSlew > 0,
                      event.rootPhase == event.clock.waveform[event.rootEdge == .rise ? 0 : 1] else {
                    throw NativeSTAConservativeCouplingError.invalidSourceAuthority("invalid clock-history event")
                }
            }
            if previous.sourceIsPort {
                guard driver.endpoint.name == wave.rise.clock.source, publication.sourceIdentity == nil,
                      wave.rise.early == wave.rise.clock.waveform[0], wave.rise.late == wave.rise.early,
                      wave.fall.early == wave.fall.clock.waveform[1], wave.fall.late == wave.fall.early else {
                    throw NativeSTAConservativeCouplingError.invalidSourceAuthority("clock root history mismatch")
                }
            } else {
                guard publication.load == previous.prescribedBoundaryLoad,
                      let identity = publication.sourceIdentity, previous.sourceArcs == [identity],
                      let oldRise = previous.riseSlew, let oldFall = previous.fallSlew else {
                    throw NativeSTAConservativeCouplingError.invalidSourceAuthority("clock driver source/load mismatch")
                }
                let rise = try Self.intersection(oldRise, NativeSTATimingBounds.slew(wave.rise.earlySlew, wave.rise.lateSlew))
                let fall = try Self.intersection(oldFall, NativeSTATimingBounds.slew(wave.fall.earlySlew, wave.fall.lateSlew))
                nextAuthorities[driver.authorityIndex] = .init(endpoint: previous.endpoint, sourceIsPort: false,
                    constantVoltage: nil, riseSlew: rise, fallSlew: fall,
                    sourceArcs: previous.sourceArcs, prescribedBoundaryLoad: previous.prescribedBoundaryLoad)
            }
            try budget.reserve(1)
            try NativeSTASequentialExecution.charge(UInt64(wave.rise.clock.name.utf8.count), work: &work, limits: limits, sourceResources: resources)
            guard histories.updateValue(.clock(.init(rootIdentity: wave.rise.clock.name, period: wave.rise.clock.period,
                riseReference: wave.rise.early...wave.rise.late, fallReference: wave.fall.early...wave.fall.late)),
                forKey: driver.endpoint) == nil else {
                throw NativeSTAConservativeCouplingError.invalidSourceAuthority("duplicate clock-history publication")
            }
        }
        guard !histories.isEmpty else { return }
        try budget.reserve(nextAuthorities.count)
        var sources: [NativeSTAConservativeCoupling.Source] = []
        sources.reserveCapacity(nextAuthorities.count)
        for authority in nextAuthorities {
            try NativeSTASequentialExecution.charge(1, work: &work, limits: limits, sourceResources: resources)
            if let constant = authority.constantVoltage { sources.append(.constant(endpoint: authority.endpoint, voltage: constant)) }
            else if let rise = authority.riseSlew, let fall = authority.fallSlew {
                sources.append(.dynamic(endpoint: authority.endpoint, sourceIsPort: authority.sourceIsPort, riseSlew: rise, fallSlew: fall))
            } else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("missing restricted source domain") }
        }
        let generation = try nextHistoryGeneration()
        let restricted = try solver.restrictSources(prepared: prepared, to: sources, work: &work)
        let next = try solver.addingSourceHistory(prepared: restricted, histories: histories, work: &work)
        prepared = next; sourceAuthorities = nextAuthorities; historyGeneration = generation
    }

    mutating func markProvedClockReceivers(_ receivers: [(instance: Int, period: Double)], work: inout UInt64) throws {
        try NativeSTASequentialExecution.charge(UInt64(receivers.count) + 1, work: &work, limits: limits, sourceResources: resources)
        try budget.reserve(provedClockPeriods.count)
        try budget.reserve(receivers.count)
        var next = provedClockPeriods
        for receiver in receivers {
            guard receiver.instance >= 0, receiver.period.isFinite, receiver.period > 0,
                  next[receiver.instance] == nil || next[receiver.instance] == receiver.period else {
                throw NativeSTAConservativeCouplingError.invalidSourceAuthority("inconsistent proved clock receiver")
            }
            next[receiver.instance] = receiver.period
        }
        provedClockPeriods = next
    }

    mutating func publishSequentialPlateau(net: String, instance: Int, period: Double,
        riseArrival: ClosedRange<Double>, fallArrival: ClosedRange<Double>,
        riseSlew: ClosedRange<Double>, fallSlew: ClosedRange<Double>, load: Double,
        sourceIdentity: LibertyTimingSourceIdentity, work: inout UInt64) throws {
        try NativeSTASequentialExecution.charge(64, work: &work, limits: limits, sourceResources: resources)
        guard let driver = drivers[net] else { return }
        let authority = sourceAuthorities[driver.authorityIndex]
        guard driver.instance == instance, provedClockPeriods[instance] == period,
              !authority.sourceIsPort, authority.constantVoltage == nil,
              authority.prescribedBoundaryLoad == load, authority.sourceArcs == [sourceIdentity],
              period.isFinite, period > 0, let admittedRise = authority.riseSlew, let admittedFall = authority.fallSlew else {
            throw NativeSTAConservativeCouplingError.invalidSourceAuthority("sequential history source/load mismatch")
        }
        typealias I = TimingNumericInterval
        let rise = try Self.intersection(riseSlew, admittedRise), fall = try Self.intersection(fallSlew, admittedFall)
        var earliest: Double?, latest: Double?
        try budget.reserve(2)
        for (edge, arrival, slew) in [(TimingEdge.rise, riseArrival, rise), (.fall, fallArrival, fall)] {
            let span = try solver.thresholdSpan(thresholds, rising: edge == .rise)
            let duration = try I(point: slew.upperBound).divided(by: span)
            let threshold = try I(point: edge == .rise ? thresholds.outputRise : thresholds.outputFall).divided(by: I(point: 100))
            let q = try edge == .rise ? threshold : I(point: 1).subtracting(threshold)
            let start = try I(arrival).subtracting(q.multiplied(by: duration))
            let end = try I(arrival).adding(I(point: 1).subtracting(q).multiplied(by: duration))
            earliest = min(earliest ?? start.lowerBound, start.lowerBound)
            latest = max(latest ?? end.upperBound, end.upperBound)
        }
        guard let earliest, let latest else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("missing sequential event support") }
        let gap = try I(point: period).adding(I(point: earliest)).subtracting(I(point: latest))
        guard gap.lowerBound > 0 else { return }
        try budget.reserve(1)
        let generation = try nextHistoryGeneration()
        let next = try solver.addingSourceHistory(prepared: prepared,
            histories: [driver.endpoint: .minimumPlateau(seconds: gap.lowerBound)], work: &work)
        prepared = next; historyGeneration = generation
    }

    private func nextHistoryGeneration() throws -> UInt64 {
        let next = historyGeneration.addingReportingOverflow(1)
        guard !next.overflow else { throw NativeSTAConservativeCouplingError.invalidSourceAuthority("source-history generation overflow") }
        return next.partialValue
    }

    private static func inputDomain(_ table: TimingLUT) -> ClosedRange<Double> {
        table.inputSlews[0]...table.inputSlews[table.inputSlews.count - 1]
    }

    private static func covering(_ first: ClosedRange<Double>, _ second: ClosedRange<Double>) -> ClosedRange<Double> {
        min(first.lowerBound, second.lowerBound)...max(first.upperBound, second.upperBound)
    }

    private static func intersection(_ first: ClosedRange<Double>, _ second: ClosedRange<Double>) throws -> ClosedRange<Double> {
        let lower = max(first.lowerBound, second.lowerBound), upper = min(first.upperBound, second.upperBound)
        guard lower <= upper else { throw NativeSTAConservativeCouplingError.inconsistentBounds("empty previous-box source intersection") }
        return lower...upper
    }

    private static func requirePositive(_ result: ClosedRange<Double>) throws {
        guard result.lowerBound > 0 else {
            throw TimingCharacterizationError.unsupportedSemantic("nonpositive fixed-load transition slope authority")
        }
    }

    func validatePeriodic(net: String, riseEarly: Double, riseLate: Double, fallEarly: Double, fallLate: Double,
                          riseSlew: ClosedRange<Double>, fallSlew: ClosedRange<Double>,
                          riseRootPhase: Double, fallRootPhase: Double, period: Double, work: inout UInt64) throws {
        try NativeSTASequentialExecution.charge(32, work: &work, limits: limits, sourceResources: resources)
        guard let driver = drivers[net] else { return }
        let authority = sourceAuthorities[driver.authorityIndex]
        typealias I = TimingNumericInterval
        let spanRise = try I(point: thresholds.slewUpperRise).subtracting(I(point: thresholds.slewLowerRise)).divided(by: I(point: 100))
        let spanFall = try I(point: thresholds.slewUpperFall).subtracting(I(point: thresholds.slewLowerFall)).divided(by: I(point: 100))
        let durationRise = try I(riseSlew).divided(by: spanRise), durationFall = try I(fallSlew).divided(by: spanFall)
        let qr = try I(point: authority.sourceIsPort ? thresholds.inputRise : thresholds.outputRise).divided(by: I(point: 100))
        let qf = try I(point: authority.sourceIsPort ? thresholds.inputFall : thresholds.outputFall).divided(by: I(point: 100))
        let one = try I(point: 1), shift = try I(point: fallRootPhase <= riseRootPhase ? period : 0)
        let riseEnd = try I(point: riseLate).adding(durationRise.multiplied(by: one.subtracting(qr)))
        let fallStart = try I(point: fallEarly).adding(shift).subtracting(durationFall.multiplied(by: one.subtracting(qf)))
        let fallEnd = try I(point: fallLate).adding(shift).adding(durationFall.multiplied(by: qf))
        let nextRise = try I(point: riseEarly).adding(I(point: period)).subtracting(durationRise.multiplied(by: qr))
        guard period.isFinite, period > 0, riseEnd.upperBound < fallStart.lowerBound,
              fallEnd.upperBound < nextRise.lowerBound else {
            throw TimingError.unsupportedSemantic(format: "certified coupled RC", semantic: "Periodic boundary ramps do not have a proved nonoverlapping history")
        }
    }

    mutating func response(net: String, sink: String, edge: TimingEdge, sourceSlew: ClosedRange<Double>,
                           work: inout UInt64) throws -> (delay: ClosedRange<Double>, slew: ClosedRange<Double>) {
        try NativeSTASequentialExecution.charge(1, work: &work, limits: limits, sourceResources: resources)
        guard let driver = drivers[net]?.endpoint else { return (0...0, sourceSlew) }
        let key = Query(net: net, sink: sink, edge: edge, lower: sourceSlew.lowerBound.bitPattern, upper: sourceSlew.upperBound.bitPattern, generation: historyGeneration)
        if let index = cached[key] {
            try NativeSTASequentialExecution.charge(1, work: &work, limits: limits, sourceResources: resources)
            let value = observations[index]
            return (value.delay, value.slew)
        }
        let endpoint = TimingParasitics.Endpoint(name: sink, ownerNet: net)
        let result = try solver.bounds(prepared: prepared, source: driver, sink: endpoint, edge: edge,
            sourceSlew: sourceSlew, work: &work)
        try budget.reserve(2)
        cached[key] = observations.count
        observations.append(.init(modeID: mode, cornerID: corner, net: net, source: driver, sink: endpoint,
            edge: edge, sourceAuthorities: sourceAuthorities, sourceSlew: sourceSlew, admittedSourceSlew: result.admittedSourceSlew,
            delay: result.delay, slew: result.slew, voltageErrorUpperBound: result.voltageErrorUpperBound,
            minimumCrossingDerivative: result.minimumCrossingDerivative,
            maximumAbsoluteDerivative: result.maximumAbsoluteDerivative))
        return (result.delay, result.slew)
    }
}

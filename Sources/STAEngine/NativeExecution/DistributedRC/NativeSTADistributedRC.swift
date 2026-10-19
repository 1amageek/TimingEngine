import Foundation
import TimingCore

/// Run-local passive nodal operator. Source voltage is prescribed, never inferred from NLDM.
internal struct NativeSTADistributedRC {
    private struct Network {
        let source: String
        let sourceIsPort: Bool
        let sourceAliases: Set<String>
        let dimension: Int
        let indices: [String: Int]
        let conductance: [Double]
        let capacitance: [Double]
        let sourceConductance: [Double]
        let sourceCapacitance: [Double]
    }
    private struct ResponseKey: Hashable {
        let net: String
        let sink: String
        let sourceSlewBits: UInt64
        let edge: TimingEdge
    }
    private struct PeriodicKey: Hashable { let net: String; let sink: String; let source: STAPeriodicRCSource }
    struct PeriodicResponse {
        let riseDelay: Double
        let fallDelay: Double
        let riseSlew: Double
        let fallSlew: Double
    }
    private var periodicResponses: [PeriodicKey: PeriodicResponse] = [:]
    private var responses: [ResponseKey: (delay: Double, slew: Double)] = [:]
    private let sourceResources: (any LibertySourceResourceAccounting)?
    private let stateBudget: NativeSTAStateBudget
    private let options: STADistributedRCOptions
    private let limits: STAExecutionLimits
    private let thresholds: TimingCharacterizationThresholds
    private let delimiter: String
    private let mode: String
    private let corner: String
    private var networks: [String: Network] = [:]
    private(set) var steps: UInt64 = 0
    private(set) var observations: [STADistributedRCObservation] = []

    init(options: STADistributedRCOptions, limits: STAExecutionLimits, parasitics: TimingParasitics,
         design: TimingDesign, cells: [TimingCell], source: OwnedLibertySource, sourceResources: (any LibertySourceResourceAccounting)? = nil, stateBudget: NativeSTAStateBudget? = nil, mode: String, corner: String,
         initialSteps: UInt64, work: inout UInt64) throws {
        self.stateBudget = stateBudget ?? NativeSTAStateBudget(maximum: limits.maximumPathStates)
        self.sourceResources = sourceResources
        self.steps = initialSteps
        self.options = options; self.limits = limits
        guard let admittedThresholds = source.thresholds else {
            throw Self.unsupported("unavailable source threshold convention: " + String(describing: source.thresholdIssue))
        }
        thresholds = admittedThresholds
        delimiter = parasitics.pinDelimiter; self.mode = mode; self.corner = corner
        guard parasitics.hasDistributedTopology else { throw Self.unsupported("legacy parasitic inventory has no exact distributed topology") }
        guard !source.hasPinThresholdOverrides else { throw Self.unsupported("pin-level threshold overrides") }
        var retainedMatrixSlots = 0
        for net in parasitics.networks {
            try Task.checkCancellation()
            guard !net.resistances.isEmpty else { throw Self.unsupported("resistance inventory without topology: " + net.name) }
            guard design.net(named: net.name).capacitance == 0 else { throw Self.unsupported("unattached canonical net capacitance: " + net.name) }
            var drivers: [(String, Bool)] = []
            var sinks: [String: Double] = [:]
            for port in design.ports where port.netName == net.name {
                if port.direction != .output { drivers.append((port.name, true)) }
                if port.direction != .input { sinks[port.name] = 0 }
            }
            for i in design.instances.indices {
                let instance = design.instances[i]
                for pin in cells[i].pins where instance.connections[pin.name] == net.name {
                    let name = instance.name + delimiter + pin.name
                    if pin.direction == .output { drivers.append((name, false)) }
                    else if pin.direction == .input { sinks[name] = pin.capacitance }
                    else { throw Self.unsupported("bidirectional distributed pin: " + name) }
                }
            }
            guard drivers.count == 1, let driver = drivers.first else { throw Self.unsupported("ambiguous distributed driver: " + net.name) }
            let connections = Set(net.connections.map(\.name))
            guard connections.contains(driver.0), Set(sinks.keys).isSubset(of: connections) else {
                throw Self.unsupported("missing exact distributed source/sink connection: " + net.name)
            }
            for endpoint in net.connections {
                try charge(1, work: &work, limits: limits)
                guard !endpoint.name.isEmpty, endpoint.ownerNet == net.name else { throw Self.unsupported("invalid distributed connection owner") }
            }
            let recordCount = net.resistances.count.addingReportingOverflow(net.capacitances.count)
            let endpointCount = recordCount.partialValue.multipliedReportingOverflow(by: 2)
            let sourceSlots = endpointCount.partialValue.addingReportingOverflow(net.connections.count)
            guard !recordCount.overflow, !endpointCount.overflow, !sourceSlots.overflow else { throw Self.unsupported("RC incidence size overflow") }
            try self.stateBudget.reserve(sourceSlots.partialValue)
            try charge(UInt64(sourceSlots.partialValue), work: &work, limits: limits)
            let names = Set(net.resistances.flatMap { [$0.first.name, $0.second.name] })
                .union(net.capacitances.flatMap { [$0.first.name] + ($0.second.map { [$0.name] } ?? []) })
                .union(connections)
            guard names.count <= options.maximumNodes else { throw STAPathAnalysisError.capacity(resource: "RC nodes", limit: UInt64(options.maximumNodes)) }
            let aliasSlots = names.count.multipliedReportingOverflow(by: 10)
            guard !aliasSlots.overflow else { throw Self.unsupported("RC alias workspace overflow") }
            try self.stateBudget.reserve(aliasSlots.partialValue)
            var representative = Dictionary(uniqueKeysWithValues: names.map { ($0, $0) })
            func root(_ name: String) -> String {
                var current = name
                while representative[current]! != current { current = representative[current]! }
                return current
            }
            var resistanceIDs: Set<UInt64> = []
            for resistor in net.resistances {
                try Task.checkCancellation(); try charge(1, work: &work, limits: limits)
                guard resistor.resistance.isFinite, resistor.resistance >= 0,
                      resistor.source.declaringNet == net.name, resistor.source.identifier > 0, resistor.source.line > 0,
                      resistanceIDs.insert(resistor.source.identifier).inserted,
                      !resistor.first.name.isEmpty, !resistor.second.name.isEmpty,
                      resistor.first.ownerNet == net.name, resistor.second.ownerNet == net.name else {
                    throw Self.unsupported("invalid distributed resistor identity/owner/value")
                }
                if resistor.resistance == 0 {
                    try charge(UInt64(names.count) * 2, work: &work, limits: limits)
                    let a = root(resistor.first.name), b = root(resistor.second.name)
                    if a != b { representative[max(a, b)] = min(a, b) }
                }
            }
            for name in names {
                try Task.checkCancellation()
                try charge(UInt64(names.count), work: &work, limits: limits)
                representative[name] = root(name)
            }
            let sourceNode = representative[driver.0]!
            let classes = Set(representative.values)
            let sourceAliases = Set(names.filter { representative[$0] == sourceNode })
            let sortWork = UInt64(names.count).multipliedReportingOverflow(by: UInt64(max(1, names.count)))
            guard !sortWork.overflow else { throw Self.unsupported("RC alias sort work overflow") }
            try charge(sortWork.partialValue, work: &work, limits: limits)
            let unknown = classes.subtracting([sourceNode]).sorted(), n = unknown.count
            let square = n.multipliedReportingOverflow(by: n)
            let storage = square.partialValue.multipliedReportingOverflow(by: 6)
            guard !square.overflow, !storage.overflow, storage.partialValue <= limits.maximumPathStates else {
                throw STAPathAnalysisError.capacity(resource: "RC matrix workspace", limit: UInt64(limits.maximumPathStates))
            }
            let rows = n.multipliedReportingOverflow(by: 12)
            let current = storage.partialValue.addingReportingOverflow(rows.partialValue)
            guard !rows.overflow, !current.overflow else { throw Self.unsupported("RC workspace size overflow") }
            let combined = retainedMatrixSlots.addingReportingOverflow(current.partialValue)
            guard !combined.overflow, combined.partialValue <= limits.maximumPathStates else {
                throw STAPathAnalysisError.capacity(resource: "retained RC matrix workspace", limit: UInt64(limits.maximumPathStates))
            }
            try self.stateBudget.reserve(current.partialValue)
            retainedMatrixSlots = combined.partialValue
            try charge(UInt64(current.partialValue), work: &work, limits: limits)
            let classIndex = Dictionary(uniqueKeysWithValues: unknown.enumerated().map { ($0.element, $0.offset) })
            let index = Dictionary(uniqueKeysWithValues: names.compactMap { name in classIndex[representative[name]!].map { (name, $0) } })
            var g = Array(repeating: 0.0, count: square.partialValue)
            var c = g, gs = Array(repeating: 0.0, count: n), cs = gs
            var neighbors: [String: [String]] = [:]
            for resistor in net.resistances {
                try charge(1, work: &work, limits: limits)
                let a = representative[resistor.first.name]!, b = representative[resistor.second.name]!
                if a == b { continue }
                let value = 1 / resistor.resistance
                guard value.isFinite, value > 0 else { throw Self.unsupported("unrepresentable distributed conductance") }
                neighbors[a, default: []].append(b); neighbors[b, default: []].append(a)
                if let i = classIndex[a] { g[i * n + i] += value; if let j = classIndex[b] { g[i * n + j] -= value } else { gs[i] += value } }
                if let j = classIndex[b] { g[j * n + j] += value; if let i = classIndex[a] { g[j * n + i] -= value } else { gs[j] += value } }
            }
            var visited: Set<String> = [sourceNode], queue = [sourceNode], cursor = 0
            while cursor < queue.count {
                let node = queue[cursor]; cursor += 1
                for next in neighbors[node] ?? [] { try charge(1, work: &work, limits: limits); if visited.insert(next).inserted { queue.append(next) } }
            }
            guard visited == classes else { throw Self.unsupported("disconnected distributed topology: " + net.name) }
            var groundedReceiverLoad = 0.0
            var capacitanceIDs: Set<UInt64> = []
            for cap in net.capacitances {
                try charge(1, work: &work, limits: limits)
                guard cap.first.ownerNet == net.name, cap.second == nil || cap.second?.ownerNet == net.name else {
                    throw Self.unsupported("dynamic cross-net coupling requires an explicit aggressor policy")
                }
                guard cap.capacitance.isFinite, cap.capacitance >= 0, !cap.first.name.isEmpty,
                      cap.second?.name != "", cap.source.declaringNet == net.name, cap.source.identifier > 0, cap.source.line > 0,
                      capacitanceIDs.insert(cap.source.identifier).inserted else { throw Self.unsupported("invalid distributed capacitance") }
                if cap.second == nil, !sourceAliases.contains(cap.first.name) { groundedReceiverLoad += cap.capacitance }
                if let second = cap.second, representative[cap.first.name] == representative[second.name] { continue }
                let a = index[cap.first.name], b = cap.second.flatMap { index[$0.name] }, value = cap.capacitance
                if let a { c[a * n + a] += value }
                if let b { c[b * n + b] += value }
                if let a, let b { c[a * n + b] -= value; c[b * n + a] -= value }
                else if cap.second != nil {
                    if let a { cs[a] -= value }; if let b { cs[b] -= value }
                }
            }
            for (sink, load) in sinks { if let i = index[sink] { c[i * n + i] += load; groundedReceiverLoad += load } }
            // With no grounded receiver load the network follows the source algebraically;
            // sampling an ideal step would fabricate a finite transition width.
            guard groundedReceiverLoad.isFinite, n == 0 || groundedReceiverLoad > 0 else {
                throw Self.unsupported("zero grounded receiver load requires an explicit algebraic transition profile")
            }
            guard (g + c + gs + cs).allSatisfy(\.isFinite) else { throw Self.unsupported("nonfinite distributed operator") }
            networks[net.name] = .init(source: driver.0, sourceIsPort: driver.1, sourceAliases: sourceAliases, dimension: n, indices: index,
                conductance: g, capacitance: c, sourceConductance: gs, sourceCapacitance: cs)
        }
        // Cross-net operators incident on a solved network cannot be silently omitted from its matrix.
        for net in parasitics.networks {
            for cap in net.capacitances where cap.second != nil && cap.first.ownerNet != cap.second!.ownerNet {
                throw Self.unsupported("dynamic cross-net coupling requires an explicit aggressor policy")
            }
        }
    }

    func contains(_ net: String) -> Bool { networks[net] != nil }

    mutating func response(net: String, sink: String, sourceSlew: Double, edge: TimingEdge,
                           work: inout UInt64) throws -> (delay: Double, slew: Double) {
        try Task.checkCancellation()
        guard let network = networks[net] else { return (0, sourceSlew) }
        let key = ResponseKey(net: net, sink: sink, sourceSlewBits: sourceSlew.bitPattern, edge: edge)
        if let retained = responses[key] { try charge(1, work: &work, limits: limits); return retained }
        let endpoint = sink
        guard sourceSlew.isFinite, sourceSlew >= 0 else {
            throw Self.unsupported("missing distributed receiver: " + sink)
        }
        let rising = edge == .rise
        let lower = (rising ? thresholds.slewLowerRise : thresholds.slewLowerFall) / 100
        let upper = (rising ? thresholds.slewUpperRise : thresholds.slewUpperFall) / 100
        let driver = (network.sourceIsPort ? (rising ? thresholds.inputRise : thresholds.inputFall)
            : (rising ? thresholds.outputRise : thresholds.outputFall)) / 100
        let receiverThreshold = (rising ? thresholds.inputRise : thresholds.inputFall) / 100
        let levels = rising ? [lower, receiverThreshold, upper] : [1 - upper, 1 - receiverThreshold, 1 - lower]
        let duration = sourceSlew / (upper - lower)
        let sourceCrossing = duration * (rising ? driver : 1 - driver)
        guard duration.isFinite, duration <= options.stopTime else { throw Self.unsupported("source ramp exceeds distributed horizon") }
        if network.sourceAliases.contains(endpoint) {
            try charge(1, work: &work, limits: limits)
            let measured = (delay: duration * levels[1] - sourceCrossing, slew: sourceSlew)
            guard measured.delay.isFinite else { throw Self.unsupported("nonfinite ideal constraint crossing") }
            guard observations.count < limits.maximumPathStates else { throw STAPathAnalysisError.capacity(resource: "RC observations", limit: UInt64(limits.maximumPathStates)) }
            try stateBudget.reserve(2)
            observations.append(.init(modeID: mode, cornerID: corner, net: net, source: network.source, sink: endpoint,
                edge: edge, sourceSlew: sourceSlew, sourceThreshold: driver, sinkThreshold: receiverThreshold,
                lowerThreshold: lower, upperThreshold: upper, wireDelay: measured.delay, sinkSlew: measured.slew,
                observedCrossingDifference: nil, finalMaximumTimeStep: nil, cumulativeSteps: steps, method: .idealConstraint))
            responses[key] = measured
            return measured
        }
        guard let receiver = network.indices[endpoint] else { throw Self.unsupported("missing distributed receiver: " + sink) }
        var previous: (Double, Double)?, step = options.maximumTimeStep
        for refinement in 0...options.maximumRefinements {
            try Task.checkCancellation()
            let crossing = try solve(network, receiver: receiver, levels: levels, duration: duration, step: step, work: &work)
            let measured = (crossing[1] - sourceCrossing, crossing[2] - crossing[0])
            guard measured.0.isFinite, measured.1.isFinite, measured.1 > 0 else { throw Self.unsupported("invalid distributed crossings") }
            if let previous {
                let difference = max(abs(measured.0 - previous.0), abs(measured.1 - previous.1))
                if difference <= options.crossingTolerance {
                    guard observations.count < limits.maximumPathStates else { throw STAPathAnalysisError.capacity(resource: "RC observations", limit: UInt64(limits.maximumPathStates)) }
                    try stateBudget.reserve(2)
                    observations.append(.init(modeID: mode, cornerID: corner, net: net, source: network.source, sink: endpoint,
                        edge: edge, sourceSlew: sourceSlew, sourceThreshold: driver, sinkThreshold: receiverThreshold,
                        lowerThreshold: lower, upperThreshold: upper, wireDelay: measured.0, sinkSlew: measured.1,
                        observedCrossingDifference: difference, finalMaximumTimeStep: step, cumulativeSteps: steps))
                    responses[key] = measured
                    return measured
                }
            }
            guard refinement < options.maximumRefinements, step / 2 > 0 else { throw Self.unsupported("distributed crossing refinement exhausted") }
            previous = measured; step /= 2
        }
        throw Self.unsupported("distributed crossing refinement exhausted")
    }

    mutating func periodicResponse(net: String, sink: String, source: STAPeriodicRCSource,
                                   work: inout UInt64) throws -> PeriodicResponse {
        try Task.checkCancellation()
        guard let network = networks[net] else {
            throw Self.unsupported("missing exact propagated clock network/receiver: " + net + " " + sink)
        }
        let key = PeriodicKey(net: net, sink: sink, source: source)
        if let retained = periodicResponses[key] { try charge(1, work: &work, limits: limits); return retained }
        let shape = try source.shape(thresholds: thresholds, sourceIsPort: network.sourceIsPort)
        if network.sourceAliases.contains(sink) {
            guard shape.period <= options.stopTime else { throw Self.unsupported("ideal periodic source exceeds horizon") }
            try charge(2, work: &work, limits: limits)
            let measured = PeriodicResponse(riseDelay: shape.riseDuration * (thresholds.inputRise / 100 - shape.riseThreshold),
                fallDelay: shape.fallDuration * (shape.fallThreshold - thresholds.inputFall / 100),
                riseSlew: source.riseSlew, fallSlew: source.fallSlew)
            guard measured.riseDelay.isFinite, measured.fallDelay.isFinite else { throw Self.unsupported("nonfinite ideal periodic crossing") }
            guard limits.maximumPathStates >= 2, observations.count <= limits.maximumPathStates - 2 else {
                throw STAPathAnalysisError.capacity(resource: "RC observations", limit: UInt64(limits.maximumPathStates))
            }
            try stateBudget.reserve(3)
            for edge in [TimingEdge.rise, .fall] {
                let rising = edge == .rise
                observations.append(.init(modeID: mode, cornerID: corner, net: net, source: network.source, sink: sink,
                    edge: edge, sourceSlew: rising ? source.riseSlew : source.fallSlew,
                    sourceThreshold: rising ? shape.riseThreshold : shape.fallThreshold,
                    sinkThreshold: (rising ? thresholds.inputRise : thresholds.inputFall) / 100,
                    lowerThreshold: (rising ? thresholds.slewLowerRise : thresholds.slewLowerFall) / 100,
                    upperThreshold: (rising ? thresholds.slewUpperRise : thresholds.slewUpperFall) / 100,
                    wireDelay: rising ? measured.riseDelay : measured.fallDelay, sinkSlew: rising ? measured.riseSlew : measured.fallSlew,
                    observedCrossingDifference: nil, finalMaximumTimeStep: nil, cumulativeSteps: steps, period: source.period, method: .idealConstraint))
            }
            periodicResponses[key] = measured
            return measured
        }
        guard let receiver = network.indices[sink] else { throw Self.unsupported("missing exact propagated clock receiver: " + sink) }
        guard shape.period <= options.stopTime / 2 else { throw Self.unsupported("periodic source exceeds convergence horizon") }
        var previous: PeriodicResponse?, step = options.maximumTimeStep
        for refinement in 0...options.maximumRefinements {
            let (measured, cycleDifference) = try solvePeriodic(network, receiver: receiver, shape: shape, step: step, work: &work)
            if let previous {
                let difference = max(abs(measured.riseDelay - previous.riseDelay), abs(measured.fallDelay - previous.fallDelay),
                    abs(measured.riseSlew - previous.riseSlew), abs(measured.fallSlew - previous.fallSlew))
                if difference <= options.crossingTolerance {
                    guard observations.count + 2 <= limits.maximumPathStates else { throw STAPathAnalysisError.capacity(resource: "RC observations", limit: UInt64(limits.maximumPathStates)) }
                    try stateBudget.reserve(3)
                    for edge in [TimingEdge.rise, .fall] {
                        let rising = edge == .rise
                        observations.append(.init(modeID: mode, cornerID: corner, net: net, source: network.source, sink: sink,
                            edge: edge, sourceSlew: rising ? source.riseSlew : source.fallSlew,
                            sourceThreshold: rising ? shape.riseThreshold : shape.fallThreshold,
                            sinkThreshold: (rising ? thresholds.inputRise : thresholds.inputFall) / 100,
                            lowerThreshold: (rising ? thresholds.slewLowerRise : thresholds.slewLowerFall) / 100,
                            upperThreshold: (rising ? thresholds.slewUpperRise : thresholds.slewUpperFall) / 100,
                            wireDelay: rising ? measured.riseDelay : measured.fallDelay,
                            sinkSlew: rising ? measured.riseSlew : measured.fallSlew, observedCrossingDifference: difference,
                            finalMaximumTimeStep: step, cumulativeSteps: steps, period: source.period, observedCycleDifference: cycleDifference))
                    }
                    periodicResponses[key] = measured
                    return measured
                }
            }
            guard refinement < options.maximumRefinements, step / 2 > 0 else { throw Self.unsupported("periodic grid refinement exhausted") }
            previous = measured; step /= 2
        }
        throw Self.unsupported("periodic grid refinement exhausted")
    }

    private mutating func solvePeriodic(_ network: Network, receiver: Int, shape: STAPeriodicRCSource.Shape,
                                       step: Double, work: inout UInt64) throws -> (PeriodicResponse, Double) {
        let n = network.dimension
        var matrix = network.conductance
        try charge(UInt64(n) * UInt64(n), work: &work, limits: limits)
        for i in matrix.indices { matrix[i] += network.capacitance[i] / step }
        let factor = try cholesky(matrix, dimension: n, work: &work)
        let levels = [thresholds.slewLowerRise, thresholds.inputRise, thresholds.slewUpperRise,
                      thresholds.slewUpperFall, thresholds.inputFall, thresholds.slewLowerFall].map { $0 / 100 }
        let breakpoints = shape.breakpoints
        var values = Array(repeating: shape.voltage(0), count: n), rhs = values
        var crossings = Array<Double?>(repeating: nil, count: 6)
        var previousCycle: PeriodicResponse?, cycle = 0, time = 0.0
        while time < options.stopTime {
            try Task.checkCancellation()
            guard steps < options.maximumSteps else { throw STAPathAnalysisError.capacity(resource: "RC time steps", limit: options.maximumSteps) }
            let boundary = Double(cycle + 1) * shape.period
            var next = min(time + step, boundary, options.stopTime)
            for point in breakpoints {
                let event = Double(cycle) * shape.period + point
                if event > time { next = min(next, event) }
            }
            let dt = next == time + step ? step : next - time
            guard next.isFinite, dt > 0, next > time else { throw Self.unsupported("unrepresentable periodic grid") }
            let actualFactor: [Double]
            if dt == step { actualFactor = factor }
            else {
                var short = network.conductance
                try charge(UInt64(n) * UInt64(n), work: &work, limits: limits)
                for i in short.indices { short[i] += network.capacitance[i] / dt }
                actualFactor = try cholesky(short, dimension: n, work: &work)
            }
            let voltage = shape.voltage(next), oldVoltage = shape.voltage(time)
            try charge(UInt64(n) * UInt64(n) * 3 + 4, work: &work, limits: limits)
            for i in 0..<n {
                rhs[i] = network.sourceConductance[i] * voltage - network.sourceCapacitance[i] * (voltage - oldVoltage) / dt
                for j in 0..<n { rhs[i] += network.capacitance[i * n + j] * values[j] / dt }
            }
            let before = values[receiver]
            for i in 0..<n {
                for j in 0..<i { rhs[i] -= actualFactor[i * n + j] * rhs[j] }
                rhs[i] /= actualFactor[i * n + i]
            }
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in (i + 1)..<n { rhs[i] -= actualFactor[j * n + i] * rhs[j] }
                rhs[i] /= actualFactor[i * n + i]
            }
            guard rhs.allSatisfy(\.isFinite) else { throw Self.unsupported("nonfinite periodic solution") }
            let after = rhs[receiver]
            for i in levels.indices {
                let crosses = i < 3 ? before < levels[i] && after >= levels[i] : before > levels[i] && after <= levels[i]
                if crosses {
                    guard crossings[i] == nil else { throw Self.unsupported("ambiguous multiple periodic threshold crossings") }
                    crossings[i] = time + dt * (levels[i] - before) / (after - before) - Double(cycle) * shape.period
                }
            }
            values = rhs; time = next; steps += 1
            if next == boundary {
                if crossings.allSatisfy({ $0 != nil }) {
                    let t = crossings.map { $0! }
                    func slew(_ offset: Int) -> Double {
                        let lower = t[offset] > t[offset + 1] ? t[offset] - shape.period : t[offset]
                        let upper = t[offset + 2] < t[offset + 1] ? t[offset + 2] + shape.period : t[offset + 2]
                        return upper - lower
                    }
                    func delay(_ crossing: Double, phase: Double, earliest: Double) -> Double {
                        let difference = crossing - phase
                        return difference < earliest ? difference + shape.period : difference
                    }
                    let measured = PeriodicResponse(riseDelay: delay(t[1], phase: shape.risePhase, earliest: -shape.riseDuration * shape.riseThreshold),
                        fallDelay: delay(t[4], phase: shape.fallPhase, earliest: -shape.fallDuration * (1 - shape.fallThreshold)),
                        riseSlew: slew(0), fallSlew: slew(3))
                    guard [measured.riseDelay, measured.fallDelay, measured.riseSlew, measured.fallSlew].allSatisfy(\.isFinite),
                          measured.riseSlew > 0, measured.fallSlew > 0 else { throw Self.unsupported("invalid periodic crossings") }
                    if let previousCycle {
                        let difference = max(abs(measured.riseDelay - previousCycle.riseDelay), abs(measured.fallDelay - previousCycle.fallDelay),
                            abs(measured.riseSlew - previousCycle.riseSlew), abs(measured.fallSlew - previousCycle.fallSlew))
                        if difference <= options.crossingTolerance { return (measured, difference) }
                    }
                    previousCycle = measured
                } else { previousCycle = nil }
                crossings = Array(repeating: nil, count: 6); cycle += 1
            }
        }
        throw Self.unsupported("periodic cycle agreement/crossings outside horizon")
    }

    private mutating func solve(_ network: Network, receiver: Int, levels: [Double], duration: Double,
                               step: Double, work: inout UInt64) throws -> [Double] {
        let n = network.dimension
        var matrix = network.conductance
        try charge(UInt64(n) * UInt64(n), work: &work, limits: limits)
        for i in matrix.indices { matrix[i] += network.capacitance[i] / step }
        let factor = try cholesky(matrix, dimension: n, work: &work)
        var values = Array(repeating: 0.0, count: n), rhs = values
        var crossings = Array<Double?>(repeating: nil, count: levels.count)
        var time = 0.0
        while time < options.stopTime {
            try Task.checkCancellation()
            guard steps < options.maximumSteps else { throw STAPathAnalysisError.capacity(resource: "RC time steps", limit: options.maximumSteps) }
            let next = min(time + step, options.stopTime), dt = next == options.stopTime ? options.stopTime - time : step
            guard next.isFinite, dt > 0 else { throw Self.unsupported("unrepresentable distributed time grid") }
            let voltage = duration == 0 ? 1 : min(next / duration, 1)
            let oldVoltage = duration == 0 ? (time == 0 ? 0 : 1) : min(time / duration, 1)
            // A shortened final step owns a different factor; never reuse the full-grid factor for it.
            let actualFactor: [Double]
            if dt != step {
                var last = network.conductance
                try charge(UInt64(n) * UInt64(n), work: &work, limits: limits)
                for i in last.indices { last[i] += network.capacitance[i] / dt }
                actualFactor = try cholesky(last, dimension: n, work: &work)
            } else { actualFactor = factor }
            try charge(UInt64(n) * UInt64(n) * 3, work: &work, limits: limits)
            for i in 0..<n {
                rhs[i] = network.sourceConductance[i] * voltage - network.sourceCapacitance[i] * (voltage - oldVoltage) / dt
                for j in 0..<n { rhs[i] += network.capacitance[i * n + j] * values[j] / dt }
            }
            let before = values[receiver]
            for i in 0..<n {
                for j in 0..<i { rhs[i] -= actualFactor[i * n + j] * rhs[j] }
                rhs[i] /= actualFactor[i * n + i]
            }
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in (i + 1)..<n { rhs[i] -= actualFactor[j * n + i] * rhs[j] }
                rhs[i] /= actualFactor[i * n + i]
            }
            guard rhs.allSatisfy(\.isFinite) else { throw Self.unsupported("nonfinite distributed solution") }
            let after = rhs[receiver]
            for i in levels.indices where crossings[i] == nil && before < levels[i] && after >= levels[i] {
                crossings[i] = time + dt * (levels[i] - before) / (after - before)
            }
            values = rhs; time = next; steps += 1
            if crossings.allSatisfy({ $0 != nil }) { return crossings.map { $0! } }
        }
        throw Self.unsupported("distributed sink crossings outside horizon")
    }

    private func cholesky(_ matrix: [Double], dimension n: Int, work: inout UInt64) throws -> [Double] {
        let cubicWork = (UInt64(n) * UInt64(n)).multipliedReportingOverflow(by: UInt64(n))
        guard !cubicWork.overflow else { throw Self.unsupported("RC factorization work overflow") }
        try charge(cubicWork.partialValue, work: &work, limits: limits)
        var factor = Array(repeating: 0.0, count: matrix.count)
        for i in 0..<n {
            try Task.checkCancellation()
            for j in 0...i {
                var value = matrix[i * n + j]
                for k in 0..<j { value -= factor[i * n + k] * factor[j * n + k] }
                if i == j {
                    guard value.isFinite, value > 0 else { throw Self.unsupported("singular/nonpositive distributed operator") }
                    factor[i * n + j] = sqrt(value)
                } else {
                    factor[i * n + j] = value / factor[j * n + j]
                    guard factor[i * n + j].isFinite else { throw Self.unsupported("nonfinite distributed factorization") }
                }
            }
        }
        return factor
    }
    private func charge(_ amount: UInt64, work: inout UInt64, limits: STAExecutionLimits) throws {
        try sourceResources?.check()
        let sum = work.addingReportingOverflow(amount)
        guard !sum.overflow, sum.partialValue <= limits.maximumPathWorkUnits else {
            throw STAPathAnalysisError.capacity(resource: "path work including distributed RC", limit: limits.maximumPathWorkUnits)
        }
        work = sum.partialValue
    }
    private static func unsupported(_ semantic: String) -> TimingError {
        .unsupportedSemantic(format: "distributed RC STA", semantic: semantic)
    }
}

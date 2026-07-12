import Foundation
import TimingCore

public struct TimingReferenceAnalyzer: Sendable {
    public init() {}

    public func analyze(
        design: TimingDesign,
        library: TimingLibrary,
        constraints: TimingConstraintSet,
        parasitics: TimingParasitics? = nil
    ) throws -> TimingReferenceResult {
        let cells = try Dictionary(uniqueKeysWithValues: design.instances.map { instance in
            (instance.name, try library.cell(named: instance.cell))
        })
        let netLoads = makeNetLoads(design: design, cells: cells, parasitics: parasitics)
        var cache: [String: EdgePair] = [:]
        var active = Set<String>()

        func arrival(for net: String) throws -> EdgePair {
            if let cached = cache[net] { return cached }
            guard active.insert(net).inserted else {
                throw TimingError.unsupportedSemantic(format: "Reference STA", semantic: "combinational cycle")
            }
            defer { active.remove(net) }

            if let port = design.ports.first(where: { $0.name == net && ($0.direction == .input || $0.direction == .bidirectional) }) {
                _ = port
                let inputDelay = constraints.inputDelays.first { $0.port == net && $0.isMax }
                let value = inputDelay.map { max($0.rise, $0.fall) } ?? 0
                let result = EdgePair(rise: value, fall: value)
                cache[net] = result
                return result
            }

            for instance in design.instances {
                guard let cell = cells[instance.name] else { continue }
                if let model = cell.sequentialModel,
                   instance.connections[model.outputPin] == net,
                   let clockNet = instance.connections[model.clockPin],
                   let clock = constraints.clock(for: clockNet) ?? constraints.clock(named: clockNet),
                   let clockToQ = model.clockToQ ?? cell.arcs.first(where: { $0.fromPin == model.clockPin && $0.toPin == model.outputPin }) {
                    _ = clock
                    let load = netLoads[net] ?? constraints.defaultOutputLoad
                    let rise = clockToQ.delay(for: .rise).lookup(inputSlew: 0, outputLoad: load)
                    let fall = clockToQ.delay(for: .fall).lookup(inputSlew: 0, outputLoad: load)
                    let result = EdgePair(rise: rise, fall: fall)
                    cache[net] = result
                    return result
                }

                for outputPin in cell.outputPins where instance.connections[outputPin.name] == net {
                    var latest = EdgePairValues(rise: -.infinity, fall: -.infinity)
                    var earliest = EdgePairValues(rise: .infinity, fall: .infinity)
                    for inputPin in cell.inputPins {
                        guard let inputNet = instance.connections[inputPin.name] else { continue }
                        let input = try arrival(for: inputNet)
                        for arc in cell.arcs(from: inputPin.name, to: outputPin.name) {
                            for outputEdge in [TimingEdge.rise, .fall] {
                                let inputEdges = arc.sense.inputEdge(for: outputEdge).map { [$0] } ?? [.rise, .fall]
                                for inputEdge in inputEdges {
                                    let delay = arc.delay(for: outputEdge).lookup(
                                        inputSlew: constraints.defaultInputSlew,
                                        outputLoad: netLoads[net] ?? constraints.defaultOutputLoad
                                    )
                                    latest.set(
                                        max(latest.value(for: outputEdge), input.late.value(for: inputEdge) + delay),
                                        for: outputEdge
                                    )
                                    earliest.set(
                                        min(earliest.value(for: outputEdge), input.early.value(for: inputEdge) + delay),
                                        for: outputEdge
                                    )
                                }
                            }
                        }
                    }
                    guard latest.rise.isFinite || latest.fall.isFinite else { continue }
                    let result = EdgePair(rise: latest.rise, fall: latest.fall, earlyRise: earliest.rise, earlyFall: earliest.fall)
                    cache[net] = result
                    return result
                }
            }
            throw TimingError.unsupportedSemantic(format: "Reference STA", semantic: "net without a supported driver: \(net)")
        }

        var setupSlacks: [Double] = []
        var holdSlacks: [Double] = []
        for instance in design.instances {
            guard let cell = cells[instance.name], let model = cell.sequentialModel,
                  let dataNet = instance.connections[model.dataPin],
                  let clockNet = instance.connections[model.clockPin],
                  let clock = constraints.clock(for: clockNet) ?? constraints.clock(named: clockNet) else { continue }
            let data = try arrival(for: dataNet)
            let startpoint = dataNet
            guard !isFalsePath(startpoint: startpoint, endpoint: dataNet, exceptions: constraints.exceptions) else { continue }
            let cycles = multicycle(for: startpoint, endpoint: dataNet, exceptions: constraints.exceptions)
            let required = clock.period * Double(cycles) - model.setupTime - clock.uncertainty
            setupSlacks.append(required - max(data.late.rise, data.late.fall))
            holdSlacks.append(min(data.early.rise, data.early.fall) - model.holdTime - clock.uncertainty)
        }
        for port in design.ports where port.direction == .output || port.direction == .bidirectional {
            guard let outputDelay = constraints.outputDelays.first(where: { $0.port == port.name && $0.isMax }) else { continue }
            let data = try arrival(for: port.name)
            let externalDelay = max(outputDelay.rise, outputDelay.fall)
            let required = outputDelay.clock
                .flatMap { constraints.clock(named: $0) ?? constraints.clock(for: $0) }
                .map { $0.period - externalDelay - $0.uncertainty }
                ?? externalDelay
            setupSlacks.append(required - max(data.late.rise, data.late.fall))
        }
        guard !setupSlacks.isEmpty || !holdSlacks.isEmpty else {
            throw TimingError.unsupportedSemantic(format: "Reference STA", semantic: "no constrained timing endpoints")
        }
        return TimingReferenceResult(
            oracleID: "timing.reference.scalar-v1",
            worstSetupSlack: setupSlacks.min(),
            worstHoldSlack: holdSlacks.min()
        )
    }

    private struct EdgePair: Sendable {
        var late: EdgePairValues
        var early: EdgePairValues

        init(rise: Double, fall: Double, earlyRise: Double? = nil, earlyFall: Double? = nil) {
            self.late = EdgePairValues(rise: rise, fall: fall)
            self.early = EdgePairValues(rise: earlyRise ?? rise, fall: earlyFall ?? fall)
        }
    }

    private struct EdgePairValues: Sendable {
        var rise: Double
        var fall: Double

        func value(for edge: TimingEdge) -> Double {
            edge == .rise ? rise : fall
        }

        mutating func set(_ value: Double, for edge: TimingEdge) {
            if edge == .rise { rise = value } else { fall = value }
        }
    }

    private func makeNetLoads(
        design: TimingDesign,
        cells: [String: TimingCell],
        parasitics: TimingParasitics?
    ) -> [String: Double] {
        var loads: [String: Double] = [:]
        for instance in design.instances {
            guard let cell = cells[instance.name] else { continue }
            for pin in cell.inputPins where instance.connections[pin.name] != nil {
                loads[instance.connections[pin.name]!, default: 0] += pin.capacitance
            }
        }
        for net in design.nets { loads[net.name, default: 0] += net.capacitance }
        for network in parasitics?.networks ?? [] {
            loads[network.name, default: 0] += network.totalCapacitance
        }
        return loads
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

    private func matches(_ value: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        return patterns.contains { pattern in
            if pattern == "*" { return true }
            guard pattern.contains("*") else { return pattern == value }
            let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            return value.hasPrefix(parts.first ?? "") && value.hasSuffix(parts.last ?? "")
        }
    }
}

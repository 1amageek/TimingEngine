import Foundation
import TimingCore

extension NativeSTASequentialExecution {
    struct Transition: Sendable {
        let pin: String
        let edge: TimingEdge
        let early: Double
        let late: Double
        let earlySlew: Double
        let lateSlew: Double
        let parentRouteIndex: Int
    }
    struct Boundary: Sendable {
        let edge: TimingEdge
        let early: Double
        let late: Double
        let earlySlew: Double
        let lateSlew: Double
    }
    struct Window: Sendable {
        let open: Boundary
        let close: Boundary
        let period: Double
    }
    enum Branch: Sendable { case data, gate, clock }
    enum CoordinateMeaning: Sendable { case attained, infimum, supremum }
    struct SampleRequest: Sendable {
        let branch: Branch
        let coordinateMeaning: CoordinateMeaning
        let selectedInputCoordinate: Double
        let pin: String
        let inputEdge: TimingEdge
        let outputEdge: TimingEdge
        let inputSlew: Double
        let outputLoad: Double
        let releaseTime: Double
        let waiting: Double
        let borrowedTime: Double
        let cycle: Int
        let windowOpen: Double?
        let windowClose: Double?
        let parentRouteIndex: Int
        let sourceIdentity: LibertyTimingSourceIdentity?
        var inputSlewBounds: ClosedRange<Double>? = nil
    }
    struct TransferRequest: Sendable {
        let cell: String
        let output: String
        let causalInput: Transition
        let earlyCandidates: [SampleRequest]
        let lateCandidates: [SampleRequest]
    }
    struct TimedBound: Sendable {
        let request: SampleRequest
        let arrival: Double
        let rawDelay: Double
        let appliedDelay: Double
        let outputSlew: Double
        let receiptIndex: Int
    }
    struct TimedOutput: Sendable {
        let output: String
        let causalInput: Transition
        let early: TimedBound
        let late: TimedBound
    }

    static func requestLatch(plan: Plan, cell: TimingCell, output: String, outputEdge: TimingEdge,
                             input: Transition, window: Window, outputLoad: Double, certified: Bool = false,
                             work: inout UInt64, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                             sourceResources: (any LibertySourceResourceAccounting)? = nil) throws -> TransferRequest {
        let scans = UInt64(cell.arcs.count).multipliedReportingOverflow(by: 4)
        let envelope = scans.partialValue.addingReportingOverflow(160)
        guard !scans.overflow, !envelope.overflow else { throw Failure.nonfinite("Latch request work") }
        try charge(envelope.partialValue, work: &work, limits: limits, sourceResources: sourceResources)
        guard plan.kind == .latch, plan.dataPins.contains(input.pin),
              plan.outputs.contains(where: { $0.pin == output }), window.open.edge == plan.activeEdge,
              window.close.edge == plan.closeEdge else { throw Failure.inconsistent("Latch transition/clock plan") }
        try validate(input: input, load: outputLoad)
        try validate(window: window)
        try stateBudget.reserve(5)
        let early = try latchCandidates(plan: plan, cell: cell, output: output, outputEdge: outputEdge,
            input: input, window: window, load: outputLoad, early: true, certified: certified)
        let late = try latchCandidates(plan: plan, cell: cell, output: output, outputEdge: outputEdge,
            input: input, window: window, load: outputLoad, early: false, certified: certified)
        guard !early.isEmpty, !late.isEmpty else { throw Failure.inconsistent("Latch interval has no periodic branch") }
        return .init(cell: cell.name, output: output, causalInput: input, earlyCandidates: early, lateCandidates: late)
    }

    static func requestFF(plan: Plan, cell: TimingCell, output: String, outputEdge: TimingEdge,
                          clock: Transition, outputLoad: Double,
                          work: inout UInt64, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                          sourceResources: (any LibertySourceResourceAccounting)? = nil) throws -> TransferRequest {
        try charge(UInt64(cell.arcs.count + 2), work: &work, limits: limits, sourceResources: sourceResources)
        guard plan.kind != .latch, clock.pin == plan.clockPin, clock.edge == plan.activeEdge,
              plan.outputs.contains(where: { $0.pin == output }) else { throw Failure.inconsistent("FF clock/output plan") }
        try validate(input: clock, load: outputLoad)
        let arc = try selectedArc(cell: cell, pin: clock.pin, output: output, inputEdge: clock.edge,
                                  outputEdge: outputEdge, clock: true, sourceRequired: plan.kind != .legacyFlipFlop)
        try stateBudget.reserve(3)
        func bound(_ arrival: Double, _ slew: Double) -> SampleRequest {
            .init(branch: .clock, coordinateMeaning: .attained, selectedInputCoordinate: arrival,
                  pin: clock.pin, inputEdge: clock.edge, outputEdge: outputEdge, inputSlew: slew,
                  outputLoad: outputLoad, releaseTime: arrival, waiting: 0, borrowedTime: 0, cycle: 0,
                  windowOpen: nil, windowClose: nil, parentRouteIndex: clock.parentRouteIndex,
                  sourceIdentity: arc.sourceIdentity,
                  inputSlewBounds: NativeSTATimingBounds.slew(clock.earlySlew, clock.lateSlew))
        }
        return .init(cell: cell.name, output: output, causalInput: clock,
                     earlyCandidates: [bound(clock.early, clock.earlySlew)], lateCandidates: [bound(clock.late, clock.lateSlew)])
    }

    /// Every possible branch extreme consumes its own actual characterized sample and receipt.
    static func complete(_ request: TransferRequest, earlySamples: [TimingSourcePropagationSample],
                         lateSamples: [TimingSourcePropagationSample], earlyReceiptIndices: [Int], lateReceiptIndices: [Int],
                         characterized: CharacterizedTimingLibrary,
                         earlyRanges: [TimingSourcePropagationRangeSample] = [], lateRanges: [TimingSourcePropagationRangeSample] = [], earlyCellScale: Double = 1, lateCellScale: Double = 1,
                         work: inout UInt64, limits: STAExecutionLimits, stateBudget: NativeSTAStateBudget,
                         sourceResources: (any LibertySourceResourceAccounting)? = nil) throws -> TimedOutput {
        guard (1...2).contains(request.earlyCandidates.count), (1...2).contains(request.lateCandidates.count),
              earlySamples.count == request.earlyCandidates.count, lateSamples.count == request.lateCandidates.count,
              earlyReceiptIndices.count == earlySamples.count, lateReceiptIndices.count == lateSamples.count else {
            throw Failure.missing("Every sequential branch candidate requires its actual sample and receipt")
        }
        guard earlyRanges.isEmpty == lateRanges.isEmpty,
              earlyRanges.isEmpty || (earlyRanges.count == earlySamples.count && lateRanges.count == lateSamples.count) else {
            throw Failure.inconsistent("Sequential range receipt count")
        }
        try charge(UInt64(earlySamples.count + lateSamples.count) * 40, work: &work, limits: limits, sourceResources: sourceResources)
        guard earlyCellScale.isFinite, lateCellScale.isFinite, earlyCellScale >= 0, lateCellScale >= 0 else {
            throw Failure.nonfinite("Sequential cell delay scale")
        }
        try stateBudget.reserve(3)
        func finish(_ wanted: SampleRequest, _ sample: TimingSourcePropagationSample, _ receipt: Int,
                    _ scale: Double, _ parentBound: Double, _ range: TimingSourcePropagationRangeSample?, _ upper: Bool) throws -> TimedBound {
            try Task.checkCancellation()
            try sourceResources?.check()
            guard receipt >= 0, let identity = wanted.sourceIdentity,
                  sample.delay.source == identity, sample.outputSlew.source == identity,
                  identity.cell == request.cell, identity.pin == request.output,
                  sample.delay.firstInput == wanted.inputSlew, sample.delay.secondInput == wanted.outputLoad,
                  sample.outputSlew.firstInput == wanted.inputSlew, sample.outputSlew.secondInput == wanted.outputLoad,
                  sample.delay.table.name == (wanted.outputEdge == .rise ? "cell_rise" : "cell_fall"),
                  sample.outputSlew.table.name == (wanted.outputEdge == .rise ? "rise_transition" : "fall_transition") else {
                throw Failure.inconsistent("Actual sequential propagation sample query/identity")
            }
            try characterized.validate(sample.delay)
            try characterized.validate(sample.outputSlew)
            if let range { try characterized.validate(range) }
            let scaled = try range.map { try NativeSTATimingBounds.scale($0.delay.result, by: scale) }
            let delay = scaled.map { upper ? $0.upperBound : $0.lowerBound } ?? sample.delay.result * scale
            let arrival = try range == nil ? wanted.releaseTime + delay : NativeSTATimingBounds.add(wanted.releaseTime, delay, upper: upper)
            let applied = try range == nil ? arrival - parentBound : NativeSTATimingBounds.add(arrival, -parentBound, upper: upper)
            guard arrival.isFinite, applied.isFinite else { throw Failure.nonfinite("Sequential output arrival") }
            return .init(request: wanted, arrival: arrival, rawDelay: sample.delay.result, appliedDelay: applied,
                         outputSlew: range.map { upper ? $0.outputSlew.result.upperBound : $0.outputSlew.result.lowerBound } ?? sample.outputSlew.result, receiptIndex: receipt)
        }
        var early: TimedBound?, late: TimedBound?
        for index in request.earlyCandidates.indices {
            let candidate = try finish(request.earlyCandidates[index], earlySamples[index], earlyReceiptIndices[index],
                                       earlyCellScale, request.causalInput.early, earlyRanges.isEmpty ? nil : earlyRanges[index], false)
            if early == nil || candidate.arrival < early!.arrival { early = candidate }
        }
        for index in request.lateCandidates.indices {
            let candidate = try finish(request.lateCandidates[index], lateSamples[index], lateReceiptIndices[index],
                                       lateCellScale, request.causalInput.late, lateRanges.isEmpty ? nil : lateRanges[index], true)
            if late == nil || candidate.arrival > late!.arrival { late = candidate }
        }
        guard earlyRanges.isEmpty == lateRanges.isEmpty,
              earlyRanges.isEmpty || (earlyRanges.count == earlySamples.count && lateRanges.count == lateSamples.count),
              let selectedEarly = early, let selectedLate = late else { throw Failure.inconsistent("Sequential range receipt count") }
        if !earlyRanges.isEmpty {
            let minimum = (earlyRanges + lateRanges).map { $0.outputSlew.result.lowerBound }.min()!
            let maximum = (earlyRanges + lateRanges).map { $0.outputSlew.result.upperBound }.max()!
            early = .init(request: selectedEarly.request, arrival: selectedEarly.arrival, rawDelay: selectedEarly.rawDelay,
                appliedDelay: selectedEarly.appliedDelay, outputSlew: minimum, receiptIndex: selectedEarly.receiptIndex)
            late = .init(request: selectedLate.request, arrival: selectedLate.arrival, rawDelay: selectedLate.rawDelay,
                appliedDelay: selectedLate.appliedDelay, outputSlew: maximum, receiptIndex: selectedLate.receiptIndex)
        }
        guard let early, let late, early.arrival <= late.arrival,
              early.appliedDelay >= 0, late.appliedDelay >= 0 else {
            throw Failure.inconsistent("Sequential arrival envelope is not finite and ordered")
        }
        return .init(output: request.output, causalInput: request.causalInput, early: early, late: late)
    }

    /// A fixed maximum of two branch extremes per context, independent of signed epoch distance.
    private static func latchCandidates(plan: Plan, cell: TimingCell, output: String, outputEdge: TimingEdge,
                                        input: Transition, window: Window, load: Double, early: Bool, certified: Bool) throws -> [SampleRequest] {
        let a = input.early, b = input.late, p = window.period
        let oe = window.open.early, ol = window.open.late, ce = window.close.early, cl = window.close.late
        func epoch(_ value: Double) throws -> Int {
            guard value.isFinite, abs(value) <= 9_007_199_254_740_991, let index = Int(exactly: value) else {
                throw Failure.nonfinite("Representable signed latch epoch")
            }
            return index
        }
        func epochRounding(_ first: Double, _ second: Double, up: Bool) throws -> Double {
            guard certified else { return up ? ceil((first - second) / p) : floor((first - second) / p) }
            let quotient = try TimingNumericInterval(point: first).subtracting(TimingNumericInterval(point: second))
                .divided(by: TimingNumericInterval(point: p))
            let low = up ? ceil(quotient.lowerBound) : floor(quotient.lowerBound)
            let high = up ? ceil(quotient.upperBound) : floor(quotient.upperBound)
            guard low == high else { throw Failure.unsupported("Unproved exact latch epoch boundary") }
            return low
        }
        func shifted(_ origin: Double, _ index: Int, upper: Bool) throws -> Double {
            if certified {
                let value = try TimingNumericInterval(point: Double(index)).multiplied(by: TimingNumericInterval(point: p))
                    .adding(TimingNumericInterval(point: origin))
                return upper ? value.upperBound : value.lowerBound
            }
            let value = origin + Double(index) * p
            guard value.isFinite else { throw Failure.nonfinite("Latch shifted phase") }
            return value
        }
        func phases(_ index: Int) throws -> (open: Double, latestOpen: Double, earliestClose: Double, close: Double, previousClose: Double) {
            let opening = try shifted(oe, index, upper: false), latest = try shifted(ol, index, upper: true)
            let closing = try shifted(ce, index, upper: false), last = try shifted(cl, index, upper: true)
            let previous = try shifted(ce, index - 1, upper: false)
            guard opening <= latest, latest < closing, closing <= last, previous < opening else {
                throw Failure.nonfinite("Representable ordered latch phases")
            }
            return (opening, latest, closing, last, previous)
        }
        var result: [SampleRequest] = []
        result.reserveCapacity(2)
        let firstData = try epoch(epochRounding(a, cl, up: false) + 1)
        let lastData = try epoch(epochRounding(b, oe, up: true) - 1)
        if firstData <= lastData {
            let index = early ? firstData : lastData, phase = try phases(index)
            guard b > phase.open, a < phase.close else { throw Failure.nonfinite("Latch data epoch intersection") }
            let coordinate = early ? max(a, phase.open) : min(b, phase.close)
            let meaning: CoordinateMeaning = early ? (a > phase.open ? .attained : .infimum)
                : (b < phase.close ? .attained : .supremum)
            let slew = early ? input.earlySlew : input.lateSlew
            let arc = try selectedArc(cell: cell, pin: input.pin, output: output, inputEdge: input.edge,
                                      outputEdge: outputEdge, clock: false, sourceRequired: true)
            let borrowed = coordinate - phase.open
            guard coordinate.isFinite, borrowed.isFinite, coordinate >= a, coordinate <= b,
                  borrowed >= 0, borrowed <= phase.close - phase.open else { throw Failure.nonfinite("Latch data bound coordinate") }
            result.append(.init(branch: .data, coordinateMeaning: meaning, selectedInputCoordinate: coordinate,
                pin: input.pin, inputEdge: input.edge, outputEdge: outputEdge, inputSlew: slew,
                outputLoad: load, releaseTime: coordinate, waiting: 0, borrowedTime: borrowed,
                cycle: index, windowOpen: phase.open, windowClose: phase.close,
                parentRouteIndex: input.parentRouteIndex, sourceIdentity: arc.sourceIdentity,
                inputSlewBounds: NativeSTATimingBounds.slew(input.earlySlew, input.lateSlew)))
        }
        let firstGate = try epoch(epochRounding(a, ol, up: true))
        let lastGate = try epoch(epochRounding(b, ce, up: false) + 1)
        if firstGate <= lastGate {
            let index = early ? firstGate : lastGate, phase = try phases(index)
            guard b >= phase.previousClose, a <= phase.latestOpen else { throw Failure.nonfinite("Latch gate epoch intersection") }
            let coordinate = max(a, phase.previousClose)
            let opening = early ? max(phase.open, a) : phase.latestOpen
            let waiting = opening - coordinate
            let slew = early ? window.open.earlySlew : window.open.lateSlew
            let arc = try selectedArc(cell: cell, pin: plan.clockPin, output: output, inputEdge: plan.activeEdge,
                                      outputEdge: outputEdge, clock: true, sourceRequired: true)
            guard coordinate.isFinite, coordinate >= a, coordinate <= b, coordinate <= opening,
                  waiting.isFinite, waiting >= 0 else { throw Failure.nonfinite("Latch gate bound coordinate") }
            result.append(.init(branch: .gate, coordinateMeaning: .attained, selectedInputCoordinate: coordinate,
                pin: plan.clockPin, inputEdge: plan.activeEdge, outputEdge: outputEdge, inputSlew: slew,
                outputLoad: load, releaseTime: opening, waiting: waiting, borrowedTime: 0,
                cycle: index, windowOpen: opening, windowClose: phase.close,
                parentRouteIndex: input.parentRouteIndex, sourceIdentity: arc.sourceIdentity,
                inputSlewBounds: NativeSTATimingBounds.slew(window.open.earlySlew, window.open.lateSlew)))
        }
        return result
    }

    private static func selectedArc(cell: TimingCell, pin: String, output: String, inputEdge: TimingEdge,
                                    outputEdge: TimingEdge, clock: Bool, sourceRequired: Bool) throws -> TimingArc {
        let matches = cell.arcs.filter { !$0.isConstraint && $0.fromPin == pin && $0.toPin == output }
        guard matches.count == 1, let arc = matches.first else { throw Failure.missing("Unique sequential propagation arc") }
        if sourceRequired {
            guard let source = arc.sourceIdentity else { throw Failure.missing("Positioned sequential propagation arc") }
            if clock {
                let expected = inputEdge == .rise ? "rising_edge" : "falling_edge"
                guard source.timingType == expected else { throw Failure.inconsistent("Source launch/gate edge") }
            } else {
                guard source.timingType == nil || source.timingType == "combinational",
                      arc.sense.inputEdge(for: outputEdge) == inputEdge else {
                    throw Failure.unsupported("Actual latch data arc edge/sense")
                }
            }
        }
        return arc
    }

    private static func validate(input: Transition, load: Double) throws {
        guard [input.early, input.late, input.earlySlew, input.lateSlew, load].allSatisfy({ $0.isFinite }),
              input.early <= input.late, input.earlySlew >= 0, input.lateSlew >= 0, load >= 0,
              input.parentRouteIndex >= 0 else { throw Failure.nonfinite("Sequential transition/load") }
    }
    private static func validate(window: Window) throws {
        guard [window.open.early, window.open.late, window.close.early, window.close.late,
               window.open.earlySlew, window.open.lateSlew, window.close.earlySlew,
               window.close.lateSlew, window.period].allSatisfy({ $0.isFinite }),
              window.period > 0, window.open.early <= window.open.late,
              window.close.early <= window.close.late, window.open.late < window.close.early,
              window.close.late < window.open.early + window.period,
              window.open.earlySlew >= 0, window.open.lateSlew >= 0,
              window.close.earlySlew >= 0, window.close.lateSlew >= 0 else {
            throw Failure.inconsistent("Finite nonoverlapping latch clock windows")
        }
    }
}

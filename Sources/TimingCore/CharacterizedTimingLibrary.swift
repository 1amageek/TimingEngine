public struct CharacterizedTimingLibrary: Sendable {
    private let storage: LibertyParseStorage?
    private let metadata: LibertySourceStorageReservation?
    private let library: TimingLibrary
    private let propagationCells: Set<String>
    private let capacitanceSources: [String: [String: TimingCapacitanceSource]]
    public let thresholds: TimingCharacterizationThresholds
    /// Attribute names resolved using the Liberty R-2020.09 normative default.
    public let standardDefaultAttributes: Set<String>

    // Only source admission constructs this immutable value; canonical JSON does not.
    init(
        admitted library: TimingLibrary, thresholds: TimingCharacterizationThresholds,
        standardDefaultAttributes: Set<String>, propagationCells: Set<String>,
        capacitanceSources: [String: [String: TimingCapacitanceSource]],
        storage: LibertyParseStorage? = nil, metadata: LibertySourceStorageReservation? = nil
    ) {
        self.storage = storage; self.metadata = metadata
        self.library = library
        self.propagationCells = propagationCells
        self.capacitanceSources = capacitanceSources
        self.thresholds = thresholds
        self.standardDefaultAttributes = standardDefaultAttributes
    }

    public var name: String { library.name }

    public func pinCapacitance(cell: String, pin: String) throws -> Double {
        let model = try library.cell(named: cell)
        guard let input = model.pin(named: pin), input.direction == .input else {
            throw TimingCharacterizationError.unsupportedSemantic("input pin \(cell).\(pin)")
        }
        return input.capacitance
    }

    public func pinCapacitanceSource(cell: String, pin: String) throws -> TimingCapacitanceSource {
        _ = try pinCapacitance(cell: cell, pin: pin)
        guard let source = capacitanceSources[cell]?[pin] else {
            throw TimingCharacterizationError.missingSourceFact("capacitance origin \(cell).\(pin)")
        }
        return source
    }

    public func pinIsClock(cell: String, pin: String) throws -> Bool {
        let model = try library.cell(named: cell)
        guard let input = model.pin(named: pin), input.direction == .input else {
            throw TimingCharacterizationError.unsupportedSemantic("input pin \(cell).\(pin)")
        }
        return input.isClock
    }

    public func arcSense(cell: String, fromPin: String, toPin: String) throws -> TimingSense {
        try arc(cell: cell, fromPin: fromPin, toPin: toPin).sense
    }

    public func evaluate(
        cell: String, fromPin: String, toPin: String, edge: TimingEdge,
        inputSlew: Double, outputLoad: Double
    ) throws -> TimingCharacterizationSample {
        let model = try arc(cell: cell, fromPin: fromPin, toPin: toPin)
        // All edge tables must admit the operating point before any value is published.
        let riseDelay = try model.delayRise.lookupChecked(inputSlew: inputSlew, outputLoad: outputLoad)
        let fallDelay = try model.delayFall.lookupChecked(inputSlew: inputSlew, outputLoad: outputLoad)
        let riseSlew = try model.transitionRise.lookupChecked(inputSlew: inputSlew, outputLoad: outputLoad)
        let fallSlew = try model.transitionFall.lookupChecked(inputSlew: inputSlew, outputLoad: outputLoad)
        return TimingCharacterizationSample(
            delay: edge == .rise ? riseDelay : fallDelay,
            outputSlew: edge == .rise ? riseSlew : fallSlew
        )
    }

    /// Observes the actual selected edge; every source table must admit the operating point.
    public func evaluatePropagation(
        cell: String, fromPin: String, toPin: String, edge: TimingEdge,
        inputSlew: Double, outputLoad: Double
    ) throws -> TimingSourcePropagationSample {
        let model = try arc(cell: cell, fromPin: fromPin, toPin: toPin)
        guard let identity = model.sourceIdentity else {
            throw TimingCharacterizationError.missingSourceFact("propagation group identity")
        }
        let riseDelay = try observation(model.delayRise, source: identity, table: "cell_rise", quantity: .cellDelay,
            first: inputSlew, second: outputLoad)
        let fallDelay = try observation(model.delayFall, source: identity, table: "cell_fall", quantity: .cellDelay,
            first: inputSlew, second: outputLoad)
        let riseSlew = try observation(model.transitionRise, source: identity, table: "rise_transition", quantity: .outputSlew,
            first: inputSlew, second: outputLoad)
        let fallSlew = try observation(model.transitionFall, source: identity, table: "fall_transition", quantity: .outputSlew,
            first: inputSlew, second: outputLoad)
        return .init(delay: edge == .rise ? riseDelay : fallDelay, outputSlew: edge == .rise ? riseSlew : fallSlew)
    }

    /// Constraint results are signed; strictness applies to the actual two slew domains.
    public func evaluateCheck(
        cell: String, kind: TimingCheckArc.Kind, constrainedPin: String, relatedPin: String,
        constrainedEdge: TimingEdge, relatedEdge: TimingEdge,
        constrainedSlew: Double, relatedSlew: Double
    ) throws -> TimingSourceEvaluationSample {
        let check = try exactCheck(cell: cell, kind: kind, constrainedPin: constrainedPin, relatedPin: relatedPin,
            constrainedEdge: constrainedEdge, relatedEdge: relatedEdge)
        guard let identity = check.sourceIdentity else { throw TimingCharacterizationError.missingSourceFact("unique source constraint group") }
        return try observation(check.table, source: identity,
            table: constrainedEdge == .rise ? "rise_constraint" : "fall_constraint", quantity: .constraint,
            first: constrainedSlew, second: relatedSlew)
    }

    /// Actual source inventory; absence creates no clock/control pulse requirement.
    public func pulseWidthConstraints(cell: String) throws -> [TimingPulseWidthConstraint] {
        let laws = try library.cell(named: cell).pulseWidthConstraints
        for law in laws {
            try storage?.step()
            guard law.sourceIdentity != nil else { throw TimingCharacterizationError.missingSourceFact("pulse law identity") }
        }
        return laws
    }

    /// Evaluates one exact original opening-edge law, never a high/low or first-value summary.
    public func evaluatePulseWidth(cell: String, pin: String, openingEdge: TimingEdge,
                                   sourceIdentity: LibertyTimingSourceIdentity, inputSlew: Double) throws -> TimingPulseWidthSample {
        guard inputSlew.isFinite, inputSlew >= 0 else { throw TimingCharacterizationError.invalidValue("pulse input slew") }
        var matched: TimingPulseWidthConstraint?
        for law in try pulseWidthConstraints(cell: cell) {
            try storage?.step(UInt64(sourceIdentity.tables.count) + 1)
            if law.pin == pin, law.openingEdge == openingEdge, law.sourceIdentity == sourceIdentity {
                guard matched == nil else { throw TimingCharacterizationError.ambiguousSource("pulse law") }
                matched = law
            }
        }
        guard let law = matched else { throw TimingCharacterizationError.missingSourceFact("exact pulse law") }
        let name = sourceIdentity.timingType == "min_pulse_width"
            ? (openingEdge == .rise ? "rise_constraint" : "fall_constraint")
            : (openingEdge == .rise ? "min_pulse_width_high" : "min_pulse_width_low")
        var tableIdentity: LibertyTimingTableIdentity?
        for table in sourceIdentity.tables {
            try storage?.step(UInt64(table.name.utf8.count) + 1)
            if table.name == name {
                guard tableIdentity == nil else { throw TimingCharacterizationError.ambiguousSource("pulse table identity") }
                tableIdentity = table
            }
        }
        guard let table = tableIdentity else { throw TimingCharacterizationError.missingSourceFact("pulse table identity") }
        switch law.limit {
        case .scalar(let value):
            guard value.isFinite, value >= 0 else { throw TimingCharacterizationError.invalidValue("scalar pulse limit") }
            return .init(source: sourceIdentity, table: table, openingEdge: openingEdge,
                inputSlew: nil, minimumSlew: nil, maximumSlew: nil, result: value)
        case .relatedPinTransition(let lut):
            // The constant second coordinate is private representation, not a source axis or receipt operand.
            guard lut.outputLoads.count == 1, lut.outputLoads[0] == 0 else { throw TimingCharacterizationError.unsupportedSemantic("pulse LUT dimensions") }
            try storage?.step(UInt64(lut.inputSlews.count) + 1)
            let value = try lut.lookupChecked(inputSlew: inputSlew, outputLoad: 0)
            return .init(source: sourceIdentity, table: table, openingEdge: openingEdge, inputSlew: inputSlew,
                minimumSlew: lut.inputSlews[0], maximumSlew: lut.inputSlews[lut.inputSlews.count - 1], result: value)
        }
    }

    public func validate(_ sample: TimingPulseWidthSample) throws {
        let actual = try evaluatePulseWidth(cell: sample.source.cell, pin: sample.source.pin,
            openingEdge: sample.openingEdge, sourceIdentity: sample.source, inputSlew: sample.inputSlew ?? 0)
        guard actual == sample else { throw TimingCharacterizationError.invalidValue("retained pulse sample") }
    }

    /// Source-only inventory, separate from ordinary clock/data propagation arcs.
    public func directionalControlArcs(cell: String) throws -> [TimingDirectionalControlArc] {
        try storage?.step()
        return try library.cell(named: cell).directionalControlArcs
    }

    public func evaluateDirectionalControl(cell: String, fromPin: String, toPin: String,
                                           kind: TimingDirectionalControlArc.Kind, outputEdge: TimingEdge,
                                           sourceIdentity: LibertyTimingSourceIdentity,
                                           inputSlew: Double, outputLoad: Double) throws -> TimingSourcePropagationSample {
        var matched: TimingDirectionalControlArc?
        for arc in try directionalControlArcs(cell: cell) {
            try storage?.step(UInt64(sourceIdentity.tables.count) + 1)
            if arc.fromPin == fromPin, arc.toPin == toPin, arc.kind == kind, arc.sourceIdentity == sourceIdentity {
                guard matched == nil else { throw TimingCharacterizationError.ambiguousSource("directional control arc") }
                matched = arc
            }
        }
        guard let arc = matched, arc.sense != nil else {
            throw TimingCharacterizationError.missingSourceFact("exact directional control arc and sense")
        }
        let delayName = outputEdge == .rise ? "cell_rise" : "cell_fall"
        let slewName = outputEdge == .rise ? "rise_transition" : "fall_transition"
        let delay = try controlTable(arc, quantity: .cellDelay, name: delayName)
        let slew = try controlTable(arc, quantity: .outputSlew, name: slewName)
        return try .init(delay: observation(delay, source: sourceIdentity, table: delayName, quantity: .cellDelay,
                             first: inputSlew, second: outputLoad),
                         outputSlew: observation(slew, source: sourceIdentity, table: slewName, quantity: .outputSlew,
                             first: inputSlew, second: outputLoad))
    }

    /// Reopens no source. A decoded observation must match this admitted immutable owner's table.
    public func validate(_ sample: TimingSourceEvaluationSample) throws {
        let table = try retainedTable(source: sample.source, quantity: sample.quantity, name: sample.table.name)
        let actual = try observation(table, source: sample.source, table: sample.table.name, quantity: sample.quantity,
            first: sample.firstInput, second: sample.secondInput)
        guard actual == sample else { throw TimingCharacterizationError.invalidValue("retained source sample") }
    }

    private func retainedTable(source: LibertyTimingSourceIdentity,
                               quantity: TimingSourceEvaluationSample.Quantity, name: String) throws -> TimingLUT {
        let cell = try library.cell(named: source.cell)
        let table: TimingLUT
        if quantity == .constraint {
            var matched: TimingCheckArc?; var count = 0
            for check in cell.sequentialModel?.timingChecks ?? [] {
                try storage?.step(UInt64(source.tables.count) + 1)
                if check.sourceIdentity == source && name == (check.constrainedEdge == .rise ? "rise_constraint" : "fall_constraint") {
                    count += 1; if matched == nil { matched = check }
                }
            }
            guard count == 1, let check = matched,
                  name == (check.constrainedEdge == .rise ? "rise_constraint" : "fall_constraint") else {
                throw TimingCharacterizationError.missingSourceFact("retained constraint identity")
            }
            table = check.table
        } else {
            var control: TimingDirectionalControlArc?; var controlCount = 0
            for arc in cell.directionalControlArcs {
                try storage?.step(UInt64(source.tables.count) + 1)
                if arc.sourceIdentity == source { controlCount += 1; if control == nil { control = arc } }
            }
            if let arc = control {
                guard controlCount == 1 else {
                    throw TimingCharacterizationError.ambiguousSource("retained directional control identity")
                }
                table = try controlTable(arc, quantity: quantity, name: name)
            } else {
                guard propagationCells.contains(cell.name) else {
                    throw TimingCharacterizationError.unsupportedSemantic("unqualified propagation cell")
                }
                var matched: TimingArc?; var count = 0
                for arc in cell.arcs {
                    try storage?.step(UInt64(source.tables.count) + 1)
                    if !arc.isConstraint && arc.sourceIdentity == source { count += 1; if matched == nil { matched = arc } }
                }
                guard count == 1, let arc = matched else {
                    throw TimingCharacterizationError.missingSourceFact("retained propagation identity")
                }
                switch (quantity, name) {
                case (.cellDelay, "cell_rise"): table = arc.delayRise
                case (.cellDelay, "cell_fall"): table = arc.delayFall
                case (.outputSlew, "rise_transition"): table = arc.transitionRise
                case (.outputSlew, "fall_transition"): table = arc.transitionFall
                default: throw TimingCharacterizationError.missingSourceFact("retained table identity")
                }
            }
        }
        return table
    }

    private func controlTable(_ arc: TimingDirectionalControlArc, quantity: TimingSourceEvaluationSample.Quantity,
                              name: String) throws -> TimingLUT {
        let table: TimingLUT?
        switch (quantity, name) {
        case (.cellDelay, "cell_rise"): table = arc.delayRise
        case (.cellDelay, "cell_fall"): table = arc.delayFall
        case (.outputSlew, "rise_transition"): table = arc.transitionRise
        case (.outputSlew, "fall_transition"): table = arc.transitionFall
        default: table = nil
        }
        guard let table else { throw TimingCharacterizationError.missingSourceFact("requested directional control table") }
        return table
    }

    private func observation(_ lut: TimingLUT, source: LibertyTimingSourceIdentity, table name: String,
                             quantity: TimingSourceEvaluationSample.Quantity,
                             first: Double, second: Double) throws -> TimingSourceEvaluationSample {
        let table = try exactTable(source: source, name: name)
        try validatePoint(first, axis: "firstInput", samples: lut.inputSlews)
        try validatePoint(second, axis: "secondInput", samples: lut.outputLoads)
        let value = lut.lookup(inputSlew: first, outputLoad: second)
        guard value.isFinite, quantity == .constraint || value >= 0 else {
            throw TimingCharacterizationError.invalidValue("interpolated source value")
        }
        return .init(source: source, table: table, quantity: quantity, firstInput: first, secondInput: second,
            firstMinimum: lut.inputSlews[0], firstMaximum: lut.inputSlews[lut.inputSlews.count - 1],
            secondMinimum: lut.outputLoads[0], secondMaximum: lut.outputLoads[lut.outputLoads.count - 1], result: value)
    }

    private func arc(cell: String, fromPin: String, toPin: String) throws -> TimingArc {
        guard propagationCells.contains(cell) else {
            throw TimingCharacterizationError.unsupportedSemantic("capacitance-only cell \(cell)")
        }
        var matched: TimingArc?; var count = 0
        for arc in try library.cell(named: cell).arcs {
            try storage?.step()
            if arc.fromPin == fromPin && arc.toPin == toPin && !arc.isConstraint {
                count += 1; if matched == nil { matched = arc }
            }
        }
        guard count == 1, let model = matched else {
            if count == 0 {
                throw TimingCharacterizationError.missingSourceFact("arc \(cell).\(fromPin)->\(toPin)")
            }
            throw TimingCharacterizationError.ambiguousSource("arc \(cell).\(fromPin)->\(toPin)")
        }
        return model
    }

    private func exactCheck(cell: String, kind: TimingCheckArc.Kind, constrainedPin: String, relatedPin: String,
        constrainedEdge: TimingEdge, relatedEdge: TimingEdge) throws -> TimingCheckArc {
        var matched: TimingCheckArc?; var count = 0
        for check in try library.cell(named: cell).sequentialModel?.timingChecks ?? [] {
            try storage?.step()
            if check.kind == kind && check.constrainedPin == constrainedPin && check.relatedPin == relatedPin
                && check.constrainedEdge == constrainedEdge && check.relatedEdge == relatedEdge {
                count += 1; if matched == nil { matched = check }
            }
        }
        guard count == 1, let matched else { throw TimingCharacterizationError.missingSourceFact("unique source constraint group") }
        return matched
    }

    private func exactTable(source: LibertyTimingSourceIdentity, name: String) throws -> LibertyTimingTableIdentity {
        var matched: LibertyTimingTableIdentity?; var count = 0
        for table in source.tables {
            try storage?.step(UInt64(table.name.utf8.count) + 1)
            if table.name == name { count += 1; if matched == nil { matched = table } }
        }
        guard count == 1, let matched else { throw TimingCharacterizationError.missingSourceFact("actual source table " + name) }
        return matched
    }
}

extension CharacterizedTimingLibrary {
    /// Encloses independent delay/transition extrema, including every interior table knot.
    public func evaluatePropagation(
        cell: String, fromPin: String, toPin: String, edge: TimingEdge,
        inputSlew: ClosedRange<Double>, outputLoad: ClosedRange<Double>
    ) throws -> TimingSourcePropagationRangeSample {
        let model = try arc(cell: cell, fromPin: fromPin, toPin: toPin)
        guard let identity = model.sourceIdentity else {
            throw TimingCharacterizationError.missingSourceFact("propagation group identity")
        }
        // Preserve strict point admission: all four domains must contain the query.
        try validateRange(inputSlew, axis: "firstInput", samples: model.delayRise.inputSlews)
        try validateRange(outputLoad, axis: "secondInput", samples: model.delayRise.outputLoads)
        try validateRange(inputSlew, axis: "firstInput", samples: model.delayFall.inputSlews)
        try validateRange(outputLoad, axis: "secondInput", samples: model.delayFall.outputLoads)
        try validateRange(inputSlew, axis: "firstInput", samples: model.transitionRise.inputSlews)
        try validateRange(outputLoad, axis: "secondInput", samples: model.transitionRise.outputLoads)
        try validateRange(inputSlew, axis: "firstInput", samples: model.transitionFall.inputSlews)
        try validateRange(outputLoad, axis: "secondInput", samples: model.transitionFall.outputLoads)
        return try .init(
            delay: rangeObservation(edge == .rise ? model.delayRise : model.delayFall,
                source: identity, table: edge == .rise ? "cell_rise" : "cell_fall", quantity: .cellDelay,
                first: inputSlew, second: outputLoad),
            outputSlew: rangeObservation(edge == .rise ? model.transitionRise : model.transitionFall,
                source: identity, table: edge == .rise ? "rise_transition" : "fall_transition", quantity: .outputSlew,
                first: inputSlew, second: outputLoad))
    }

    public func evaluateCheck(
        cell: String, kind: TimingCheckArc.Kind, constrainedPin: String, relatedPin: String,
        constrainedEdge: TimingEdge, relatedEdge: TimingEdge,
        constrainedSlew: ClosedRange<Double>, relatedSlew: ClosedRange<Double>
    ) throws -> TimingSourceEvaluationRangeSample {
        let check = try exactCheck(cell: cell, kind: kind, constrainedPin: constrainedPin, relatedPin: relatedPin,
            constrainedEdge: constrainedEdge, relatedEdge: relatedEdge)
        guard let identity = check.sourceIdentity else { throw TimingCharacterizationError.missingSourceFact("unique source constraint group") }
        return try rangeObservation(check.table, source: identity,
            table: constrainedEdge == .rise ? "rise_constraint" : "fall_constraint", quantity: .constraint,
            first: constrainedSlew, second: relatedSlew)
    }

    public func evaluateDirectionalControl(
        cell: String, fromPin: String, toPin: String, kind: TimingDirectionalControlArc.Kind,
        outputEdge: TimingEdge, sourceIdentity: LibertyTimingSourceIdentity,
        inputSlew: ClosedRange<Double>, outputLoad: ClosedRange<Double>
    ) throws -> TimingSourcePropagationRangeSample {
        let arc = try exactControlArc(cell: cell, fromPin: fromPin, toPin: toPin,
                                      kind: kind, sourceIdentity: sourceIdentity)
        let delayName = outputEdge == .rise ? "cell_rise" : "cell_fall"
        let slewName = outputEdge == .rise ? "rise_transition" : "fall_transition"
        return try .init(
            delay: rangeObservation(controlTable(arc, quantity: .cellDelay, name: delayName),
                source: sourceIdentity, table: delayName, quantity: .cellDelay, first: inputSlew, second: outputLoad),
            outputSlew: rangeObservation(controlTable(arc, quantity: .outputSlew, name: slewName),
                source: sourceIdentity, table: slewName, quantity: .outputSlew, first: inputSlew, second: outputLoad))
    }

    public func evaluatePulseWidth(
        cell: String, pin: String, openingEdge: TimingEdge,
        sourceIdentity: LibertyTimingSourceIdentity, inputSlew: ClosedRange<Double>
    ) throws -> TimingPulseWidthRangeSample {
        guard inputSlew.lowerBound.isFinite, inputSlew.upperBound.isFinite, inputSlew.lowerBound >= 0 else {
            throw TimingCharacterizationError.invalidValue("pulse input slew range")
        }
        // Resolve the same exact law and table identity as the point API.
        let point = try evaluatePulseWidth(cell: cell, pin: pin, openingEdge: openingEdge,
                                          sourceIdentity: sourceIdentity, inputSlew: inputSlew.lowerBound)
        if point.inputSlew == nil {
            return .init(source: point.source, table: point.table, openingEdge: openingEdge,
                         inputSlew: nil, slewDomain: nil, result: point.result...point.result)
        }
        var matched: TimingPulseWidthConstraint?; var count = 0
        for law in try pulseWidthConstraints(cell: cell) {
            try storage?.step(UInt64(sourceIdentity.tables.count) + 1)
            if law.pin == pin && law.openingEdge == openingEdge && law.sourceIdentity == sourceIdentity {
                count += 1; if matched == nil { matched = law }
            }
        }
        guard count == 1, let law = matched, case .relatedPinTransition(let lut) = law.limit else {
            throw TimingCharacterizationError.missingSourceFact("exact pulse range law")
        }
        let sample = try rangeObservation(lut, source: sourceIdentity, table: point.table.name,
                                          quantity: .constraint, first: inputSlew, second: 0...0)
        return .init(source: sample.source, table: sample.table, openingEdge: openingEdge,
                     inputSlew: inputSlew, slewDomain: sample.firstDomain, result: sample.result)
    }

    /// All characterized transition knots, across both output edges, provide the positive slew floor.
    public func fullDomainOutputSlew(cell: String, fromPin: String, toPin: String) throws -> ClosedRange<Double> {
        let model = try arc(cell: cell, fromPin: fromPin, toPin: toPin)
        guard let identity = model.sourceIdentity else {
            throw TimingCharacterizationError.missingSourceFact("propagation group identity")
        }
        let rise = try fullTransitionRange(model.transitionRise, source: identity, name: "rise_transition")
        let fall = try fullTransitionRange(model.transitionFall, source: identity, name: "fall_transition")
        return min(rise.lowerBound, fall.lowerBound)...max(rise.upperBound, fall.upperBound)
    }

    public func fullDomainOutputSlew(
        cell: String, fromPin: String, toPin: String, kind: TimingDirectionalControlArc.Kind,
        sourceIdentity: LibertyTimingSourceIdentity
    ) throws -> ClosedRange<Double> {
        let arc = try exactControlArc(cell: cell, fromPin: fromPin, toPin: toPin,
                                      kind: kind, sourceIdentity: sourceIdentity)
        var minimum = Double.infinity, maximum = -Double.infinity
        func include(delay: TimingLUT?, transition: TimingLUT?, name: String) throws {
            try storage?.step()
            guard (delay == nil) == (transition == nil) else {
                throw TimingCharacterizationError.missingSourceFact("directional transition slope authority")
            }
            if let transition {
                let range = try fullTransitionRange(transition, source: sourceIdentity, name: name)
                minimum = min(minimum, range.lowerBound); maximum = max(maximum, range.upperBound)
            }
        }
        try include(delay: arc.delayRise, transition: arc.transitionRise, name: "rise_transition")
        try include(delay: arc.delayFall, transition: arc.transitionFall, name: "fall_transition")
        guard minimum.isFinite, maximum.isFinite else {
            throw TimingCharacterizationError.missingSourceFact("directional transition slope authority")
        }
        return minimum...maximum
    }

    public func validate(_ sample: TimingSourceEvaluationRangeSample) throws {
        let lut = try retainedTable(source: sample.source, quantity: sample.quantity, name: sample.table.name)
        let actual = try rangeObservation(lut, source: sample.source, table: sample.table.name,
                                          quantity: sample.quantity, first: sample.firstInput, second: sample.secondInput)
        guard actual == sample else { throw TimingCharacterizationError.invalidValue("retained source range sample") }
    }

    public func validate(_ sample: TimingSourcePropagationRangeSample) throws {
        try validate(sample.delay); try validate(sample.outputSlew)
        guard sample.delay.source == sample.outputSlew.source,
              sample.delay.quantity == .cellDelay, sample.outputSlew.quantity == .outputSlew,
              sample.delay.firstInput == sample.outputSlew.firstInput,
              sample.delay.secondInput == sample.outputSlew.secondInput,
              (sample.delay.table.name == "cell_rise" && sample.outputSlew.table.name == "rise_transition")
                || (sample.delay.table.name == "cell_fall" && sample.outputSlew.table.name == "fall_transition") else {
            throw TimingCharacterizationError.invalidValue("retained propagation range pairing")
        }
    }

    public func validate(_ sample: TimingPulseWidthRangeSample) throws {
        let actual = try evaluatePulseWidth(cell: sample.source.cell, pin: sample.source.pin,
            openingEdge: sample.openingEdge, sourceIdentity: sample.source, inputSlew: sample.inputSlew ?? 0...0)
        guard actual == sample else { throw TimingCharacterizationError.invalidValue("retained pulse range sample") }
    }

    private func exactControlArc(cell: String, fromPin: String, toPin: String,
                                 kind: TimingDirectionalControlArc.Kind,
                                 sourceIdentity: LibertyTimingSourceIdentity) throws -> TimingDirectionalControlArc {
        var matched: TimingDirectionalControlArc?
        for arc in try directionalControlArcs(cell: cell) {
            try storage?.step(UInt64(sourceIdentity.tables.count) + 1)
            if arc.fromPin == fromPin, arc.toPin == toPin, arc.kind == kind, arc.sourceIdentity == sourceIdentity {
                guard matched == nil else { throw TimingCharacterizationError.ambiguousSource("directional control arc") }
                matched = arc
            }
        }
        guard let matched, matched.sense != nil else {
            throw TimingCharacterizationError.missingSourceFact("exact directional control arc and sense")
        }
        return matched
    }

    private func fullTransitionRange(_ lut: TimingLUT, source: LibertyTimingSourceIdentity,
                                     name: String) throws -> ClosedRange<Double> {
        let range = try rangeObservation(lut, source: source, table: name, quantity: .outputSlew,
            first: lut.inputSlews[0]...lut.inputSlews[lut.inputSlews.count - 1],
            second: lut.outputLoads[0]...lut.outputLoads[lut.outputLoads.count - 1]).result
        guard range.lowerBound > 0 else {
            throw TimingCharacterizationError.unsupportedSemantic("nonpositive full-domain transition slope authority")
        }
        return range
    }

    private func validateRange(_ range: ClosedRange<Double>, axis: String, samples: [Double]) throws {
        try validatePoint(range.lowerBound, axis: axis, samples: samples)
        try validatePoint(range.upperBound, axis: axis, samples: samples)
    }

    private func validatePoint(_ value: Double, axis: String, samples: [Double]) throws {
        try storage?.step()
        guard value.isFinite, value >= 0 else { throw TimingCharacterizationError.invalidValue(axis) }
        guard value >= samples[0], value <= samples[samples.count - 1] else {
            throw TimingCharacterizationError.inputOutOfRange(axis: axis, value: value,
                minimum: samples[0], maximum: samples[samples.count - 1])
        }
    }

    private func rangeObservation(
        _ lut: TimingLUT, source: LibertyTimingSourceIdentity, table name: String,
        quantity: TimingSourceEvaluationSample.Quantity, first: ClosedRange<Double>, second: ClosedRange<Double>
    ) throws -> TimingSourceEvaluationRangeSample {
        let table = try exactTable(source: source, name: name)
        try validateRange(first, axis: "firstInput", samples: lut.inputSlews)
        try validateRange(second, axis: "secondInput", samples: lut.outputLoads)
        var minimum = Double.infinity, maximum = -Double.infinity
        // Endpoints plus every interior knot are exactly the vertices of all clipped rectangles.
        // Walk the retained axes directly: no temporary Cartesian-grid allocation.
        for firstIndex in 0..<(lut.inputSlews.count + 2) {
            try storage?.step()
            let x = firstIndex == 0 ? first.lowerBound : firstIndex == 1 ? first.upperBound : lut.inputSlews[firstIndex - 2]
            if !first.contains(x) { continue }
            for secondIndex in 0..<(lut.outputLoads.count + 2) {
                try storage?.step()
                let y = secondIndex == 0 ? second.lowerBound : secondIndex == 1 ? second.upperBound : lut.outputLoads[secondIndex - 2]
                if !second.contains(y) { continue }
                let value = try enclosedVertex(lut, first: x, second: y)
                minimum = min(minimum, value.lowerBound); maximum = max(maximum, value.upperBound)
            }
        }
        guard minimum.isFinite, maximum.isFinite, quantity == .constraint || minimum >= 0 else {
            throw TimingCharacterizationError.invalidValue("interpolated source range")
        }
        return .init(source: source, table: table, quantity: quantity, firstInput: first, secondInput: second,
            firstDomain: lut.inputSlews[0]...lut.inputSlews[lut.inputSlews.count - 1],
            secondDomain: lut.outputLoads[0]...lut.outputLoads[lut.outputLoads.count - 1], result: minimum...maximum)
    }

    private func enclosedVertex(_ lut: TimingLUT, first: Double, second: Double) throws -> TimingNumericInterval {
        func bracket(_ axis: [Double], _ value: Double) throws -> (Int, Int) {
            var high = 0
            while high < axis.count - 1 && axis[high] < value { try storage?.step(); high += 1 }
            if axis[high] == value || high == 0 { return (high, high) }
            return (high - 1, high)
        }
        func interpolate(_ low: TimingNumericInterval, _ high: TimingNumericInterval,
                         coordinate: Double, lower: Double, upper: Double) throws -> TimingNumericInterval {
            if lower == upper { return low }
            let numerator = try TimingNumericInterval(point: coordinate).subtracting(.init(point: lower))
            let denominator = try TimingNumericInterval(point: upper).subtracting(.init(point: lower))
            let fraction = try numerator.divided(by: denominator)
            let difference = try high.subtracting(low)
            let result = try low.adding(difference.multiplied(by: fraction))
            // In-domain interpolation is a convex combination. Intersecting its exact corner hull
            // prevents rounding expansion from inventing negative nonnegative source quantities.
            return try .init(lowerBound: max(result.lowerBound, min(low.lowerBound, high.lowerBound)),
                             upperBound: min(result.upperBound, max(low.upperBound, high.upperBound)))
        }
        let row = try bracket(lut.inputSlews, first), column = try bracket(lut.outputLoads, second)
        let low = try interpolate(.init(point: lut.values[row.0][column.0]), .init(point: lut.values[row.0][column.1]),
            coordinate: second, lower: lut.outputLoads[column.0], upper: lut.outputLoads[column.1])
        if row.0 == row.1 { return low }
        let high = try interpolate(.init(point: lut.values[row.1][column.0]), .init(point: lut.values[row.1][column.1]),
            coordinate: second, lower: lut.outputLoads[column.0], upper: lut.outputLoads[column.1])
        return try interpolate(low, high, coordinate: first, lower: lut.inputSlews[row.0], upper: lut.inputSlews[row.1])
    }
}

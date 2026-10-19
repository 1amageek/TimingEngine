import Foundation

public struct LibertyParser: TimingLibraryParsing, TimingCharacterizationParsing, LibertySourceParsing {
    private let storage: LibertyParseStorage?
    public init() { storage = nil }
    internal init(storage: LibertyParseStorage) { self.storage = storage }

    public func parse(_ data: Data) throws -> TimingLibrary {
        try parse(data, strictCells: nil, propagationCells: []).library
    }

    public func parseCharacterized(
        _ data: Data, cellNames: [String], propagationCellNames: [String]
    ) throws -> CharacterizedTimingLibrary {
        guard !cellNames.isEmpty, Set(cellNames).count == cellNames.count,
              cellNames.allSatisfy({ !$0.isEmpty }) else {
            throw TimingCharacterizationError.invalidValue("selected cell names")
        }
        guard Set(propagationCellNames).count == propagationCellNames.count,
              Set(propagationCellNames).isSubset(of: Set(cellNames)) else {
            throw TimingCharacterizationError.invalidValue("propagation cell subset")
        }
        let parsed = try parse(data, strictCells: Set(cellNames), propagationCells: Set(propagationCellNames))
        guard let thresholds = parsed.thresholds else {
            throw TimingCharacterizationError.missingSourceFact("thresholds")
        }
        return CharacterizedTimingLibrary(
            admitted: parsed.library, thresholds: thresholds, standardDefaultAttributes: parsed.defaults,
            propagationCells: Set(propagationCellNames), capacitanceSources: parsed.capacitanceSources
        )
    }

    private func parse(_ data: Data, strictCells: Set<String>?, propagationCells: Set<String>) throws -> (
        library: TimingLibrary, thresholds: TimingCharacterizationThresholds?, defaults: Set<String>, capacitanceSources: [String: [String: TimingCapacitanceSource]]
    ) {
        guard let source = String(data: data, encoding: .utf8) else {
            throw TimingError.parseFailure(format: "Liberty", line: 1, message: "Input is not UTF-8.")
        }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            guard strictCells == nil else {
                throw TimingCharacterizationError.unsupportedSemantic("canonical JSON without Liberty source facts")
            }
            do {
                return (try JSONDecoder().decode(TimingLibrary.self, from: data), nil, [], [:])
            } catch {
                throw TimingError.parseFailure(format: "Liberty JSON", line: 1, message: error.localizedDescription)
            }
        }
        var grammar = try LibertyGrammar(source: source)
        let root = try grammar.parse()
        return try convert(root, strictCells: strictCells, propagationCells: propagationCells)
    }

    internal func convert(_ root: [LibertyNode], strictCells: Set<String>? = nil,
        propagationCells: Set<String> = [], sequentialPropagationCells: Set<String> = []) throws -> (
        library: TimingLibrary, thresholds: TimingCharacterizationThresholds?, defaults: Set<String>,
        capacitanceSources: [String: [String: TimingCapacitanceSource]]
    ) {
        var selectedLibrary: LibertyNode?
        for node in root {
            try checkText(node.name)
            if node.name == "library" { selectedLibrary = node; break }
        }
        guard let libraryNode = selectedLibrary else {
            throw TimingError.parseFailure(format: "Liberty", line: 1, message: "No library group was found.")
        }

        if strictCells != nil {
            var libraries = 0
            for node in root { try checkText(node.name); if node.name == "library" { libraries += 1 } }
            guard libraries == 1 else {
                throw TimingCharacterizationError.ambiguousSource("library")
            }
            for fact in ["time_unit", "capacitive_load_unit"] {
                _ = try self.uniqueChild(libraryNode, named: fact, required: fact == "capacitive_load_unit")
            }
        }
        let thresholds = strictCells == nil ? nil : try self.thresholds(libraryNode)
        let collectCharacterization = storage == nil || strictCells != nil
        var defaults: Set<String> = []
        if collectCharacterization {
            let defaultableAttributes = ["time_unit", "input_threshold_pct_rise", "input_threshold_pct_fall",
                "output_threshold_pct_rise", "output_threshold_pct_fall", "slew_lower_threshold_pct_rise",
                "slew_lower_threshold_pct_fall", "slew_upper_threshold_pct_rise", "slew_upper_threshold_pct_fall", "slew_derate_from_library"]
            var defaultNames = LibertyBuffer<String>()
            for name in defaultableAttributes where try libraryNode.child(named: name, storage: storage) == nil { try defaultNames.append(name, storage: storage) }
            let receipt = try storage?.reserve(String.self, capacity: defaultNames.count)
            defaults = Set(try defaultNames.array(storage: storage))
            if let storage, let receipt { try storage.hold(defaults, receipt: receipt) }
        }
        let inputCapacitanceDefault = try self.uniqueChild(libraryNode, named: "default_input_pin_cap", required: false)
        var templates = LibertyMap<LibertyNode>()
        for template in libraryNode.children {
            try checkText(template.name)
            guard template.name == "lu_table_template" else { continue }
            guard let name = template.arguments.first, try templates.value(for: name, storage: storage) == nil else {
                throw TimingCharacterizationError.ambiguousSource("lu_table_template")
            }
            try templates.set(template, for: name, storage: storage)
        }

        let timeUnitScale = try self.unitScale(
            from: (try libraryNode.attribute(named: "time_unit", storage: storage)) ?? "1ns",
            dimension: .time,
            line: self.line(try libraryNode.child(named: "time_unit", storage: storage), fallback: libraryNode)
        )
        let capacitanceUnitScale = try self.capacitanceScale(
            from: try libraryNode.child(named: "capacitive_load_unit", storage: storage)
        )
        let powerUnitScale = try self.unitScale(
            from: (try libraryNode.attribute(named: "power_unit", storage: storage)) ?? "1W",
            dimension: .power,
            line: self.line(try libraryNode.child(named: "power_unit", storage: storage), fallback: libraryNode)
        )
        if strictCells != nil {
            guard timeUnitScale.isFinite, timeUnitScale > 0,
                  capacitanceUnitScale.isFinite, capacitanceUnitScale > 0 else {
                throw TimingCharacterizationError.invalidValue("scaled time or capacitance unit")
            }
        }
        var operatingConditions = LibertyMap<TimingOperatingCondition>()
        for node in libraryNode.children {
            try checkText(node.name)
            guard node.name == "operating_conditions" else { continue }
            let name = node.arguments.first ?? "default"
            try operatingConditions.set(TimingOperatingCondition(
                name: name,
                process: try self.optionalNumber(
                    (try node.attribute(named: "process", storage: storage)),
                    field: "process",
                    line: self.line(try node.child(named: "process", storage: storage), fallback: node)
                ),
                voltage: try self.optionalNumber(
                    (try node.attribute(named: "voltage", storage: storage)),
                    field: "voltage",
                    line: self.line(try node.child(named: "voltage", storage: storage), fallback: node)
                ),
                temperature: try self.optionalNumber(
                    (try node.attribute(named: "temperature", storage: storage)),
                    field: "temperature",
                    line: self.line(try node.child(named: "temperature", storage: storage), fallback: node)
                )
            ), for: name, storage: storage)
        }

        var cells = LibertyMap<TimingCell>()
        var capacitanceSources = LibertyMap<[String: TimingCapacitanceSource]>()
        for cellNode in libraryNode.children {
            try checkText(cellNode.name)
            guard cellNode.name == "cell" else { continue }
            guard let cellName = cellNode.arguments.first, !cellName.isEmpty else {
                throw TimingError.parseFailure(format: "Liberty", line: self.line(cellNode), message: "Cell has no name.")
            }
            try checkText(cellName)
            if let strictCells, !strictCells.contains(cellName) { continue }
            guard try cells.value(for: cellName, storage: storage) == nil else {
                throw TimingCharacterizationError.ambiguousSource(storage == nil ? "cell \(cellName)" : "cell")
            }
            var cell = try parseCell(
                node: cellNode,
                timeUnitScale: timeUnitScale,
                capacitanceUnitScale: capacitanceUnitScale,
                powerUnitScale: powerUnitScale,
                templates: templates,
                strict: strictCells != nil,
                inputCapacitanceDefault: inputCapacitanceDefault,
                strictPropagation: propagationCells.contains(cellName), strictSequentialPropagation: sequentialPropagationCells.contains(cellName)
            )
            if storage == nil, try (cellNode.child(named: "ff") != nil || cellNode.child(named: "latch") != nil) {
                let facts = try LibertyFunctionalProjection(storage: nil, maximumNesting: nil).cell(cellNode)
                cell.sequentialModel = try LibertySequentialBinding(storage: nil).model(facts, numerical: cell.sequentialModel)
            }
            try cells.set(cell, for: cellName, storage: storage)
            if collectCharacterization {
            var pinSources = LibertyMap<TimingCapacitanceSource>()
            for pin in cellNode.children where try (pin.name == "pin" && pin.attribute(named: "direction", storage: storage) == "input") {
                if let name = pin.arguments.first {
                    try pinSources.set((try pin.child(named: "capacitance", storage: storage)) == nil ? .libraryDefaultInputPinCap : .pinAttribute, for: name, storage: storage)
                }
            }
            try capacitanceSources.set(pinSources.dictionary(storage: storage), for: cellName, storage: storage)
            }
        }

        let cellsOutput = try cells.dictionary(storage: storage)
        if let strictCells {
            let receipt = try storage?.reserve(String.self, capacity: cellsOutput.count, kind: .temporaryBytes)
            let keys = Set(cellsOutput.keys)
            if let storage, let receipt { try storage.hold(keys, receipt: receipt, kind: .temporaryBytes) }
            guard keys == strictCells else { throw TimingCharacterizationError.missingSourceFact("selected cells") }
        }
        guard !cells.isEmpty else {
            throw TimingError.parseFailure(format: "Liberty", line: self.line(libraryNode), message: "Library contains no cells.")
        }
        return (TimingLibrary(
            name: libraryNode.arguments.first ?? "library",
            timeUnitScale: timeUnitScale,
            capacitanceUnitScale: capacitanceUnitScale,
            powerUnitScale: powerUnitScale,
            cells: cellsOutput,
            operatingConditions: try operatingConditions.dictionary(storage: storage)
        ), thresholds, defaults, collectCharacterization ? try capacitanceSources.dictionary(storage: storage) : [:])
    }

    private func parseCell(
        node: LibertyNode,
        timeUnitScale: Double,
        capacitanceUnitScale: Double,
        powerUnitScale: Double,
        templates: LibertyMap<LibertyNode>,
        strict: Bool,
        inputCapacitanceDefault: LibertyNode?,
        strictPropagation: Bool, strictSequentialPropagation: Bool = false
    ) throws -> TimingCell {
        var pins = LibertyBuffer<TimingPin>()
        for pinNode in node.children {
            try checkText(pinNode.name)
            guard pinNode.name == "pin" else { continue }
            guard let name = pinNode.arguments.first else {
                throw TimingError.parseFailure(format: "Liberty", line: self.line(pinNode), message: "Pin has no name.")
            }
            if strict {
                guard !pins.contains(where: { $0.name == name }) else {
                    throw TimingCharacterizationError.ambiguousSource("pin \(name)")
                }
                _ = try self.uniqueChild(pinNode, named: "direction", required: true)
            }
            if strict {
                for fact in ["slew_lower_threshold_pct_rise", "slew_lower_threshold_pct_fall",
                             "slew_upper_threshold_pct_rise", "slew_upper_threshold_pct_fall",
                             "input_threshold_pct_rise", "input_threshold_pct_fall",
                             "output_threshold_pct_rise", "output_threshold_pct_fall"] {
                    guard (try pinNode.child(named: fact, storage: storage)) == nil else {
                        throw TimingCharacterizationError.unsupportedSemantic("pin-level threshold \(name).\(fact)")
                    }
                }
                if let clock = try self.uniqueChild(pinNode, named: "clock", required: false),
                   clock.value != "true" && clock.value != "false" {
                    throw TimingCharacterizationError.invalidValue("clock pin \(name)")
                }
            }
            let directionValue = (try pinNode.attribute(named: "direction", storage: storage))
            let direction: TimingPin.Direction
            if let directionValue {
                guard let parsed = TimingPin.Direction(
                    rawValue: try cleanedText(directionValue, lowercase: true)
                ) else {
                    throw TimingError.parseFailure(
                        format: "Liberty",
                        line: self.line(try pinNode.child(named: "direction", storage: storage), fallback: pinNode),
                        message: "Pin direction is invalid."
                    )
                }
                direction = parsed
            } else {
                direction = .unknown
            }
            if strict {
                guard direction == .input || direction == .output || direction == .internalPin else {
                    throw TimingCharacterizationError.unsupportedSemantic("pin direction \(name)")
                }
                if direction == .input {
                    _ = try self.uniqueChild(pinNode, named: "capacitance", required: inputCapacitanceDefault == nil)
                }
            }
            let pinCapacitance = (try pinNode.attribute(named: "capacitance", storage: storage))
                ?? (direction == .input ? inputCapacitanceDefault?.value : nil)
            let capacitance = try self.optionalNumber(
                pinCapacitance,
                field: "capacitance",
                line: self.line(try pinNode.child(named: "capacitance", storage: storage), fallback: pinNode)
            ).map { $0 * capacitanceUnitScale } ?? 0
            if strict, direction == .input,
               pinCapacitance.flatMap(Double.init) == nil {
                throw TimingCharacterizationError.invalidValue("pin capacitance dimension \(name)")
            }
            if strict, !capacitance.isFinite || capacitance < 0 {
                throw TimingCharacterizationError.invalidValue("pin capacitance \(name)")
            }
            let maxCapacitance = try self.optionalNumber(
                (try pinNode.attribute(named: "max_capacitance", storage: storage)),
                field: "max_capacitance",
                line: self.line(try pinNode.child(named: "max_capacitance", storage: storage), fallback: pinNode)
            ).map { $0 * capacitanceUnitScale }
            let clockValue = try pinNode.attribute(named: "clock", storage: storage)
            if let clockValue { try checkText(clockValue) }
            try pins.append(TimingPin(
                name: name,
                direction: direction,
                capacitance: capacitance,
                maxCapacitance: maxCapacitance,
                function: (try pinNode.attribute(named: "function", storage: storage)),
                isClock: clockValue == "true",
                isData: false
            ), storage: storage)
        }

        if strictPropagation, try (node.child(named: "ff", storage: storage) != nil || node.child(named: "latch", storage: storage) != nil) {
            throw TimingCharacterizationError.unsupportedSemantic("sequential propagation cell")
        }
        let ffNode = try node.child(named: "ff", storage: storage)
        let latchNode = try node.child(named: "latch", storage: storage)
        if strictSequentialPropagation {
            guard (ffNode != nil) != (latchNode != nil) else { throw TimingCharacterizationError.unsupportedSemantic("ambiguous sequential propagation cell") }
        }
        let leakagePower = try self.optionalNumber(
            (try node.attribute(named: "cell_leakage_power", storage: storage)),
            field: "cell_leakage_power",
            line: self.line(try node.child(named: "cell_leakage_power", storage: storage), fallback: node)
        ).map { $0 * powerUnitScale }
        var internalPower: Double?
        for powerNode in node.children {
            try checkText(powerNode.name)
            guard powerNode.name == "internal_power" else { continue }
            for tableNode in powerNode.children {
                try checkText(tableNode.name)
                guard tableNode.name == "rise_power" || tableNode.name == "fall_power" else { continue }
                guard let valuesNode = (try tableNode.child(named: "values", storage: storage)) else {
                    throw TimingError.parseFailure(
                        format: "Liberty",
                        line: self.line(tableNode),
                        message: "Power table has no values."
                    )
                }
                let values = try self.values(
                    from: valuesNode.arguments,
                    field: "values",
                    line: self.line(valuesNode)
                )
                guard let first = values.first else {
                    throw TimingError.parseFailure(
                        format: "Liberty",
                        line: self.line(valuesNode),
                        message: "Power table has no numeric values."
                    )
                }
                internalPower = first * powerUnitScale
                break
            }
            if internalPower != nil { break }
        }
        // This temporary numerical container is replaced with complete source definitions at every Liberty intake.
        let sequentialNode = ffNode ?? latchNode
        let dataPin = try sequentialNode.flatMap { try self.pinName(from: (try $0.attribute(named: ffNode != nil ? "next_state" : "data_in", storage: storage))) }
        let clockPin = try sequentialNode.flatMap { try self.pinName(from: (try $0.attribute(named: ffNode != nil ? "clocked_on" : "enable", storage: storage))) }
        if strict, let expression = (try ffNode?.attribute(named: "clocked_on", storage: storage)), let clockPin,
           expression != clockPin && expression != "!" + clockPin {
            throw TimingCharacterizationError.unsupportedSemantic("compound sequential clock expression")
        }
        var outputPin: String?
        for pin in pins {
            try storage?.step()
            if pin.direction == .output { outputPin = pin.name; break }
        }
        var arcs = LibertyBuffer<TimingArc>()
        var checks = LibertyBuffer<TimingCheckArc>()
        var setup: Double?
        var hold: Double?
        var recovery: Double?
        var removal: Double?
        var minPulseWidth: Double?
        var pulseWidths = LibertyBuffer<TimingPulseWidthConstraint>()
        var controlArcs = LibertyBuffer<TimingDirectionalControlArc>()
        var clockToQ: TimingArc?
        var clockToQEdge: TimingEdge?
        var timingOrdinal = 0

        func declaredPin(_ name: String, direction: TimingPin.Direction? = nil) throws -> Bool {
            for pin in pins {
                try checkText(pin.name); try checkText(name)
                if pin.name == name, direction == nil || pin.direction == direction { return true }
            }
            return false
        }

        for pinNode in node.children {
            try checkText(pinNode.name)
            guard pinNode.name == "pin" else { continue }
            guard let destination = pinNode.arguments.first else { continue }
            for (attribute, edge) in [("min_pulse_width_high", TimingEdge.rise), ("min_pulse_width_low", .fall)] {
                if let fact = try uniqueChild(pinNode, named: attribute, required: false) {
                    guard let raw = try optionalNumber(fact.value, field: attribute, line: line(fact)), raw >= 0,
                          (raw * timeUnitScale).isFinite else { throw TimingCharacterizationError.invalidValue("pulse width attribute") }
                    var tableIdentity = LibertyBuffer<LibertyTimingTableIdentity>()
                    try tableIdentity.append(.init(name: attribute, line: fact.sourceLine, byteOffset: fact.byteOffset), storage: storage)
                    let identity = LibertyTimingSourceIdentity(cell: node.arguments.first ?? "cell", pin: destination,
                        timingType: nil, line: fact.sourceLine, byteOffset: fact.byteOffset, ordinal: 0,
                        tables: try tableIdentity.array(storage: storage))
                    let value = raw * timeUnitScale
                    try pulseWidths.append(.init(pin: destination, openingEdge: edge, limit: .scalar(value), sourceIdentity: identity), storage: storage)
                    minPulseWidth = max(minPulseWidth ?? value, value)
                }
            }
            for timingNode in pinNode.children {
            try checkText(timingNode.name)
            guard timingNode.name == "timing" else { continue }
                let ordinal = timingOrdinal
                timingOrdinal = try LibertyParseStorage.add(timingOrdinal, 1)
                let timingType = try cleanedText((try timingNode.attribute(named: "timing_type", storage: storage)) ?? "", lowercase: true)
                if strict, !strictPropagation, !strictSequentialPropagation,
                   timingType != "min_pulse_width", timingType != "clear", timingType != "preset" { continue }
                if strict || timingType == "min_pulse_width" {
                    _ = try self.uniqueChild(timingNode, named: "related_pin", required: true)
                }
                guard let related = try (try timingNode.attribute(named: "related_pin", storage: storage)).flatMap(self.pinName) else {
                    if timingType == "min_pulse_width" { throw TimingCharacterizationError.missingSourceFact("pulse related pin") }
                    continue
                }
                let identity = try timingIdentity(timingNode, cell: node.arguments.first ?? "cell", pin: destination,
                    timingType: timingType.isEmpty ? nil : timingType, ordinal: ordinal)
                try rejectConditionalTiming(timingNode, strict: strict)
                let checkKind: TimingCheckArc.Kind?
                let checkEdge: TimingEdge
                switch timingType {
                case "setup_rising": checkKind = .setup; checkEdge = .rise
                case "setup_falling": checkKind = .setup; checkEdge = .fall
                case "hold_rising": checkKind = .hold; checkEdge = .rise
                case "hold_falling": checkKind = .hold; checkEdge = .fall
                case "recovery_rising": checkKind = .recovery; checkEdge = .rise
                case "recovery_falling": checkKind = .recovery; checkEdge = .fall
                case "removal_rising": checkKind = .removal; checkEdge = .rise
                case "removal_falling": checkKind = .removal; checkEdge = .fall
                default: checkKind = nil; checkEdge = .rise
                }
                if let checkKind {
                    var found = false
                    for (name, edge) in [("rise_constraint", TimingEdge.rise), ("fall_constraint", .fall)] {
                        if let table = try optionalTable(node: timingNode, name: name, scale: timeUnitScale,
                            capacitanceScale: timeUnitScale, templates: templates, strict: strict, constraintAxes: true) {
                            found = true
                            try checks.append(.init(kind: checkKind, constrainedPin: destination,
                                relatedPin: related, relatedEdge: checkEdge, constrainedEdge: edge, table: table, sourceIdentity: identity), storage: storage)
                            // Compatibility summary is not native measurement or source-presence evidence.
                            let value = table.values[0][0]
                            switch checkKind {
                            case .setup: setup = max(setup ?? value, value)
                            case .hold: hold = max(hold ?? value, value)
                            case .recovery: recovery = max(recovery ?? value, value)
                            case .removal: removal = max(removal ?? value, value)
                            }
                        }
                    }
                    guard found else { throw TimingError.parseFailure(format: "Liberty", line: line(timingNode), message: "Timing check has no constraint table") }
                    continue
                }
                if timingType == "min_pulse_width" {
                    guard try timingNode.attribute(named: "related_pin", storage: storage) == related,
                          try declaredPin(related) else {
                        throw TimingCharacterizationError.unsupportedSemantic("pulse related pin")
                    }
                    let relatedOutput = try uniqueChild(timingNode, named: "related_output_pin", required: false)?.value
                    if let relatedOutput {
                        try checkText(relatedOutput)
                        guard try declaredPin(relatedOutput, direction: .output) else {
                            throw TimingCharacterizationError.unsupportedSemantic("pulse related output pin")
                        }
                    }
                    var found = false
                    for (name, edge) in [("rise_constraint", TimingEdge.rise), ("fall_constraint", .fall)] {
                        if let table = try uniqueChild(timingNode, named: name, required: false) {
                            found = true
                            let limit = try pulseWidthLimit(table, scale: timeUnitScale, templates: templates)
                            try pulseWidths.append(.init(pin: destination, relatedPin: related, relatedOutputPin: relatedOutput,
                                openingEdge: edge, limit: limit, sourceIdentity: identity), storage: storage)
                            if case .scalar(let value) = limit { minPulseWidth = max(minPulseWidth ?? value, value) }
                        }
                    }
                    guard found else { throw TimingCharacterizationError.missingSourceFact("pulse constraint table") }
                    continue
                }

                if let kind = TimingDirectionalControlArc.Kind(rawValue: timingType) {
                    guard try timingNode.attribute(named: "related_pin", storage: storage) == related,
                          try declaredPin(related, direction: .input),
                          try declaredPin(destination, direction: .output) else {
                        throw TimingCharacterizationError.unsupportedSemantic("directional control arc pins")
                    }
                    let sense: TimingSense?
                    if let value = try uniqueChild(timingNode, named: "timing_sense", required: false)?.value {
                        try checkText(value)
                        switch value {
                        case "positive_unate": sense = .positiveUnate
                        case "negative_unate": sense = .negativeUnate
                        case "non_unate": sense = .nonUnate
                        default: throw TimingCharacterizationError.unsupportedSemantic("directional control timing sense")
                        }
                    } else { sense = nil }
                    for name in ["cell_rise", "cell_fall", "rise_transition", "fall_transition"] {
                        _ = try uniqueChild(timingNode, named: name, required: false)
                    }
                    let rise = try optionalTable(node: timingNode, name: "cell_rise", scale: timeUnitScale,
                        capacitanceScale: capacitanceUnitScale, templates: templates, strict: strict)
                    let fall = try optionalTable(node: timingNode, name: "cell_fall", scale: timeUnitScale,
                        capacitanceScale: capacitanceUnitScale, templates: templates, strict: strict)
                    let riseSlew = try optionalTable(node: timingNode, name: "rise_transition", scale: timeUnitScale,
                        capacitanceScale: capacitanceUnitScale, templates: templates, strict: strict)
                    let fallSlew = try optionalTable(node: timingNode, name: "fall_transition", scale: timeUnitScale,
                        capacitanceScale: capacitanceUnitScale, templates: templates, strict: strict)
                    guard rise != nil || fall != nil || riseSlew != nil || fallSlew != nil else {
                        throw TimingCharacterizationError.missingSourceFact("directional control tables")
                    }
                    try controlArcs.append(.init(kind: kind, fromPin: related, toPin: destination, sense: sense,
                        delayRise: rise, delayFall: fall, transitionRise: riseSlew, transitionFall: fallSlew,
                        sourceIdentity: identity), storage: storage)
                    continue
                }

                guard let arc = try parseArc(
                    timingNode,
                    from: related,
                    to: destination,
                    timeUnitScale: timeUnitScale,
                    capacitanceUnitScale: capacitanceUnitScale,
                    templates: templates,
                    strict: strict, sequentialPropagation: strictSequentialPropagation, latchPropagation: latchNode != nil, sourceIdentity: identity
                ) else {
                    continue
                }
                if strict {
                    guard pins.contains(where: { $0.name == related && $0.direction == .input }),
                          pins.contains(where: { $0.name == destination && $0.direction == .output }) else {
                        throw TimingCharacterizationError.unsupportedSemantic("propagation arc pin directions")
                    }
                    guard !arcs.contains(where: { $0.fromPin == related && $0.toPin == destination }) else {
                        throw TimingCharacterizationError.ambiguousSource("propagation arc \(related)->\(destination)")
                    }
                }
                try arcs.append(arc, storage: storage)
                try checkText(related); try checkText(destination)
                if let clockPin { try checkText(clockPin) }
                if let outputPin { try checkText(outputPin) }
                if let clockPin, let outputPin, related == clockPin, destination == outputPin,
                   try (contains(timingType, "edge") || contains(timingType, "propagation")) {
                    clockToQ = arc
                    clockToQEdge = timingType == "rising_edge" ? .rise : timingType == "falling_edge" ? .fall : nil
                }
            }
        }

        if strictPropagation, arcs.isEmpty {
            throw TimingCharacterizationError.missingSourceFact("propagation arc")
        }
        let sequential: TimingSequentialModel?
        if let dataPin, let clockPin, let outputPin {
            sequential = TimingSequentialModel(
                dataPin: dataPin,
                clockPin: clockPin,
                outputPin: outputPin,
                clockToQ: clockToQ,
                setupTime: setup ?? 0,
                holdTime: hold ?? 0,
                recoveryTime: recovery,
                removalTime: removal,
                minPulseWidth: minPulseWidth,
                timingChecks: try checks.array(storage: storage),
                clockEdge: (try ffNode?.attribute(named: "clocked_on", storage: storage)).map { $0.hasPrefix("!") || $0.hasSuffix("'") ? .fall : .rise }, clockToQEdge: clockToQEdge
            )
        } else {
            sequential = nil
        }

        var normalizedPins = LibertyBuffer<TimingPin>()
        for pin in pins {
            try checkText(pin.name)
            if let clockPin { try checkText(clockPin) }
            if let dataPin { try checkText(dataPin) }
            try normalizedPins.append(TimingPin(
                name: pin.name, direction: pin.direction, capacitance: pin.capacitance,
                maxCapacitance: pin.maxCapacitance, function: pin.function,
                isClock: pin.isClock || pin.name == clockPin, isData: pin.name == dataPin
            ), storage: storage)
        }

        return TimingCell(
            name: node.arguments.first ?? "cell",
            area: try self.optionalNumber(
                (try node.attribute(named: "area", storage: storage)),
                field: "area",
                line: self.line(try node.child(named: "area", storage: storage), fallback: node)
            ),
            pins: try normalizedPins.array(storage: storage),
            arcs: try arcs.array(storage: storage),
            sequentialModel: sequential,
            powerModel: TimingPowerModel(leakagePower: leakagePower, internalPower: internalPower),
            pulseWidthConstraints: try pulseWidths.array(storage: storage),
            directionalControlArcs: try controlArcs.array(storage: storage)
        )
    }

    private func pulseWidthLimit(_ table: LibertyNode, scale: Double,
                                 templates: LibertyMap<LibertyNode>) throws -> TimingPulseWidthConstraint.Limit {
        guard table.arguments.count == 1, let templateName = table.arguments.first else {
            throw TimingCharacterizationError.missingSourceFact("pulse table template")
        }
        let template = try templates.value(for: templateName, storage: storage)
        for fact in ["index_2", "index_3", "variable_2", "variable_3"] {
            if try table.child(named: fact, storage: storage) != nil || template?.child(named: fact, storage: storage) != nil {
                throw TimingCharacterizationError.unsupportedSemantic("multidimensional pulse constraint")
            }
        }
        guard let valueNode = try uniqueChild(table, named: "values", required: true) else {
            throw TimingCharacterizationError.missingSourceFact("pulse constraint values")
        }
        let rawValues = try values(from: valueNode.arguments, field: "values", line: line(valueNode))
        if templateName == "scalar", template == nil {
            guard try table.child(named: "index_1", storage: storage) == nil, rawValues.count == 1,
                  rawValues[0] >= 0, (rawValues[0] * scale).isFinite else {
                throw TimingCharacterizationError.invalidValue("scalar pulse constraint")
            }
            return .scalar(rawValues[0] * scale)
        }
        guard let template,
              try uniqueChild(template, named: "variable_1", required: true)?.value == "related_pin_transition" else {
            throw TimingCharacterizationError.unsupportedSemantic("pulse constraint axis")
        }
        let explicitIndex = try uniqueChild(table, named: "index_1", required: false)
        let inheritedIndex = try uniqueChild(template, named: "index_1", required: false)
        guard let index = explicitIndex ?? inheritedIndex else { throw TimingCharacterizationError.missingSourceFact("pulse constraint index") }
        let rawAxis = try values(from: index.arguments, field: "index_1", line: line(index))
        guard !rawAxis.isEmpty, rawValues.count == rawAxis.count, valueNode.arguments.count == 1 else {
            throw TimingCharacterizationError.invalidValue("pulse constraint dimensions")
        }
        var axis = LibertyBuffer<Double>()
        var rows = LibertyBuffer<[Double]>()
        for i in rawAxis.indices {
            try storage?.step()
            guard rawAxis[i] >= 0, rawValues[i] >= 0 else { throw TimingCharacterizationError.invalidValue("pulse constraint values") }
            try axis.append(rawAxis[i] * scale, storage: storage)
            var row = LibertyBuffer<Double>()
            try row.append(rawValues[i] * scale, storage: storage)
            try rows.append(row.array(storage: storage), storage: storage)
        }
        var coordinate = LibertyBuffer<Double>()
        try coordinate.append(0, storage: storage)
        let lut = try TimingLUT(inputSlews: axis.array(storage: storage), outputLoads: coordinate.array(storage: storage),
            values: rows.array(storage: storage), checking: { try storage?.step() })
        return .relatedPinTransition(lut)
    }

    private func parseArc(
        _ node: LibertyNode,
        from: String,
        to: String,
        timeUnitScale: Double,
        capacitanceUnitScale: Double,
        templates: LibertyMap<LibertyNode>,
        strict: Bool, sequentialPropagation: Bool = false, latchPropagation: Bool = false,
        sourceIdentity: LibertyTimingSourceIdentity? = nil
    ) throws -> TimingArc? {
        try rejectConditionalTiming(node, strict: strict)
        if strict {
            let timingType = (try node.attribute(named: "timing_type", storage: storage))
            guard (sequentialPropagation ? (timingType == "rising_edge" || timingType == "falling_edge" || (latchPropagation && timingType == "combinational")) : (timingType == nil || timingType == "combinational")),
                  (try node.child(named: "when", storage: storage)) == nil,
                  (try node.child(named: "sdf_cond", storage: storage)) == nil,
                  (try node.child(named: "mode", storage: storage)) == nil,
                  (try node.child(named: "when_start", storage: storage)) == nil, (try node.child(named: "when_end", storage: storage)) == nil,
                  (try node.attribute(named: "related_pin", storage: storage)) == from else {
                throw TimingCharacterizationError.unsupportedSemantic("conditional or non-combinational propagation arc")
            }
            _ = try self.uniqueChild(node, named: "timing_sense", required: true)
            guard ["positive_unate", "negative_unate", "non_unate"].contains((try node.attribute(named: "timing_sense", storage: storage)) ?? "") else {
                throw TimingCharacterizationError.unsupportedSemantic("timing_sense")
            }
            for fact in ["cell_rise", "cell_fall", "rise_transition", "fall_transition"] {
                _ = try self.uniqueChild(node, named: fact, required: true)
            }
        }
        let senseValue = try cleanedText((try node.attribute(named: "timing_sense", storage: storage)) ?? "positive_unate", lowercase: true)
        let sense: TimingSense
        switch senseValue {
        case "negative_unate":
            sense = .negativeUnate
        case "non_unate":
            sense = .nonUnate
        default:
            sense = .positiveUnate
        }
        guard let rise = try optionalTable(node: node, name: "cell_rise", scale: timeUnitScale, capacitanceScale: capacitanceUnitScale, templates: templates, strict: strict),
              let fall = try optionalTable(node: node, name: "cell_fall", scale: timeUnitScale, capacitanceScale: capacitanceUnitScale, templates: templates, strict: strict) else {
            return nil
        }
        let riseTransition = try optionalTable(node: node, name: "rise_transition", scale: timeUnitScale, capacitanceScale: capacitanceUnitScale, templates: templates, strict: strict) ?? rise
        let fallTransition = try optionalTable(node: node, name: "fall_transition", scale: timeUnitScale, capacitanceScale: capacitanceUnitScale, templates: templates, strict: strict) ?? fall
        return TimingArc(
            fromPin: from,
            toPin: to,
            sense: sense,
            delayRise: rise,
            delayFall: fall,
            transitionRise: riseTransition,
            transitionFall: fallTransition,
            isConstraint: false, sourceIdentity: sourceIdentity
        )
    }

    private func timingIdentity(_ node: LibertyNode, cell: String, pin: String, timingType: String?, ordinal: Int) throws -> LibertyTimingSourceIdentity {
        var tables = LibertyBuffer<LibertyTimingTableIdentity>()
        for child in node.children {
            try checkText(child.name)
            if ["cell_rise", "cell_fall", "rise_transition", "fall_transition", "rise_constraint", "fall_constraint"].contains(child.name) {
                try tables.append(.init(name: child.name, line: child.sourceLine, byteOffset: child.byteOffset), storage: storage)
            }
        }
        return .init(cell: cell, pin: pin, timingType: timingType, line: node.sourceLine, byteOffset: node.byteOffset,
            ordinal: ordinal, tables: try tables.array(storage: storage))
    }

    private func rejectConditionalTiming(_ node: LibertyNode, strict: Bool) throws {
        for child in node.children {
            try storage?.step()
            if child.name == "when" || child.name == "sdf_cond" || child.name == "mode"
                || child.name == "when_start" || child.name == "when_end" {
                let reason = "conditional timing arc: " + child.name + " at line " + String(line(child))
                if strict { throw TimingCharacterizationError.unsupportedSemantic(reason) }
                throw TimingError.unsupportedSemantic(format: "Liberty", semantic: reason)
            }
        }
    }

    private func optionalTable(
        node: LibertyNode, name: String, scale: Double, capacitanceScale: Double,
        templates: LibertyMap<LibertyNode> = .init(), strict: Bool = false, constraintAxes: Bool = false
    ) throws -> TimingLUT? {
        guard let tableNode = try node.child(named: name, storage: storage) else { return nil }
        let template = try tableNode.arguments.first.flatMap { try templates.value(for: $0, storage: storage) }
        var transposed = false
        if constraintAxes {
            guard (try tableNode.child(named: "index_3", storage: storage)) == nil,
                  (try template?.child(named: "index_3", storage: storage)) == nil,
                  (try template?.child(named: "variable_3", storage: storage)) == nil else {
                throw TimingError.unsupportedSemantic(format: "Liberty", semantic: "three-dimensional sequential constraint at line " + String(line(tableNode)))
            }
        }
        if strict {
            guard let template else {
                throw TimingCharacterizationError.missingSourceFact("template for \(name)")
            }
            for fact in ["variable_1", "variable_2"] {
                _ = try self.uniqueChild(template, named: fact, required: true)
            }
            guard (try template.child(named: "variable_3", storage: storage)) == nil,
                  (try template.child(named: "index_3", storage: storage)) == nil, (try tableNode.child(named: "index_3", storage: storage)) == nil else {
                throw TimingCharacterizationError.unsupportedSemantic("three-dimensional \(name)")
            }
            for fact in ["index_1", "index_2", "values"] {
                _ = try self.uniqueChild(tableNode, named: fact, required: fact == "values")
            }
        }
        if let template {
            let firstVariable = try template.attribute(named: "variable_1", storage: storage)
            let secondVariable = try template.attribute(named: "variable_2", storage: storage)
            if let firstVariable { try checkText(firstVariable) }
            if let secondVariable { try checkText(secondVariable) }
            if constraintAxes {
                if firstVariable == "related_pin_transition", secondVariable == "constrained_pin_transition" || secondVariable == nil {
                    transposed = true
                } else if firstVariable == "constrained_pin_transition", secondVariable == "related_pin_transition" || secondVariable == nil {
                    transposed = false
                } else if firstVariable == nil, secondVariable == nil {
                    transposed = false
                } else {
                    throw TimingError.unsupportedSemantic(format: "Liberty", semantic: "sequential constraint axes at line " + String(line(tableNode)))
                }
            } else if firstVariable == "total_output_net_capacitance", secondVariable == "input_net_transition" {
                transposed = true
            } else if strict, firstVariable != "input_net_transition" || secondVariable != "total_output_net_capacitance" {
                throw TimingCharacterizationError.unsupportedSemantic("template variables for \(name)")
            }
        }
        let index1Node = try (tableNode.child(named: "index_1", storage: storage) ?? template?.child(named: "index_1", storage: storage))
        let index2Node = try (tableNode.child(named: "index_2", storage: storage) ?? template?.child(named: "index_2", storage: storage))
        if strict {
            guard index1Node != nil, index2Node != nil else {
                throw TimingCharacterizationError.missingSourceFact("indexes for \(name)")
            }
            for fact in ["index_1", "index_2"] {
                if (try tableNode.child(named: fact, storage: storage)) == nil, let template {
                    _ = try self.uniqueChild(template, named: fact, required: true)
                }
            }
        }
        let valuesNode = (try tableNode.child(named: "values", storage: storage))
        let index1 = try index1Node.map {
            try self.values(
                from: $0.arguments,
                field: "index_1",
                line: self.line($0)
            )
        } ?? []
        let index2 = try index2Node.map {
            try self.values(
                from: $0.arguments,
                field: "index_2",
                line: self.line($0)
            )
        } ?? []
        guard let valuesNode else {
            throw TimingError.parseFailure(
                format: "Liberty",
                line: self.line(tableNode),
                message: "Timing table has no values."
            )
        }
        let rows = try self.values(
            from: valuesNode.arguments,
            field: "values",
            line: self.line(valuesNode)
        )
        if strict {
            guard !index1.isEmpty, !index2.isEmpty,
                  (index1 + index2).allSatisfy({ $0 >= 0 }),
                  constraintAxes || rows.allSatisfy({ $0 >= 0 }) else {
                throw TimingCharacterizationError.invalidValue("indexes or values for \(name)")
            }
        }
        func scaledAxis(_ source: [Double], multiplier: Double) throws -> [Double] {
            var output = LibertyBuffer<Double>()
            if source.isEmpty { try output.append(0, storage: storage) }
            for value in source { try storage?.step(); try output.append(value * multiplier, storage: storage) }
            return try output.array(storage: storage)
        }
        let actualIndex1 = try scaledAxis(index1, multiplier: transposed ? capacitanceScale : scale)
        let actualIndex2 = try scaledAxis(index2, multiplier: transposed ? scale : capacitanceScale)
        let (elementCount, overflow) = actualIndex1.count.multipliedReportingOverflow(by: actualIndex2.count)
        guard !overflow else { throw LibertySourceError.arithmeticOverflow }
        guard rows.count == elementCount else {
            throw TimingError.parseFailure(format: "Liberty", line: self.line(tableNode), message: "Table dimensions do not match values.")
        }
        if strict {
            guard valuesNode.arguments.count == actualIndex1.count else {
                throw TimingCharacterizationError.invalidValue("row count for \(name)")
            }
            for row in valuesNode.arguments {
                guard try self.values(from: [row], field: "values", line: self.line(valuesNode)).count == actualIndex2.count else {
                    throw TimingCharacterizationError.invalidValue("row width for \(name)")
                }
            }
        }
        var matrix = LibertyBuffer<[Double]>()
        let rowKind: LibertySourceStorageKind = transposed ? .temporaryBytes : .liveOwnedBytes
        for row in 0..<actualIndex1.count {
            var output = LibertyBuffer<Double>()
            for column in 0..<actualIndex2.count {
                try storage?.step()
                try output.append(rows[row * actualIndex2.count + column] * scale, storage: storage)
            }
            try matrix.append(output.array(storage: storage, kind: rowKind), storage: storage)
        }
        let normalized = try matrix.array(storage: storage, kind: rowKind)
        let finalValues: [[Double]]
        if transposed {
            var output = LibertyBuffer<[Double]>()
            for column in 0..<actualIndex2.count {
                var row = LibertyBuffer<Double>()
                for index in 0..<actualIndex1.count {
                    try storage?.step(); try row.append(normalized[index][column], storage: storage)
                }
                try output.append(row.array(storage: storage), storage: storage)
            }
            finalValues = try output.array(storage: storage)
        } else { finalValues = normalized }
        return try TimingLUT(inputSlews: transposed ? actualIndex2 : actualIndex1,
            outputLoads: transposed ? actualIndex1 : actualIndex2, values: finalValues,
            checking: { try storage?.step() })
    }

    internal func thresholds(_ library: LibertyNode) throws -> TimingCharacterizationThresholds {
        func percentage(_ name: String) throws -> Double {
            let node = try uniqueChild(library, named: name, required: false)
            let defaultValue = name.hasPrefix("slew_lower") ? 20.0 : name.hasPrefix("slew_upper") ? 80.0 : 50.0
            guard let value = node == nil ? defaultValue : node?.value.flatMap(Double.init), value.isFinite,
                  value > 0, value < 100 else {
                throw TimingCharacterizationError.invalidValue(name)
            }
            return value
        }
        let result = try TimingCharacterizationThresholds(
            inputRise: percentage("input_threshold_pct_rise"),
            inputFall: percentage("input_threshold_pct_fall"),
            outputRise: percentage("output_threshold_pct_rise"),
            outputFall: percentage("output_threshold_pct_fall"),
            slewLowerRise: percentage("slew_lower_threshold_pct_rise"),
            slewUpperRise: percentage("slew_upper_threshold_pct_rise"),
            slewLowerFall: percentage("slew_lower_threshold_pct_fall"),
            slewUpperFall: percentage("slew_upper_threshold_pct_fall")
        )
        guard result.slewLowerRise < result.slewUpperRise,
              result.slewLowerFall < result.slewUpperFall else {
            throw TimingCharacterizationError.invalidValue("slew threshold ordering")
        }
        if let derate = try uniqueChild(library, named: "slew_derate_from_library", required: false),
           derate.value.flatMap(Double.init) != 1 {
            throw TimingCharacterizationError.unsupportedSemantic("slew_derate_from_library")
        }
        return result
    }

    private func uniqueChild(_ node: LibertyNode, named name: String, required: Bool) throws -> LibertyNode? {
        var found: LibertyNode?
        for child in node.children {
            try checkText(child.name); try checkText(name)
            guard child.name == name else { continue }
            guard found == nil else { throw TimingCharacterizationError.ambiguousSource(name) }
            found = child
        }
        if required, found == nil { throw TimingCharacterizationError.missingSourceFact(name) }
        return found
    }

    private enum UnitDimension {
        case time
        case power
    }

    private func unitScale(
        from value: String,
        dimension: UnitDimension,
        line: Int
    ) throws -> Double {
        let cleaned = try cleanedText(value, lowercase: true)
        try checkText(cleaned)
        let suffixStart = cleaned.firstIndex { character in
            !(character.isNumber
                || character == "."
                || character == "-"
                || character == "+"
                || character == "e")
        }
        let numericText = try suffixStart.map { try copyText(cleaned[..<$0], kind: .temporaryBytes) } ?? cleaned
        let suffix = suffixStart.map { cleaned[$0...] } ?? ""
        try checkText(numericText)
        guard let number = Double(numericText), number.isFinite, number > 0 else {
            throw TimingError.parseFailure(
                format: "Liberty",
                line: line,
                message: "Unit scale must contain a finite positive number."
            )
        }
        switch (dimension, suffix) {
        case (.time, "s"): return number
        case (.time, "ms"): return number * 1e-3
        case (.time, "us"): return number * 1e-6
        case (.time, "ns"): return number * 1e-9
        case (.time, "ps"): return number * 1e-12
        case (.time, "fs"): return number * 1e-15
        case (.power, "w"): return number
        case (.power, "mw"): return number * 1e-3
        case (.power, "uw"): return number * 1e-6
        case (.power, "nw"): return number * 1e-9
        case (.power, "pw"): return number * 1e-12
        default:
            throw TimingError.parseFailure(
                format: "Liberty",
                line: line,
                message: storage == nil ? "Unsupported unit suffix '\(suffix)'." : "Unsupported unit suffix."
            )
        }
    }

    private func capacitanceScale(from node: LibertyNode?) throws -> Double {
        guard let node else { return 1 }
        guard node.arguments.count == 2,
              let value = try number(node.arguments[0]),
              value.isFinite,
              value > 0 else {
            throw TimingError.parseFailure(
                format: "Liberty",
                line: self.line(node),
                message: "capacitive_load_unit requires a finite positive scale and a unit."
            )
        }
        let unit = try cleanedText(node.arguments[1], lowercase: true, trim: false)
        let multiplier: Double
        switch unit {
        case "f": multiplier = 1
        case "mf": multiplier = 1e-3
        case "uf": multiplier = 1e-6
        case "nf": multiplier = 1e-9
        case "pf": multiplier = 1e-12
        case "ff": multiplier = 1e-15
        default:
            throw TimingError.parseFailure(
                format: "Liberty",
                line: self.line(node),
                message: storage == nil ? "Unsupported capacitance unit '\(unit)'." : "Unsupported capacitance unit."
            )
        }
        return value * multiplier
    }

    private func number(_ value: String) throws -> Double? {
        let cleaned = try cleanedText(value)
        try checkText(cleaned)
        if let direct = Double(cleaned) { return direct }
        let suffixLease = try storage?.reserve(String.self, capacity: 11, kind: .temporaryBytes)
        let suffixes = ["ms", "us", "ns", "ps", "fs", "s", "mf", "uf", "nf", "pf", "ff"]
        if let storage, let suffixLease { try storage.hold(suffixes, receipt: suffixLease, kind: .temporaryBytes) }
        let lower = try cleanedText(cleaned, lowercase: true, trim: false)
        for suffix in suffixes {
            try checkText(lower)
            guard lower.hasSuffix(suffix) else { continue }
            return Double(cleaned.dropLast(suffix.count))
        }
        return nil
    }

    private func optionalNumber(
        _ value: String?,
        field: String,
        line: Int
    ) throws -> Double? {
        guard let value else { return nil }
        guard let parsed = try number(value), parsed.isFinite else {
            throw TimingError.parseFailure(
                format: "Liberty",
                line: line,
                message: storage == nil ? "\(field) contains an invalid numeric value." : "Invalid numeric value."
            )
        }
        return parsed
    }

    private func values(
        from arguments: [String],
        field: String,
        line: Int
    ) throws -> [Double] {
        var output = LibertyBuffer<Double>()
        var token = LibertyText()
        func flush() throws {
            guard !token.isEmpty else { return }
            let text = try token.string(storage: storage, kind: .temporaryBytes)
            try checkText(text)
            guard let value = Double(text), value.isFinite else {
                throw TimingError.parseFailure(format: "Liberty", line: line,
                    message: storage == nil ? "\(field) contains an invalid numeric value '\(text)'." : "Invalid numeric value.")
            }
            try output.append(value, storage: storage); token = LibertyText()
        }
        for argument in arguments {
            // A comma separates original arguments exactly as the legacy joined string did.
            try flush()
            for character in argument {
                try storage?.step()
                if character == "\"" { continue }
                if character == "," || character.isWhitespace { try flush() }
                else { try token.append(character, storage: storage) }
            }
        }
        try flush()
        return try output.array(storage: storage, kind: .temporaryBytes)
    }

    private func pinName(from expression: String?) throws -> String? {
        guard let expression else { return nil }
        let cleaned = try cleanedText(expression, trim: false)
        var start: String.Index?
        var last: Range<String.Index>?
        var cursor = cleaned.startIndex
        while cursor != cleaned.endIndex {
            try storage?.step()
            let character = cleaned[cursor]
            if character.isLetter || character.isNumber || character == "_" {
                if start == nil { start = cursor }
            } else if let begin = start {
                last = begin..<cursor; start = nil
            }
            cursor = cleaned.index(after: cursor)
        }
        if let begin = start { last = begin..<cursor }
        if let last { return try copyText(cleaned[last]) }; return nil
    }

    private func line(_ node: LibertyNode) -> Int {
        storage == nil ? node.line : node.sourceLine
    }

    private func line(_ node: LibertyNode?, fallback: LibertyNode) -> Int {
        line(node ?? fallback)
    }

    private func contains(_ text: String, _ pattern: String) throws -> Bool {
        try checkText(text); return text.contains(pattern)
    }

    internal func checkText(_ text: String) throws {
        try storage?.step()
        for _ in text.utf8 { try storage?.step() }
    }

    private func copyText(_ text: Substring, kind: LibertySourceStorageKind = .liveOwnedBytes) throws -> String {
        guard let storage else { return String(text) }
        var count = 0
        for _ in text.utf8 { try storage.step(); count = try LibertyParseStorage.add(count, 1) }
        let lease = try storage.reserve(UInt8.self, capacity: count, kind: kind)
        try storage.step(UInt64(count))
        let output = String(decoding: text.utf8, as: UTF8.self)
        try storage.hold(output, receipt: lease, kind: kind); return output
    }

    private func cleanedText(_ text: String, lowercase: Bool = false, trim: Bool = true) throws -> String {
        guard let storage else {
            let cleaned = text.replacingOccurrences(of: "\"", with: "")
            let trimmed = trim ? cleaned.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
            return lowercase ? trimmed.lowercased() : trimmed
        }
        var bytes = LibertyBuffer<UInt8>()
        for byte in text.utf8 {
            try storage.step(); guard byte != 34 else { continue }
            try bytes.append(lowercase && byte >= 65 && byte <= 90 ? byte + 32 : byte, storage: storage)
        }
        var first = 0, last = bytes.count
        if trim {
            while first < last && (bytes[first] == 32 || (9...13).contains(bytes[first])) { try storage.step(); first += 1 }
            while last > first && (bytes[last - 1] == 32 || (9...13).contains(bytes[last - 1])) { try storage.step(); last -= 1 }
        }
        let lease = try storage.reserve(UInt8.self, capacity: last - first, kind: .temporaryBytes)
        var outputBytes = [UInt8](); outputBytes.reserveCapacity(last - first)
        for index in first..<last { try storage.step(); outputBytes.append(bytes[index]) }
        try storage.hold(outputBytes, receipt: lease, kind: .temporaryBytes)
        let textLease = try storage.reserve(UInt8.self, capacity: outputBytes.count, kind: .temporaryBytes)
        try storage.step(UInt64(outputBytes.count))
        let output = String(decoding: outputBytes, as: UTF8.self)
        try storage.hold(output, receipt: textLease, kind: .temporaryBytes); return output
    }
}

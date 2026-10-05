import Foundation

public struct LibertyParser: TimingLibraryParsing, TimingCharacterizationParsing {
    public init() {}

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
        guard let libraryNode = root.first(where: { $0.name == "library" }) else {
            throw TimingError.parseFailure(format: "Liberty", line: 1, message: "No library group was found.")
        }

        if strictCells != nil {
            guard root.filter({ $0.name == "library" }).count == 1 else {
                throw TimingCharacterizationError.ambiguousSource("library")
            }
            for fact in ["time_unit", "capacitive_load_unit"] {
                _ = try Self.uniqueChild(libraryNode, named: fact, required: fact == "capacitive_load_unit")
            }
        }
        let thresholds = strictCells == nil ? nil : try Self.thresholds(libraryNode)
        let defaultableAttributes = [
            "time_unit", "input_threshold_pct_rise", "input_threshold_pct_fall",
            "output_threshold_pct_rise", "output_threshold_pct_fall",
            "slew_lower_threshold_pct_rise", "slew_lower_threshold_pct_fall",
            "slew_upper_threshold_pct_rise", "slew_upper_threshold_pct_fall", "slew_derate_from_library"
        ]
        let defaults = Set(defaultableAttributes.filter { libraryNode.child(named: $0) == nil })
        let inputCapacitanceDefault = try Self.uniqueChild(libraryNode, named: "default_input_pin_cap", required: false)
        var templates: [String: LibertyNode] = [:]
        for template in libraryNode.children where template.name == "lu_table_template" {
            guard let name = template.arguments.first, templates[name] == nil else {
                throw TimingCharacterizationError.ambiguousSource("lu_table_template")
            }
            templates[name] = template
        }

        let timeUnitScale = try Self.unitScale(
            from: libraryNode.attribute(named: "time_unit") ?? "1ns",
            dimension: .time,
            line: libraryNode.child(named: "time_unit")?.line ?? libraryNode.line
        )
        let capacitanceUnitScale = try Self.capacitanceScale(
            from: libraryNode.children.first(where: {
                $0.name == "capacitive_load_unit"
            })
        )
        let powerUnitScale = try Self.unitScale(
            from: libraryNode.attribute(named: "power_unit") ?? "1W",
            dimension: .power,
            line: libraryNode.child(named: "power_unit")?.line ?? libraryNode.line
        )
        if strictCells != nil {
            guard timeUnitScale.isFinite, timeUnitScale > 0,
                  capacitanceUnitScale.isFinite, capacitanceUnitScale > 0 else {
                throw TimingCharacterizationError.invalidValue("scaled time or capacitance unit")
            }
        }
        var operatingConditions: [String: TimingOperatingCondition] = [:]
        for node in libraryNode.children where node.name == "operating_conditions" {
            let name = node.arguments.first ?? "default"
            operatingConditions[name] = TimingOperatingCondition(
                name: name,
                process: try Self.optionalNumber(
                    node.attribute(named: "process"),
                    field: "process",
                    line: node.child(named: "process")?.line ?? node.line
                ),
                voltage: try Self.optionalNumber(
                    node.attribute(named: "voltage"),
                    field: "voltage",
                    line: node.child(named: "voltage")?.line ?? node.line
                ),
                temperature: try Self.optionalNumber(
                    node.attribute(named: "temperature"),
                    field: "temperature",
                    line: node.child(named: "temperature")?.line ?? node.line
                )
            )
        }

        var cells: [String: TimingCell] = [:]
        var capacitanceSources: [String: [String: TimingCapacitanceSource]] = [:]
        for cellNode in libraryNode.children where cellNode.name == "cell" {
            guard let cellName = cellNode.arguments.first, !cellName.isEmpty else {
                throw TimingError.parseFailure(format: "Liberty", line: cellNode.line, message: "Cell has no name.")
            }
            if let strictCells, !strictCells.contains(cellName) { continue }
            guard cells[cellName] == nil else {
                throw TimingCharacterizationError.ambiguousSource("cell \(cellName)")
            }
            let cell = try parseCell(
                node: cellNode,
                timeUnitScale: timeUnitScale,
                capacitanceUnitScale: capacitanceUnitScale,
                powerUnitScale: powerUnitScale,
                templates: templates,
                strict: strictCells != nil,
                inputCapacitanceDefault: inputCapacitanceDefault,
                strictPropagation: propagationCells.contains(cellName)
            )
            cells[cellName] = cell
            var pinSources: [String: TimingCapacitanceSource] = [:]
            for pin in cellNode.children where pin.name == "pin" && pin.attribute(named: "direction") == "input" {
                if let name = pin.arguments.first {
                    pinSources[name] = pin.child(named: "capacitance") == nil ? .libraryDefaultInputPinCap : .pinAttribute
                }
            }
            capacitanceSources[cellName] = pinSources
        }

        if let strictCells, Set(cells.keys) != strictCells {
            throw TimingCharacterizationError.missingSourceFact("selected cells \(strictCells.subtracting(cells.keys).sorted())")
        }
        guard !cells.isEmpty else {
            throw TimingError.parseFailure(format: "Liberty", line: libraryNode.line, message: "Library contains no cells.")
        }
        return (TimingLibrary(
            name: libraryNode.arguments.first ?? "library",
            timeUnitScale: timeUnitScale,
            capacitanceUnitScale: capacitanceUnitScale,
            powerUnitScale: powerUnitScale,
            cells: cells,
            operatingConditions: operatingConditions
        ), thresholds, defaults, capacitanceSources)
    }

    private func parseCell(
        node: LibertyNode,
        timeUnitScale: Double,
        capacitanceUnitScale: Double,
        powerUnitScale: Double,
        templates: [String: LibertyNode],
        strict: Bool,
        inputCapacitanceDefault: LibertyNode?,
        strictPropagation: Bool
    ) throws -> TimingCell {
        var pins: [TimingPin] = []
        for pinNode in node.children where pinNode.name == "pin" {
            guard let name = pinNode.arguments.first else {
                throw TimingError.parseFailure(format: "Liberty", line: pinNode.line, message: "Pin has no name.")
            }
            if strict {
                guard !pins.contains(where: { $0.name == name }) else {
                    throw TimingCharacterizationError.ambiguousSource("pin \(name)")
                }
                _ = try Self.uniqueChild(pinNode, named: "direction", required: true)
            }
            if strict {
                for fact in ["slew_lower_threshold_pct_rise", "slew_lower_threshold_pct_fall",
                             "slew_upper_threshold_pct_rise", "slew_upper_threshold_pct_fall",
                             "input_threshold_pct_rise", "input_threshold_pct_fall",
                             "output_threshold_pct_rise", "output_threshold_pct_fall"] {
                    guard pinNode.child(named: fact) == nil else {
                        throw TimingCharacterizationError.unsupportedSemantic("pin-level threshold \(name).\(fact)")
                    }
                }
                if let clock = try Self.uniqueChild(pinNode, named: "clock", required: false),
                   clock.value != "true" && clock.value != "false" {
                    throw TimingCharacterizationError.invalidValue("clock pin \(name)")
                }
            }
            let directionValue = pinNode.attribute(named: "direction")
            let direction: TimingPin.Direction
            if let directionValue {
                guard let parsed = TimingPin.Direction(
                    rawValue: directionValue.lowercased()
                ) else {
                    throw TimingError.parseFailure(
                        format: "Liberty",
                        line: pinNode.child(named: "direction")?.line ?? pinNode.line,
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
                    _ = try Self.uniqueChild(pinNode, named: "capacitance", required: inputCapacitanceDefault == nil)
                }
            }
            let pinCapacitance = pinNode.attribute(named: "capacitance")
                ?? (direction == .input ? inputCapacitanceDefault?.value : nil)
            let capacitance = try Self.optionalNumber(
                pinCapacitance,
                field: "capacitance",
                line: pinNode.child(named: "capacitance")?.line ?? pinNode.line
            ).map { $0 * capacitanceUnitScale } ?? 0
            if strict, direction == .input,
               pinCapacitance.flatMap(Double.init) == nil {
                throw TimingCharacterizationError.invalidValue("pin capacitance dimension \(name)")
            }
            if strict, !capacitance.isFinite || capacitance < 0 {
                throw TimingCharacterizationError.invalidValue("pin capacitance \(name)")
            }
            let maxCapacitance = try Self.optionalNumber(
                pinNode.attribute(named: "max_capacitance"),
                field: "max_capacitance",
                line: pinNode.child(named: "max_capacitance")?.line ?? pinNode.line
            ).map { $0 * capacitanceUnitScale }
            pins.append(TimingPin(
                name: name,
                direction: direction,
                capacitance: capacitance,
                maxCapacitance: maxCapacitance,
                function: pinNode.attribute(named: "function"),
                isClock: pinNode.attribute(named: "clock") == "true",
                isData: false
            ))
        }

        if strictPropagation, node.child(named: "ff") != nil || node.child(named: "latch") != nil {
            throw TimingCharacterizationError.unsupportedSemantic("sequential propagation cell")
        }
        let ffNode = node.children.first(where: { $0.name == "ff" })
        let leakagePower = try Self.optionalNumber(
            node.attribute(named: "cell_leakage_power"),
            field: "cell_leakage_power",
            line: node.child(named: "cell_leakage_power")?.line ?? node.line
        ).map { $0 * powerUnitScale }
        var internalPower: Double?
        for powerNode in node.children where powerNode.name == "internal_power" {
            for tableNode in powerNode.children
                where tableNode.name == "rise_power" || tableNode.name == "fall_power" {
                guard let valuesNode = tableNode.child(named: "values") else {
                    throw TimingError.parseFailure(
                        format: "Liberty",
                        line: tableNode.line,
                        message: "Power table has no values."
                    )
                }
                let values = try Self.values(
                    from: valuesNode.arguments,
                    field: "values",
                    line: valuesNode.line
                )
                guard let first = values.first else {
                    throw TimingError.parseFailure(
                        format: "Liberty",
                        line: valuesNode.line,
                        message: "Power table has no numeric values."
                    )
                }
                internalPower = first * powerUnitScale
                break
            }
            if internalPower != nil { break }
        }
        let dataPin = ffNode.flatMap { Self.pinName(from: $0.attribute(named: "next_state")) }
        let clockPin = ffNode.flatMap { Self.pinName(from: $0.attribute(named: "clocked_on")) }
        if strict, let expression = ffNode?.attribute(named: "clocked_on"), let clockPin,
           expression != clockPin && expression != "!" + clockPin {
            throw TimingCharacterizationError.unsupportedSemantic("compound sequential clock expression")
        }
        let outputPin = pins.first(where: { $0.direction == .output })?.name
        var arcs: [TimingArc] = []
        var setup: Double?
        var hold: Double?
        var recovery: Double?
        var removal: Double?
        var minPulseWidth: Double?
        var clockToQ: TimingArc?

        for pinNode in node.children where pinNode.name == "pin" {
            guard let destination = pinNode.arguments.first else { continue }
            for timingNode in pinNode.children where timingNode.name == "timing" {
                if strict, !strictPropagation { continue }
                if strict {
                    _ = try Self.uniqueChild(timingNode, named: "related_pin", required: true)
                }
                guard let related = timingNode.attribute(named: "related_pin").flatMap(Self.pinName) else { continue }
                let timingType = (timingNode.attribute(named: "timing_type") ?? "").lowercased()
                if timingType.contains("setup") {
                    let value = try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale)
                    setup = max(setup ?? value, value)
                    continue
                }
                if timingType.contains("hold") {
                    let value = try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale)
                    hold = max(hold ?? value, value)
                    continue
                }
                if timingType.contains("recovery") {
                    let value = try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale)
                    recovery = max(recovery ?? value, value)
                    continue
                }
                if timingType.contains("removal") {
                    let value = try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale)
                    removal = max(removal ?? value, value)
                    continue
                }
                if timingType.contains("min_pulse_width") {
                    minPulseWidth = max(minPulseWidth ?? 0, try constraintValue(timingNode, timeUnitScale: timeUnitScale, capacitanceUnitScale: capacitanceUnitScale))
                    continue
                }

                guard let arc = try parseArc(
                    timingNode,
                    from: related,
                    to: destination,
                    timeUnitScale: timeUnitScale,
                    capacitanceUnitScale: capacitanceUnitScale,
                    templates: templates,
                    strict: strict
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
                arcs.append(arc)
                if let clockPin, let outputPin, related == clockPin, destination == outputPin,
                   timingType.contains("edge") || timingType.contains("propagation") {
                    clockToQ = arc
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
                minPulseWidth: minPulseWidth
            )
        } else {
            sequential = nil
        }

        let normalizedPins = pins.map { pin in
            TimingPin(
                name: pin.name,
                direction: pin.direction,
                capacitance: pin.capacitance,
                maxCapacitance: pin.maxCapacitance,
                function: pin.function,
                isClock: pin.isClock || pin.name == clockPin,
                isData: pin.name == dataPin
            )
        }
        return TimingCell(
            name: node.arguments.first ?? "cell",
            area: try Self.optionalNumber(
                node.attribute(named: "area"),
                field: "area",
                line: node.child(named: "area")?.line ?? node.line
            ),
            pins: normalizedPins,
            arcs: arcs,
            sequentialModel: sequential,
            powerModel: TimingPowerModel(leakagePower: leakagePower, internalPower: internalPower)
        )
    }

    private func parseArc(
        _ node: LibertyNode,
        from: String,
        to: String,
        timeUnitScale: Double,
        capacitanceUnitScale: Double,
        templates: [String: LibertyNode],
        strict: Bool
    ) throws -> TimingArc? {
        if strict {
            let timingType = node.attribute(named: "timing_type")
            guard timingType == nil || timingType == "combinational",
                  node.child(named: "when") == nil,
                  node.child(named: "sdf_cond") == nil,
                  node.child(named: "mode") == nil,
                  node.child(named: "when_start") == nil, node.child(named: "when_end") == nil,
                  node.attribute(named: "related_pin") == from else {
                throw TimingCharacterizationError.unsupportedSemantic("conditional or non-combinational propagation arc")
            }
            _ = try Self.uniqueChild(node, named: "timing_sense", required: true)
            guard ["positive_unate", "negative_unate", "non_unate"].contains(node.attribute(named: "timing_sense") ?? "") else {
                throw TimingCharacterizationError.unsupportedSemantic("timing_sense")
            }
            for fact in ["cell_rise", "cell_fall", "rise_transition", "fall_transition"] {
                _ = try Self.uniqueChild(node, named: fact, required: true)
            }
        }
        let senseValue = (node.attribute(named: "timing_sense") ?? "positive_unate").lowercased()
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
            isConstraint: false
        )
    }

    private func constraintValue(_ node: LibertyNode, timeUnitScale: Double, capacitanceUnitScale: Double) throws -> Double {
        for name in ["rise_constraint", "fall_constraint", "cell_rise", "cell_fall"] {
            if let table = try optionalTable(node: node, name: name, scale: timeUnitScale, capacitanceScale: capacitanceUnitScale) {
                return table.values[0][0]
            }
        }
        throw TimingError.parseFailure(format: "Liberty", line: node.line, message: "Timing constraint has no supported table.")
    }

    private func optionalTable(
        node: LibertyNode, name: String, scale: Double, capacitanceScale: Double,
        templates: [String: LibertyNode] = [:], strict: Bool = false
    ) throws -> TimingLUT? {
        guard let tableNode = node.children.first(where: { $0.name == name }) else { return nil }
        let template = tableNode.arguments.first.flatMap { templates[$0] }
        var transposed = false
        if strict {
            guard let template else {
                throw TimingCharacterizationError.missingSourceFact("template for \(name)")
            }
            for fact in ["variable_1", "variable_2"] {
                _ = try Self.uniqueChild(template, named: fact, required: true)
            }
            guard template.child(named: "variable_3") == nil,
                  template.child(named: "index_3") == nil, tableNode.child(named: "index_3") == nil else {
                throw TimingCharacterizationError.unsupportedSemantic("three-dimensional \(name)")
            }
            for fact in ["index_1", "index_2", "values"] {
                _ = try Self.uniqueChild(tableNode, named: fact, required: fact == "values")
            }
        }
        if let template {
            let variables = [template.attribute(named: "variable_1"), template.attribute(named: "variable_2")]
            if variables == ["total_output_net_capacitance", "input_net_transition"] {
                transposed = true
            } else if strict, variables != ["input_net_transition", "total_output_net_capacitance"] {
                throw TimingCharacterizationError.unsupportedSemantic("template variables for \(name)")
            }
        }
        let index1Node = tableNode.child(named: "index_1") ?? template?.child(named: "index_1")
        let index2Node = tableNode.child(named: "index_2") ?? template?.child(named: "index_2")
        if strict {
            guard index1Node != nil, index2Node != nil else {
                throw TimingCharacterizationError.missingSourceFact("indexes for \(name)")
            }
            for fact in ["index_1", "index_2"] {
                if tableNode.child(named: fact) == nil, let template {
                    _ = try Self.uniqueChild(template, named: fact, required: true)
                }
            }
        }
        let valuesNode = tableNode.child(named: "values")
        let index1 = try index1Node.map {
            try Self.values(
                from: $0.arguments,
                field: "index_1",
                line: $0.line
            )
        } ?? []
        let index2 = try index2Node.map {
            try Self.values(
                from: $0.arguments,
                field: "index_2",
                line: $0.line
            )
        } ?? []
        guard let valuesNode else {
            throw TimingError.parseFailure(
                format: "Liberty",
                line: tableNode.line,
                message: "Timing table has no values."
            )
        }
        let rows = try Self.values(
            from: valuesNode.arguments,
            field: "values",
            line: valuesNode.line
        )
        if strict {
            guard !index1.isEmpty, !index2.isEmpty,
                  (index1 + index2 + rows).allSatisfy({ $0 >= 0 }) else {
                throw TimingCharacterizationError.invalidValue("indexes or values for \(name)")
            }
        }
        let actualIndex1 = index1.isEmpty ? [0] : index1.map { $0 * (transposed ? capacitanceScale : scale) }
        let actualIndex2 = index2.isEmpty ? [0] : index2.map { $0 * (transposed ? scale : capacitanceScale) }
        let matrix: [[Double]]
        if rows.count == actualIndex1.count * actualIndex2.count {
            matrix = stride(from: 0, to: rows.count, by: actualIndex2.count).map {
                Array(rows[$0 ..< ($0 + actualIndex2.count)])
            }
        } else if actualIndex1.count == 1 && rows.count == actualIndex2.count {
            matrix = [rows]
        } else {
            throw TimingError.parseFailure(format: "Liberty", line: tableNode.line, message: "Table dimensions do not match values.")
        }
        if strict {
            guard valuesNode.arguments.count == actualIndex1.count else {
                throw TimingCharacterizationError.invalidValue("row count for \(name)")
            }
            for row in valuesNode.arguments {
                guard try Self.values(from: [row], field: "values", line: valuesNode.line).count == actualIndex2.count else {
                    throw TimingCharacterizationError.invalidValue("row width for \(name)")
                }
            }
        }
        let normalized = matrix.map { row in row.map { $0 * scale } }
        return try TimingLUT(
            inputSlews: transposed ? actualIndex2 : actualIndex1,
            outputLoads: transposed ? actualIndex1 : actualIndex2,
            values: transposed
                ? actualIndex2.indices.map { column in actualIndex1.indices.map { normalized[$0][column] } }
                : normalized
        )
    }

    private static func thresholds(_ library: LibertyNode) throws -> TimingCharacterizationThresholds {
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

    private static func uniqueChild(_ node: LibertyNode, named name: String, required: Bool) throws -> LibertyNode? {
        let matches = node.children.filter { $0.name == name }
        guard matches.count <= 1 else {
            throw TimingCharacterizationError.ambiguousSource(name)
        }
        if required, matches.isEmpty {
            throw TimingCharacterizationError.missingSourceFact(name)
        }
        return matches.first
    }

    private enum UnitDimension {
        case time
        case power
    }

    private static func unitScale(
        from value: String,
        dimension: UnitDimension,
        line: Int
    ) throws -> Double {
        let cleaned = value.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffixStart = cleaned.firstIndex { character in
            !(character.isNumber
                || character == "."
                || character == "-"
                || character == "+"
                || character == "e")
        }
        let numericText = suffixStart.map { String(cleaned[..<$0]) } ?? cleaned
        let suffix = suffixStart.map { cleaned[$0...] } ?? ""
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
                message: "Unsupported unit suffix '\(suffix)'."
            )
        }
    }

    private static func capacitanceScale(from node: LibertyNode?) throws -> Double {
        guard let node else { return 1 }
        guard node.arguments.count == 2,
              let value = number(node.arguments[0]),
              value.isFinite,
              value > 0 else {
            throw TimingError.parseFailure(
                format: "Liberty",
                line: node.line,
                message: "capacitive_load_unit requires a finite positive scale and a unit."
            )
        }
        let unit = node.arguments[1]
            .replacingOccurrences(of: "\"", with: "")
            .lowercased()
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
                line: node.line,
                message: "Unsupported capacitance unit '\(unit)'."
            )
        }
        return value * multiplier
    }

    private static func number(_ value: String) -> Double? {
        let cleaned = value.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(cleaned) { return direct }
        let suffixes = ["ms", "us", "ns", "ps", "fs", "s", "mf", "uf", "nf", "pf", "ff"]
        for suffix in suffixes where cleaned.lowercased().hasSuffix(suffix) {
            return Double(cleaned.dropLast(suffix.count))
        }
        return nil
    }

    private static func optionalNumber(
        _ value: String?,
        field: String,
        line: Int
    ) throws -> Double? {
        guard let value else { return nil }
        guard let parsed = number(value), parsed.isFinite else {
            throw TimingError.parseFailure(
                format: "Liberty",
                line: line,
                message: "\(field) contains an invalid numeric value."
            )
        }
        return parsed
    }

    private static func values(
        from arguments: [String],
        field: String,
        line: Int
    ) throws -> [Double] {
        let tokens = arguments
            .joined(separator: ",")
            .replacingOccurrences(of: "\"", with: "")
            .split { $0 == "," || $0.isWhitespace }
        var values: [Double] = []
        values.reserveCapacity(tokens.count)
        for token in tokens {
            guard let value = Double(token), value.isFinite else {
                throw TimingError.parseFailure(
                    format: "Liberty",
                    line: line,
                    message: "\(field) contains an invalid numeric value '\(token)'."
                )
            }
            values.append(value)
        }
        return values
    }

    private static func pinName(from expression: String?) -> String? {
        guard let expression else { return nil }
        let cleaned = expression.replacingOccurrences(of: "\"", with: "")
        let candidates = cleaned.split { character in
            !(character.isLetter || character.isNumber || character == "_")
        }
        return candidates.last.map(String.init)
    }
}

private struct LibertyNode: Sendable {
    let name: String
    let arguments: [String]
    let value: String?
    let children: [LibertyNode]
    let line: Int

    func attribute(named name: String) -> String? {
        children.first(where: { $0.name == name })?.value
    }

    func child(named name: String) -> LibertyNode? {
        children.first(where: { $0.name == name })
    }
}

private struct LibertyGrammar {
    private enum Token: Equatable {
        case word(String)
        case quoted(String)
        case symbol(Character)
        case end
    }

    private let source: String
    private var tokens: [Token] = []
    private var lines: [Int] = []
    private var index = 0

    init(source: String) throws {
        self.source = source
        try tokenize()
    }

    mutating func parse() throws -> [LibertyNode] {
        try parseStatements(until: nil)
    }

    private mutating func parseStatements(until closing: Character?) throws -> [LibertyNode] {
        var result: [LibertyNode] = []
        while true {
            if case .end = peek() {
                if let closing {
                    throw error("Missing closing '\(closing)'.")
                }
                return result
            }
            if let closing, peek() == .symbol(closing) {
                _ = advance()
                return result
            }
            guard case .word(let name) = advance() else {
                throw error("Expected a Liberty group or attribute.")
            }
            let line = currentLine()
            var arguments: [String] = []
            if peek() == .symbol("(") {
                arguments = try parseArguments()
            }
            if peek() == .symbol(":") {
                _ = advance()
                let value = try parseAttributeValue()
                result.append(LibertyNode(name: name, arguments: arguments, value: value, children: [], line: line))
            } else if peek() == .symbol("{") {
                _ = advance()
                let children = try parseStatements(until: "}")
                result.append(LibertyNode(name: name, arguments: arguments, value: nil, children: children, line: line))
            } else if peek() == .symbol(";") {
                _ = advance()
                result.append(LibertyNode(name: name, arguments: arguments, value: nil, children: [], line: line))
            } else {
                throw error("Expected ':', '{' or ';' after '\(name)'.")
            }
        }
    }

    private mutating func parseArguments() throws -> [String] {
        guard peek() == .symbol("(") else { return [] }
        _ = advance()
        var values: [String] = []
        var current = ""
        while true {
            switch advance() {
            case .symbol(")"):
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append(current) }
                return values
            case .symbol(","):
                values.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            case .word(let value), .quoted(let value):
                if !current.isEmpty { current += " " }
                current += value
            case .symbol(let symbol):
                current.append(symbol)
            case .end:
                throw error("Unterminated argument list.")
            }
        }
    }

    private mutating func parseAttributeValue() throws -> String {
        var value = ""
        while true {
            switch advance() {
            case .symbol(";"):
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .word(let item), .quoted(let item):
                if !value.isEmpty { value += " " }
                value += item
            case .symbol(let symbol):
                value.append(symbol)
            case .end:
                throw error("Unterminated attribute value.")
            }
        }
    }

    private func peek() -> Token { tokens[index] }

    private mutating func advance() -> Token {
        let token = tokens[index]
        index += 1
        return token
    }

    private func currentLine() -> Int { lines[min(index, lines.count - 1)] }

    private func error(_ message: String) -> TimingError {
        .parseFailure(format: "Liberty", line: currentLine(), message: message)
    }

    private func continuationLength(in bytes: borrowing [UInt8], at cursor: Int) -> Int {
        guard bytes[cursor] == 92, cursor + 1 < bytes.count else { return 0 }
        if bytes[cursor + 1] == 10 { return 2 }
        if bytes[cursor + 1] == 13, cursor + 2 < bytes.count, bytes[cursor + 2] == 10 { return 3 }
        return 0
    }

    private mutating func tokenize() throws {
        let bytes = Array(source.utf8)
        var cursor = 0
        var line = 1
        while cursor < bytes.count {
            let byte = bytes[cursor]
            let continuation = continuationLength(in: bytes, at: cursor)
            if continuation > 0 { line += 1; cursor += continuation; continue }
            if byte == 10 { line += 1; cursor += 1; continue }
            if byte == 13 || byte == 32 || byte == 9 { cursor += 1; continue }
            if byte == 47, cursor + 1 < bytes.count, bytes[cursor + 1] == 47 {
                cursor += 2
                while cursor < bytes.count, bytes[cursor] != 10 { cursor += 1 }
                continue
            }
            if byte == 47, cursor + 1 < bytes.count, bytes[cursor + 1] == 42 {
                cursor += 2
                while cursor + 1 < bytes.count && !(bytes[cursor] == 42 && bytes[cursor + 1] == 47) {
                    if bytes[cursor] == 10 { line += 1 }
                    cursor += 1
                }
                guard cursor + 1 < bytes.count else {
                    throw TimingError.parseFailure(format: "Liberty", line: line, message: "Unterminated comment.")
                }
                cursor += 2
                continue
            }
            if byte == 34 {
                cursor += 1
                var value = ""
                while cursor < bytes.count && bytes[cursor] != 34 {
                    let continuation = continuationLength(in: bytes, at: cursor)
                    if continuation > 0 { line += 1; cursor += continuation; continue }
                    if bytes[cursor] == 92, cursor + 1 < bytes.count {
                        cursor += 1
                    }
                    value.append(Character(UnicodeScalar(bytes[cursor])))
                    cursor += 1
                }
                guard cursor < bytes.count else {
                    throw TimingError.parseFailure(format: "Liberty", line: line, message: "Unterminated string.")
                }
                cursor += 1
                tokens.append(.quoted(value))
                lines.append(line)
                continue
            }
            if "(){}:;,".utf8.contains(byte) {
                tokens.append(.symbol(Character(UnicodeScalar(byte))))
                lines.append(line)
                cursor += 1
                continue
            }
            var value = ""
            while cursor < bytes.count {
                let current = bytes[cursor]
                if continuationLength(in: bytes, at: cursor) > 0 { break }
                if current == 10 || current == 13 || current == 32 || current == 9 || "(){}:;,\"".utf8.contains(current) { break }
                value.append(Character(UnicodeScalar(current)))
                cursor += 1
            }
            if value.isEmpty {
                throw TimingError.parseFailure(format: "Liberty", line: line, message: "Unexpected byte.")
            }
            tokens.append(.word(value))
            lines.append(line)
        }
        tokens.append(.end)
        lines.append(line)
    }
}

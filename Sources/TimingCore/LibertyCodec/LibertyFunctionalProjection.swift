/// Projects actual grammar nodes without consulting simplified TimingCell semantics.
struct LibertyFunctionalProjection {
    let storage: LibertyParseStorage?
    let maximumNesting: Int?

    func cell(_ node: LibertyNode) throws -> LibertySourceCell {
        guard node.arguments.count == 1, let name = node.arguments.first else {
            throw LibertySourceError.syntax(line: node.sourceLine)
        }
        var pins = LibertyBuffer<LibertySourcePin>()
        var powerPins = LibertyBuffer<LibertySourcePowerPin>()
        var sequential = LibertyBuffer<LibertySourceSequential>()
        var unsupported = LibertyBuffer<String>()
        for child in node.children {
            try check(child.name)
            switch child.name {
            case "pin":
                guard let pin = child.arguments.first else { throw LibertySourceError.syntax(line: child.sourceLine) }
                if child.arguments.count != 1 { try unsupported.append("multiple_pin_names", storage: storage) }
                for prior in pins {
                    try check(prior.name); try check(pin)
                    guard prior.name != pin else { throw LibertySourceError.unsupportedSemantics("Duplicate source pin") }
                }
                let directionNode = try unique(child, "direction")
                let direction: TimingPin.Direction
                if let directionNode {
                    guard let value = directionNode.value else { throw LibertySourceError.syntax(line: directionNode.sourceLine) }
                    try check(value)
                    guard let parsed = TimingPin.Direction(rawValue: value) else { throw LibertySourceError.syntax(line: child.sourceLine) }
                    direction = parsed
                } else { direction = .unknown }
                try pins.append(.init(name: pin, direction: direction, function: try function(child, "function"),
                    stateFunction: try function(child, "state_function"), threeState: try function(child, "three_state"),
                    xFunction: try function(child, "x_function"), line: child.sourceLine, byteOffset: child.byteOffset,
                    powerDownFunction: try function(child, "power_down_function"),
                    relatedPowerPin: try attribute(child, "related_power_pin"),
                    relatedGroundPin: try attribute(child, "related_ground_pin")), storage: storage)
            case "pg_pin":
                guard child.arguments.count == 1, let name = child.arguments.first else { throw LibertySourceError.syntax(line: child.sourceLine) }
                for prior in powerPins {
                    try check(prior.name); try check(name)
                    guard prior.name != name else { throw LibertySourceError.unsupportedSemantics("Duplicate source PG pin") }
                }
                try powerPins.append(.init(name: name, pgType: try attribute(child, "pg_type"),
                    voltageName: try attribute(child, "voltage_name"), line: child.sourceLine, byteOffset: child.byteOffset), storage: storage)
            case "ff", "latch":
                let flipFlop = child.name == "ff"
                try sequential.append(.init(kind: flipFlop ? .flipFlop : .latch,
                    variables: try storage?.array(child.arguments) ?? child.arguments,
                    data: try function(child, flipFlop ? "next_state" : "data_in"),
                    control: try function(child, flipFlop ? "clocked_on" : "enable"),
                    additionalControl: try function(child, flipFlop ? "clocked_on_also" : "enable_also"),
                    powerDownFunction: try function(child, "power_down_function"),
                    clear: try function(child, "clear"), preset: try function(child, "preset"),
                    clearPresetVariable1: try attribute(child, "clear_preset_var1"),
                    clearPresetVariable2: try attribute(child, "clear_preset_var2"),
                    line: child.sourceLine, byteOffset: child.byteOffset), storage: storage)
            case "ff_bank", "latch_bank", "statetable", "memory", "bus", "bundle", "test_cell":
                try unsupported.append(child.name, storage: storage)
            default: break
            }
        }
        let area: Double?
        if let text = try attribute(node, "area") {
            try check(text)
            guard let number = Double(text), number.isFinite else { throw LibertySourceError.syntax(line: node.sourceLine) }
            area = number
        } else { area = nil }
        let dontUse: Bool?
        if let text = try attribute(node, "dont_use") {
            try check(text)
            guard text == "true" || text == "false" else { throw LibertySourceError.syntax(line: node.sourceLine) }
            dontUse = text == "true"
        } else { dontUse = nil }
        return .init(name: name, pins: try pins.array(storage: storage), area: area, dontUse: dontUse,
            sequential: try sequential.array(storage: storage), unsupportedFunctionalGroups: try unsupported.array(storage: storage),
            line: node.sourceLine, byteOffset: node.byteOffset, powerPins: try powerPins.array(storage: storage))
    }

    private func function(_ parent: LibertyNode, _ name: String) throws -> LibertySourceFunction? {
        guard let node = try unique(parent, name) else { return nil }
        return try LibertyBooleanNormalizer.normalize(node, storage: storage, maximumNesting: maximumNesting)
    }
    private func attribute(_ parent: LibertyNode, _ name: String) throws -> String? {
        guard let node = try unique(parent, name) else { return nil }
        guard let value = node.value else { throw LibertySourceError.syntax(line: node.sourceLine) }
        return value
    }
    private func unique(_ parent: LibertyNode, _ name: String) throws -> LibertyNode? {
        var result: LibertyNode?
        for child in parent.children {
            try check(child.name)
            if child.name == name {
                guard result == nil else { throw LibertySourceError.unsupportedSemantics("Duplicate functional attribute") }
                result = child
            }
        }
        return result
    }
    private func check(_ text: String) throws {
        for _ in text.utf8 { try storage?.step() }
        try storage?.resources.check()
    }
}

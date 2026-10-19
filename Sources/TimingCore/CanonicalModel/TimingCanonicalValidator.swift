import Foundation

public struct TimingCanonicalValidator: Sendable {
    public init() {}

    public func validate(
        design: TimingDesign,
        constraints: TimingConstraintSet,
        libraries: [TimingLibrary],
        parasitics: TimingParasitics?
    ) -> TimingCanonicalValidationReport {
        var findings: [TimingCanonicalValidationFinding] = []
        validate(design, findings: &findings)
        validate(constraints, design: design, findings: &findings)
        validate(libraries, design: design, findings: &findings)
        if let parasitics {
            validate(parasitics, design: design, findings: &findings)
        }
        return TimingCanonicalValidationReport(findings: findings)
    }

    public func validateSignalIntegrity(design: TimingDesign, constraints: TimingConstraintSet,
                                        parasitics: TimingParasitics) -> TimingCanonicalValidationReport {
        var findings: [TimingCanonicalValidationFinding] = []
        validate(design, findings: &findings)
        validate(constraints, design: design, findings: &findings)
        validate(parasitics, design: design, findings: &findings)
        if parasitics.networks.isEmpty || (design.nets.isEmpty && design.ports.isEmpty) {
            findings.append(finding("timing.signal-integrity.empty-scope", "SI requires an explicit design and parasitic network scope."))
        }
        return TimingCanonicalValidationReport(findings: findings)
    }

    public func validateSignalIntegrityParasitics(
        _ parasitics: TimingParasitics
    ) -> TimingCanonicalValidationReport {
        var findings: [TimingCanonicalValidationFinding] = []
        if parasitics.schemaVersion != 2 && parasitics.schemaVersion != TimingParasitics.currentSchemaVersion {
            findings.append(finding(
                "timing.parasitic.schema-version",
                "The timing parasitic schema version is unsupported."
            ))
        }
        validateUnique(
            parasitics.networks.map(\.name),
            kind: "parasitic-network",
            findings: &findings
        )
        for network in parasitics.networks {
            if network.name.isEmpty
                || !isNonnegativeFinite(network.declaredCapacitance)
                || !isNonnegativeFinite(network.groundCapacitance)
                || !isNonnegativeFinite(network.resistanceInventory) {
                findings.append(finding(
                    "timing.parasitic.network-invalid",
                    "A timing parasitic network has an invalid identity or numeric value.",
                    network.name
                ))
            }
        }
        if parasitics.pinDelimiter.count != 1 {
            findings.append(finding("timing.parasitic.delimiter-invalid", "A pin delimiter must contain exactly one character."))
        }
        var owners: [String: String] = [:]
        for network in parasitics.networks {
            var resistanceIDs: Set<UInt64> = []
            for record in network.resistances {
                if record.source.declaringNet != network.name || record.source.identifier == 0 || record.source.line <= 0
                    || !resistanceIDs.insert(record.source.identifier).inserted || !isNonnegativeFinite(record.resistance) {
                    findings.append(finding("timing.parasitic.resistance-invalid", "A resistance source record has invalid identity, ownership or value."))
                }
            }
            for endpoint in network.connections + network.resistances.flatMap({ [$0.first, $0.second] }) {
                if endpoint.name.isEmpty || endpoint.ownerNet.isEmpty
                    || owners[endpoint.name].map({ $0 != endpoint.ownerNet }) == true {
                    findings.append(finding("timing.parasitic.endpoint-invalid", "A resistance/connection endpoint has invalid ownership."))
                }
                owners[endpoint.name] = endpoint.ownerNet
            }
            var identifiers: Set<UInt64> = []
            for record in network.capacitances {
                let endpoints = [record.first] + (record.second.map { [$0] } ?? [])
                if record.source.declaringNet != network.name || record.source.identifier == 0
                    || record.source.line <= 0 || !identifiers.insert(record.source.identifier).inserted
                    || !isNonnegativeFinite(record.capacitance)
                    || !endpoints.contains(where: { $0.ownerNet == network.name }) {
                    findings.append(finding("timing.parasitic.capacitance-invalid", "A source capacitance record has invalid identity, ownership or value."))
                }
                for endpoint in endpoints {
                    if endpoint.name.isEmpty || endpoint.ownerNet.isEmpty
                        || owners[endpoint.name].map({ $0 != endpoint.ownerNet }) == true {
                        findings.append(finding("timing.parasitic.endpoint-invalid", "A source endpoint has empty or conflicting ownership."))
                    }
                    owners[endpoint.name] = endpoint.ownerNet
                }
            }
        }
        return TimingCanonicalValidationReport(findings: findings)
    }

    private func validate(
        _ design: TimingDesign,
        findings: inout [TimingCanonicalValidationFinding]
    ) {
        if design.schemaVersion != TimingDesign.currentSchemaVersion {
            findings.append(finding(
                "timing.design.schema-version",
                "The timing design schema version is unsupported."
            ))
        }
        if design.topDesignName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(finding(
                "timing.design.name-missing",
                "The top timing design name must not be empty."
            ))
        }
        validateUnique(
            design.ports.map(\.name),
            kind: "port",
            findings: &findings
        )
        validateUnique(
            design.instances.map(\.name),
            kind: "instance",
            findings: &findings
        )
        validateUnique(
            design.nets.map(\.name),
            kind: "net",
            findings: &findings
        )
        let netNames = Set(design.nets.map(\.name)).union(design.ports.filter { $0.net == nil }.map(\.name))
        for port in design.ports where port.name.isEmpty {
            findings.append(finding(
                "timing.design.port-name-missing",
                "Timing port names must not be empty."
            ))
        }
        for port in design.ports where !netNames.contains(port.netName) || port.netName.isEmpty {
            findings.append(finding("timing.design.port-net-invalid", "A port does not resolve to a physical net.", port.name))
        }
        for instance in design.instances {
            if instance.name.isEmpty || instance.cell.isEmpty {
                findings.append(finding(
                    "timing.design.instance-identity-missing",
                    "Timing instances need a name and cell identity.",
                    instance.name
                ))
            }
            for (pin, net) in instance.connections {
                if pin.isEmpty || net.isEmpty || !netNames.contains(net) {
                    findings.append(finding(
                        "timing.design.connection-invalid",
                        "An instance connection does not resolve to a canonical net.",
                        instance.name
                    ))
                }
            }
        }
        for net in design.nets {
            if net.name.isEmpty || !net.capacitance.isFinite || net.capacitance < 0 {
                findings.append(finding(
                    "timing.design.net-invalid",
                    "Timing nets need a name and finite nonnegative capacitance.",
                    net.name
                ))
            }
        }
    }

    private func validate(
        _ constraints: TimingConstraintSet,
        design: TimingDesign,
        findings: inout [TimingCanonicalValidationFinding]
    ) {
        if constraints.schemaVersion != TimingConstraintSet.currentSchemaVersion {
            findings.append(finding(
                "timing.constraint.schema-version",
                "The timing constraint schema version is unsupported."
            ))
        }
        if constraints.modeID.isEmpty {
            findings.append(finding(
                "timing.constraint.mode-missing",
                "A timing constraint mode identifier is required."
            ))
        }
        validateUnique(
            constraints.clocks.map(\.name) + constraints.generatedClocks.map(\.name),
            kind: "clock",
            findings: &findings
        )
        let ports = Set(design.ports.map(\.name))
        let primaryClocks = Set(constraints.clocks.map(\.name))
        let allClocks = primaryClocks.union(constraints.generatedClocks.map(\.name))
        for clock in constraints.clocks {
            if clock.name.isEmpty || !ports.contains(clock.source)
                || !clock.period.isFinite || clock.period <= 0
                || !clock.uncertainty.isFinite || clock.uncertainty < 0
                || !clock.waveform.allSatisfy(\.isFinite)
                || clock.sourceRiseTransition.map({ !$0.isFinite || $0 <= 0 }) == true
                || clock.sourceFallTransition.map({ !$0.isFinite || $0 <= 0 }) == true
                || (clock.isPropagated && (!clock.hasValidPropagatedSource || design.ports.first(where: { $0.name == clock.source })?.direction != .input)) {
                findings.append(finding(
                    "timing.constraint.clock-invalid",
                    "A primary clock has an invalid identity, source, or numeric value.",
                    clock.name
                ))
            }
        }
        var clockSources = Set<String>()
        for clock in constraints.clocks.map({ ($0.name, $0.source) })
            + constraints.generatedClocks.map({ ($0.name, $0.source) }) {
            let net = design.ports.first { $0.name == clock.1 }?.netName ?? clock.1
            if !clockSources.insert(net).inserted || design.net(named: net).constant != nil {
                findings.append(finding("timing.constraint.clock-net-invalid", "Clock sources must be unique nonconstant physical nets.", clock.0))
            }
        }
        for clock in constraints.generatedClocks {
            if clock.name.isEmpty || !ports.contains(clock.source)
                || !primaryClocks.contains(clock.masterClock)
                || clock.divideBy <= 0 || clock.multiplyBy <= 0 {
                findings.append(finding(
                    "timing.constraint.generated-clock-invalid",
                    "A generated clock has an invalid source, master, or ratio.",
                    clock.name
                ))
            }
        }
        for delay in constraints.inputDelays + constraints.outputDelays {
            if !ports.contains(delay.port)
                || delay.clock.map({ !allClocks.contains($0) }) == true
                || !delay.rise.isFinite || !delay.fall.isFinite {
                findings.append(finding(
                    "timing.constraint.port-delay-invalid",
                    "A port delay has an invalid port, clock, or numeric value.",
                    delay.port
                ))
            }
        }
        for exception in constraints.exceptions {
            let objects = exception.from + exception.to + exception.through.flatMap { $0 }
            let cyclesValid = exception.cycles.map { $0 >= (exception.scope == .hold ? 0 : 1) } ?? false
            let delayValid = exception.delay.map { $0.isFinite && $0 >= 0 } ?? false
            let fieldsValid: Bool
            switch exception.kind {
            case .falsePath: fieldsValid = exception.cycles == nil && exception.delay == nil && !objects.isEmpty
            case .multicycle: fieldsValid = cyclesValid && exception.delay == nil
            case .maxDelay, .minDelay: fieldsValid = delayValid && exception.cycles == nil && exception.scope == .both
            }
            if !fieldsValid || objects.contains(where: { $0.pattern.isEmpty }) || exception.through.contains(where: { $0.isEmpty }) {
                findings.append(finding("timing.constraint.exception-invalid", "A path exception has invalid selectors, scope or numeric values."))
            }
        }
        if !constraints.defaultInputSlew.isFinite
            || constraints.defaultInputSlew < 0
            || !constraints.defaultOutputLoad.isFinite
            || constraints.defaultOutputLoad < 0 {
            findings.append(finding(
                "timing.constraint.default-invalid",
                "Default slew and output load must be finite and nonnegative."
            ))
        }
    }

    private func validate(
        _ libraries: [TimingLibrary],
        design: TimingDesign,
        findings: inout [TimingCanonicalValidationFinding]
    ) {
        if libraries.isEmpty {
            findings.append(finding(
                "timing.library.missing",
                "At least one exact source-bound timing library is required."
            ))
        }
        validateUnique(libraries.map(\.name), kind: "library", findings: &findings)
        var knownCells = Set<String>()
        for library in libraries {
            if library.name.isEmpty
                || !isPositiveFinite(library.timeUnitScale)
                || !isPositiveFinite(library.capacitanceUnitScale)
                || !isPositiveFinite(library.powerUnitScale) {
                findings.append(finding(
                    "timing.library.identity-or-units-invalid",
                    "A timing library needs an identity and finite positive unit scales.",
                    library.name
                ))
            }
            for (cellName, cell) in library.cells {
                knownCells.insert(cellName)
                if cellName != cell.name || cellName.isEmpty {
                    findings.append(finding(
                        "timing.library.cell-identity-invalid",
                        "A timing cell key must match its canonical name.",
                        cellName
                    ))
                }
                validateUnique(
                    cell.pins.map(\.name),
                    kind: "cell-pin",
                    findings: &findings
                )
                for pin in cell.pins {
                    if pin.name.isEmpty || !pin.capacitance.isFinite
                        || pin.capacitance < 0
                        || pin.maxCapacitance.map({ !$0.isFinite || $0 < 0 }) == true {
                        findings.append(finding(
                            "timing.library.pin-invalid",
                            "A timing pin has an invalid identity or capacitance.",
                            "\(cellName)/\(pin.name)"
                        ))
                    }
                }
            }
        }
        var drivers: [String: Int] = [:]
        for port in design.ports where port.direction == .input || port.direction == .bidirectional {
            drivers[port.netName, default: 0] += 1
        }
        for net in design.nets where net.constant != nil { drivers[net.name, default: 0] += 1 }
        for instance in design.instances {
            guard let cell = libraries.lazy.compactMap({ $0.cells[instance.cell] }).first else { continue }
            for pin in cell.outputPins {
                if let net = instance.connections[pin.name] { drivers[net, default: 0] += 1 }
            }
            for (pin, _) in instance.connections where cell.pin(named: pin) == nil {
                findings.append(finding("timing.design.pin-invalid", "A connected pin is absent from its cell.", instance.name + "/" + pin))
            }
        }
        for (net, count) in drivers where count > 1 {
            findings.append(finding("timing.design.multiple-drivers", "A physical net has conflicting drivers.", net))
        }
        for instance in design.instances where !knownCells.contains(instance.cell) {
            findings.append(finding(
                "timing.library.instance-cell-missing",
                "A design instance does not resolve in the bound timing libraries.",
                instance.name
            ))
        }
    }

    private func validate(
        _ parasitics: TimingParasitics,
        design: TimingDesign,
        findings: inout [TimingCanonicalValidationFinding]
    ) {
        findings.append(contentsOf: validateSignalIntegrityParasitics(parasitics).findings)
        let designNets = Set(design.nets.map(\.name)).union(design.ports.filter { $0.net == nil }.map(\.name))
        for network in parasitics.networks {
            if !designNets.contains(network.name) {
                findings.append(finding("timing.parasitic.network-invalid", "A parasitic network is absent from the logical design.", network.name))
            }
            for record in network.capacitances {
                for endpoint in [record.first] + (record.second.map { [$0] } ?? []) {
                    if !designNets.contains(endpoint.ownerNet) {
                        findings.append(finding("timing.parasitic.endpoint-invalid", "A parasitic endpoint owner is absent from the logical design.", endpoint.ownerNet))
                    }
                }
            }
        }
    }

    private func validateUnique(
        _ values: [String],
        kind: String,
        findings: inout [TimingCanonicalValidationFinding]
    ) {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted {
            findings.append(finding(
                "timing.\(kind).duplicate",
                "Canonical \(kind) identities must be unique.",
                value
            ))
        }
    }

    private func isPositiveFinite(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }

    private func isNonnegativeFinite(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    private func finding(
        _ code: String,
        _ summary: String,
        _ entity: String? = nil
    ) -> TimingCanonicalValidationFinding {
        TimingCanonicalValidationFinding(
            code: code,
            summary: summary,
            entity: entity
        )
    }
}

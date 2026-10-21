import Foundation
import Synchronization

public struct TimingCanonicalValidator: Sendable {
    public init() {}

    public func validate(design: TimingDesign, constraints: TimingConstraintSet,
        libraries: [TimingLibrary], parasitics: TimingParasitics?) -> TimingCanonicalValidationReport {
        validate(design: design, constraints: constraints, libraries: libraries,
            parasitics: parasitics, construction: { _ in nil }).value
    }

    public func validateSignalIntegrity(design: TimingDesign, constraints: TimingConstraintSet,
        parasitics: TimingParasitics) -> TimingCanonicalValidationReport {
        validateSignalIntegrity(design: design, constraints: constraints,
            parasitics: parasitics, construction: { _ in nil }).value
    }

    public func validateSignalIntegrityParasitics(_ parasitics: TimingParasitics) -> TimingCanonicalValidationReport {
        validateSignalIntegrityParasitics(parasitics, construction: { _ in nil }).value
    }

    public func validate(design: TimingDesign, constraints: TimingConstraintSet,
        libraries: [TimingLibrary], parasitics: TimingParasitics?,
        resources: any LibertySourceResourceAccounting) throws -> TimingTransformValue<TimingCanonicalValidationReport> {
        let transform = try TimingTextTransform(resources: resources)
        let accounting = try Accounting(transform: transform)
        do {
            let result = try validate(design: design, constraints: constraints, libraries: libraries,
                parasitics: parasitics, construction: accounting.admit)
            return try publish(result, transform: transform)
        } catch let error as TimingControlledTransformFailure { throw error }
        catch { throw transform.failure(error) }
    }

    public func validateSignalIntegrity(design: TimingDesign, constraints: TimingConstraintSet,
        parasitics: TimingParasitics, resources: any LibertySourceResourceAccounting) throws
        -> TimingTransformValue<TimingCanonicalValidationReport> {
        let transform = try TimingTextTransform(resources: resources)
        let accounting = try Accounting(transform: transform)
        do {
            let result = try validateSignalIntegrity(design: design, constraints: constraints,
                parasitics: parasitics, construction: accounting.admit)
            return try publish(result, transform: transform)
        } catch let error as TimingControlledTransformFailure { throw error }
        catch { throw transform.failure(error) }
    }

    public func validateSignalIntegrityParasitics(_ parasitics: TimingParasitics,
        resources: any LibertySourceResourceAccounting) throws -> TimingTransformValue<TimingCanonicalValidationReport> {
        let transform = try TimingTextTransform(resources: resources)
        let accounting = try Accounting(transform: transform)
        do {
            let result = try validateSignalIntegrityParasitics(parasitics, construction: accounting.admit)
            return try publish(result, transform: transform)
        } catch let error as TimingControlledTransformFailure { throw error }
        catch { throw transform.failure(error) }
    }

    private func validate(
        design: TimingDesign,
        constraints: TimingConstraintSet,
        libraries: [TimingLibrary],
        parasitics: TimingParasitics?, construction: Construction
    ) rethrows -> Payload<TimingCanonicalValidationReport> {
        _ = try construction(.checkpoint)
        var findings = FindingBuffer()
        try validate(design, findings: &findings, construction: construction)
        try validate(constraints, design: design, findings: &findings, construction: construction)
        try validate(libraries, design: design, findings: &findings, construction: construction)
        if let parasitics {
            try validate(parasitics, design: design, findings: &findings, construction: construction)
        }
        return try payload(TimingCanonicalValidationReport(findings: findings.values),
            receipt: findings.receipt, construction: construction)
    }

    private func validateSignalIntegrity(design: TimingDesign, constraints: TimingConstraintSet,
                                        parasitics: TimingParasitics, construction: Construction) rethrows -> Payload<TimingCanonicalValidationReport> {
        _ = try construction(.checkpoint)
        var findings = FindingBuffer()
        try validate(design, findings: &findings, construction: construction)
        try validate(constraints, design: design, findings: &findings, construction: construction)
        try validate(parasitics, design: design, findings: &findings, construction: construction)
        if parasitics.networks.isEmpty || (design.nets.isEmpty && design.ports.isEmpty) {
            try append(finding("timing.signal-integrity.empty-scope", "SI requires an explicit design and parasitic network scope."), findings: &findings, construction: construction)
        }
        return try payload(TimingCanonicalValidationReport(findings: findings.values),
            receipt: findings.receipt, construction: construction)
    }

    private func validateSignalIntegrityParasitics(
        _ parasitics: TimingParasitics, construction: Construction
    ) rethrows -> Payload<TimingCanonicalValidationReport> {
        _ = try construction(.checkpoint)
        var findings = FindingBuffer()
        if parasitics.schemaVersion != 2 && parasitics.schemaVersion != TimingParasitics.currentSchemaVersion {
            try append(finding(
                "timing.parasitic.schema-version",
                "The timing parasitic schema version is unsupported."
            ), findings: &findings, construction: construction)
        }
        try validateUnique(
            try project(parasitics.networks, { $0.name }, construction: construction),
            kind: "parasitic-network",
            findings: &findings, construction: construction
        )
        for network in parasitics.networks {
            _ = try construction(.checkpoint)
            _ = try construction(.work(network.capacitances.count))
            if network.name.isEmpty
                || !isNonnegativeFinite(network.declaredCapacitance)
                || !isNonnegativeFinite(network.groundCapacitance)
                || !isNonnegativeFinite(network.resistanceInventory) {
                try append(finding(
                    "timing.parasitic.network-invalid",
                    "A timing parasitic network has an invalid identity or numeric value.",
                    network.name
                ), findings: &findings, construction: construction)
            }
        }
        if parasitics.pinDelimiter.count != 1 {
            try append(finding("timing.parasitic.delimiter-invalid", "A pin delimiter must contain exactly one character."), findings: &findings, construction: construction)
        }
        var endpointCapacity = 0
        for network in parasitics.networks {
            _ = try construction(.checkpoint)
            endpointCapacity = try sum(endpointCapacity, network.connections.count, construction: construction)
            endpointCapacity = try sum(endpointCapacity, network.resistances.count, construction: construction)
            endpointCapacity = try sum(endpointCapacity, network.resistances.count, construction: construction)
            endpointCapacity = try sum(endpointCapacity, network.capacitances.count, construction: construction)
            endpointCapacity = try sum(endpointCapacity, network.capacitances.count, construction: construction)
        }
        let ownersReceipt = try construction(.stringOwners(endpointCapacity))
        defer { withExtendedLifetime(ownersReceipt) {} }
        var owners: [String: String] = [:]; owners.reserveCapacity(endpointCapacity)
        for network in parasitics.networks {
            _ = try construction(.checkpoint)
            let resistanceReceipt = try construction(.identifiers(network.resistances.count))
            defer { withExtendedLifetime(resistanceReceipt) {} }
            var resistanceIDs = Set<UInt64>(minimumCapacity: network.resistances.count)
            for record in network.resistances {
                _ = try construction(.checkpoint)
                if record.source.declaringNet != network.name || record.source.identifier == 0 || record.source.line <= 0
                    || !resistanceIDs.insert(record.source.identifier).inserted || !isNonnegativeFinite(record.resistance) {
                    try append(finding("timing.parasitic.resistance-invalid", "A resistance source record has invalid identity, ownership or value."), findings: &findings, construction: construction)
                }
            }
            let endpoints = try concatenate(try payload(network.connections, construction: construction),
                try resistanceEndpoints(network.resistances, construction: construction), construction: construction)
            defer { withExtendedLifetime(endpoints) {} }
            for endpoint in endpoints.value {
                _ = try construction(.checkpoint)
                _ = try construction(.inspect(endpoint.name)); _ = try construction(.inspect(endpoint.ownerNet))
                if endpoint.name.isEmpty || endpoint.ownerNet.isEmpty
                    || owners[endpoint.name].map({ $0 != endpoint.ownerNet }) == true {
                    try append(finding("timing.parasitic.endpoint-invalid", "A resistance/connection endpoint has invalid ownership."), findings: &findings, construction: construction)
                }
                owners[endpoint.name] = endpoint.ownerNet
            }
            let identifiersReceipt = try construction(.identifiers(network.capacitances.count))
            defer { withExtendedLifetime(identifiersReceipt) {} }
            var identifiers = Set<UInt64>(minimumCapacity: network.capacitances.count)
            for record in network.capacitances {
                _ = try construction(.checkpoint)
                let endpoints = try capacitanceEndpoints(record, construction: construction)
                defer { withExtendedLifetime(endpoints) {} }
                if record.source.declaringNet != network.name || record.source.identifier == 0
                    || record.source.line <= 0 || !identifiers.insert(record.source.identifier).inserted
                    || !isNonnegativeFinite(record.capacitance)
                    || !endpoints.value.contains(where: { $0.ownerNet == network.name }) {
                    try append(finding("timing.parasitic.capacitance-invalid", "A source capacitance record has invalid identity, ownership or value."), findings: &findings, construction: construction)
                }
                for endpoint in endpoints.value {
                    _ = try construction(.checkpoint)
                    _ = try construction(.inspect(endpoint.name)); _ = try construction(.inspect(endpoint.ownerNet))
                    if endpoint.name.isEmpty || endpoint.ownerNet.isEmpty
                        || owners[endpoint.name].map({ $0 != endpoint.ownerNet }) == true {
                        try append(finding("timing.parasitic.endpoint-invalid", "A source endpoint has empty or conflicting ownership."), findings: &findings, construction: construction)
                    }
                    owners[endpoint.name] = endpoint.ownerNet
                }
            }
        }
        return try payload(TimingCanonicalValidationReport(findings: findings.values),
            receipt: findings.receipt, construction: construction)
    }

    private func validate(
        _ design: TimingDesign,
        findings: inout FindingBuffer, construction: Construction
    ) rethrows {
        if design.schemaVersion != TimingDesign.currentSchemaVersion {
            try append(finding(
                "timing.design.schema-version",
                "The timing design schema version is unsupported."
            ), findings: &findings, construction: construction)
        }
        if try trimmedIsEmpty(design.topDesignName, construction: construction) {
            try append(finding(
                "timing.design.name-missing",
                "The top timing design name must not be empty."
            ), findings: &findings, construction: construction)
        }
        try validateUnique(
            try project(design.ports, { $0.name }, construction: construction),
            kind: "port",
            findings: &findings, construction: construction
        )
        try validateUnique(
            try project(design.instances, { $0.name }, construction: construction),
            kind: "instance",
            findings: &findings, construction: construction
        )
        try validateUnique(
            try project(design.nets, { $0.name }, construction: construction),
            kind: "net",
            findings: &findings, construction: construction
        )
        let netNames = try identifiers(try concatenate(try project(design.nets, { $0.name }, construction: construction),
            try project(try select(design.ports, { $0.net == nil }, construction: construction), { $0.name }, construction: construction),
            construction: construction), construction: construction)
        defer { withExtendedLifetime(netNames) {} }
        for port in design.ports {
            _ = try construction(.checkpoint)
            guard port.name.isEmpty else { continue }
            try append(finding(
                "timing.design.port-name-missing",
                "Timing port names must not be empty."
            ), findings: &findings, construction: construction)
        }
        for port in design.ports {
            _ = try construction(.inspect(port.netName))
            guard !netNames.value.contains(port.netName) || port.netName.isEmpty else { continue }
            _ = try construction(.checkpoint)
            try append(finding("timing.design.port-net-invalid", "A port does not resolve to a physical net.", port.name), findings: &findings, construction: construction)
        }
        for instance in design.instances {
            _ = try construction(.checkpoint)
            if instance.name.isEmpty || instance.cell.isEmpty {
                try append(finding(
                    "timing.design.instance-identity-missing",
                    "Timing instances need a name and cell identity.",
                    instance.name
                ), findings: &findings, construction: construction)
            }
            for (pin, net) in instance.connections {
                _ = try construction(.checkpoint)
                if pin.isEmpty || net.isEmpty || !netNames.value.contains(net) {
                    try append(finding(
                        "timing.design.connection-invalid",
                        "An instance connection does not resolve to a canonical net.",
                        instance.name
                    ), findings: &findings, construction: construction)
                }
            }
        }
        for net in design.nets {
            _ = try construction(.checkpoint)
            if net.name.isEmpty || !net.capacitance.isFinite || net.capacitance < 0 {
                try append(finding(
                    "timing.design.net-invalid",
                    "Timing nets need a name and finite nonnegative capacitance.",
                    net.name
                ), findings: &findings, construction: construction)
            }
        }
    }

    private func validate(
        _ constraints: TimingConstraintSet,
        design: TimingDesign,
        findings: inout FindingBuffer, construction: Construction
    ) rethrows {
        if constraints.schemaVersion != TimingConstraintSet.currentSchemaVersion {
            try append(finding(
                "timing.constraint.schema-version",
                "The timing constraint schema version is unsupported."
            ), findings: &findings, construction: construction)
        }
        if constraints.modeID.isEmpty {
            try append(finding(
                "timing.constraint.mode-missing",
                "A timing constraint mode identifier is required."
            ), findings: &findings, construction: construction)
        }
        try validateUnique(
            try concatenate(try project(constraints.clocks, { $0.name }, construction: construction),
                try project(constraints.generatedClocks, { $0.name }, construction: construction), construction: construction),
            kind: "clock",
            findings: &findings, construction: construction
        )
        let ports = try identifiers(try project(design.ports, { $0.name }, construction: construction), construction: construction)
        defer { withExtendedLifetime(ports) {} }
        let primaryClocks = try identifiers(try project(constraints.clocks, { $0.name }, construction: construction), construction: construction)
        defer { withExtendedLifetime(primaryClocks) {} }
        let allClocks = try union(primaryClocks, try project(constraints.generatedClocks, { $0.name }, construction: construction), construction: construction)
        defer { withExtendedLifetime(allClocks) {} }
        for clock in constraints.clocks {
            _ = try construction(.checkpoint)
            _ = try construction(.work(design.ports.count)); _ = try construction(.work(clock.waveform.count))
            _ = try construction(.inspect(clock.source))
            if clock.name.isEmpty || !ports.value.contains(clock.source)
                || !clock.period.isFinite || clock.period <= 0
                || !clock.uncertainty.isFinite || clock.uncertainty < 0
                || !clock.waveform.allSatisfy(\.isFinite)
                || clock.sourceRiseTransition.map({ !$0.isFinite || $0 <= 0 }) == true
                || clock.sourceFallTransition.map({ !$0.isFinite || $0 <= 0 }) == true
                || (clock.isPropagated && (!clock.hasValidPropagatedSource || design.ports.first(where: { $0.name == clock.source })?.direction != .input)) {
                try append(finding(
                    "timing.constraint.clock-invalid",
                    "A primary clock has an invalid identity, source, or numeric value.",
                    clock.name
                ), findings: &findings, construction: construction)
            }
        }
        let clockSourceCount = try sum(constraints.clocks.count, constraints.generatedClocks.count, construction: construction)
        let clockSourcesReceipt = try construction(.stringSet(clockSourceCount))
        defer { withExtendedLifetime(clockSourcesReceipt) {} }
        var clockSources = Set<String>(minimumCapacity: clockSourceCount)
        let clockPairs = try concatenate(try project(constraints.clocks, { ($0.name, $0.source) }, construction: construction),
            try project(constraints.generatedClocks, { ($0.name, $0.source) }, construction: construction), construction: construction)
        defer { withExtendedLifetime(clockPairs) {} }
        for clock in clockPairs.value {
            _ = try construction(.checkpoint)
            _ = try construction(.work(design.ports.count)); _ = try construction(.work(design.nets.count))
            _ = try construction(.inspect(clock.1))
            let net = design.ports.first { $0.name == clock.1 }?.netName ?? clock.1
            if !clockSources.insert(net).inserted || design.net(named: net).constant != nil {
                try append(finding("timing.constraint.clock-net-invalid", "Clock sources must be unique nonconstant physical nets.", clock.0), findings: &findings, construction: construction)
            }
        }
        for clock in constraints.generatedClocks {
            _ = try construction(.checkpoint)
            _ = try construction(.work(design.ports.count))
            _ = try construction(.inspect(clock.source))
            if clock.name.isEmpty || !ports.value.contains(clock.source)
                || !primaryClocks.value.contains(clock.masterClock)
                || clock.divideBy <= 0 || clock.multiplyBy <= 0 {
                try append(finding(
                    "timing.constraint.generated-clock-invalid",
                    "A generated clock has an invalid source, master, or ratio.",
                    clock.name
                ), findings: &findings, construction: construction)
            }
        }
        let delays = try concatenate(try payload(constraints.inputDelays, construction: construction),
            try payload(constraints.outputDelays, construction: construction), construction: construction)
        defer { withExtendedLifetime(delays) {} }
        for delay in delays.value {
            _ = try construction(.checkpoint)
            if !ports.value.contains(delay.port)
                || delay.clock.map({ !allClocks.value.contains($0) }) == true
                || !delay.rise.isFinite || !delay.fall.isFinite {
                try append(finding(
                    "timing.constraint.port-delay-invalid",
                    "A port delay has an invalid port, clock, or numeric value.",
                    delay.port
                ), findings: &findings, construction: construction)
            }
        }
        for exception in constraints.exceptions {
            _ = try construction(.checkpoint)
            let objects = try concatenate(try concatenate(try payload(exception.from, construction: construction),
                try payload(exception.to, construction: construction), construction: construction),
                try flatten(exception.through, construction: construction), construction: construction)
            defer { withExtendedLifetime(objects) {} }
            let cyclesValid = exception.cycles.map { $0 >= (exception.scope == .hold ? 0 : 1) } ?? false
            let delayValid = exception.delay.map { $0.isFinite && $0 >= 0 } ?? false
            let fieldsValid: Bool
            switch exception.kind {
            case .falsePath: fieldsValid = exception.cycles == nil && exception.delay == nil && !objects.value.isEmpty
            case .multicycle: fieldsValid = cyclesValid && exception.delay == nil
            case .maxDelay, .minDelay: fieldsValid = delayValid && exception.cycles == nil && exception.scope == .both
            }
            if !fieldsValid || objects.value.contains(where: { $0.pattern.isEmpty }) || exception.through.contains(where: { $0.isEmpty }) {
                try append(finding("timing.constraint.exception-invalid", "A path exception has invalid selectors, scope or numeric values."), findings: &findings, construction: construction)
            }
        }
        if !constraints.defaultInputSlew.isFinite
            || constraints.defaultInputSlew < 0
            || !constraints.defaultOutputLoad.isFinite
            || constraints.defaultOutputLoad < 0 {
            try append(finding(
                "timing.constraint.default-invalid",
                "Default slew and output load must be finite and nonnegative."
            ), findings: &findings, construction: construction)
        }
    }

    private func validate(
        _ libraries: [TimingLibrary],
        design: TimingDesign,
        findings: inout FindingBuffer, construction: Construction
    ) rethrows {
        if libraries.isEmpty {
            try append(finding(
                "timing.library.missing",
                "At least one exact source-bound timing library is required."
            ), findings: &findings, construction: construction)
        }
        try validateUnique(try project(libraries, { $0.name }, construction: construction), kind: "library", findings: &findings, construction: construction)
        var cellCapacity = 0
        for library in libraries { cellCapacity = try sum(cellCapacity, library.cells.count, construction: construction) }
        let knownCellsReceipt = try construction(.stringSet(cellCapacity))
        defer { withExtendedLifetime(knownCellsReceipt) {} }
        var knownCells = Set<String>(minimumCapacity: cellCapacity)
        for library in libraries {
            _ = try construction(.checkpoint)
            if library.name.isEmpty
                || !isPositiveFinite(library.timeUnitScale)
                || !isPositiveFinite(library.capacitanceUnitScale)
                || !isPositiveFinite(library.powerUnitScale) {
                try append(finding(
                    "timing.library.identity-or-units-invalid",
                    "A timing library needs an identity and finite positive unit scales.",
                    library.name
                ), findings: &findings, construction: construction)
            }
            for (cellName, cell) in library.cells {
                _ = try construction(.checkpoint)
                _ = try construction(.inspect(cellName))
                knownCells.insert(cellName)
                if cellName != cell.name || cellName.isEmpty {
                    try append(finding(
                        "timing.library.cell-identity-invalid",
                        "A timing cell key must match its canonical name.",
                        cellName
                    ), findings: &findings, construction: construction)
                }
                try validateUnique(
                    try project(cell.pins, { $0.name }, construction: construction),
                    kind: "cell-pin",
                    findings: &findings, construction: construction
                )
                for pin in cell.pins {
                    _ = try construction(.checkpoint)
                    if pin.name.isEmpty || !pin.capacitance.isFinite
                        || pin.capacitance < 0
                        || pin.maxCapacitance.map({ !$0.isFinite || $0 < 0 }) == true {
                        try append(finding(
                            "timing.library.pin-invalid",
                            "A timing pin has an invalid identity or capacitance.",
                            try joined(cellName, "/", pin.name, construction: construction)
                        ), findings: &findings, construction: construction)
                    }
                }
            }
        }
        var driverCapacity = try sum(design.ports.count, design.nets.count, construction: construction)
        for instance in design.instances {
            _ = try construction(.checkpoint)
            _ = try construction(.work(libraries.count)); _ = try construction(.inspect(instance.cell))
            if let cell = libraries.lazy.compactMap({ $0.cells[instance.cell] }).first {
                driverCapacity = try sum(driverCapacity, cell.pins.count, construction: construction)
            }
        }
        let driversReceipt = try construction(.drivers(driverCapacity))
        defer { withExtendedLifetime(driversReceipt) {} }
        var drivers: [String: Int] = [:]; drivers.reserveCapacity(driverCapacity)
        for port in design.ports {
            _ = try construction(.checkpoint)
            guard port.direction == .input || port.direction == .bidirectional else { continue }
            drivers[port.netName, default: 0] += 1
        }
        for net in design.nets {
            _ = try construction(.checkpoint)
            if net.constant != nil { drivers[net.name, default: 0] += 1 }
        }
        for instance in design.instances {
            _ = try construction(.checkpoint)
            _ = try construction(.work(libraries.count)); _ = try construction(.inspect(instance.cell))
            guard let cell = libraries.lazy.compactMap({ $0.cells[instance.cell] }).first else { continue }
            let outputPins = try select(cell.pins, { $0.direction == .output || $0.direction == .bidirectional }, construction: construction)
            defer { withExtendedLifetime(outputPins) {} }
            for pin in outputPins.value {
                _ = try construction(.checkpoint)
                _ = try construction(.inspect(pin.name))
                if let net = instance.connections[pin.name] { drivers[net, default: 0] += 1 }
            }
            for (pin, _) in instance.connections {
                _ = try construction(.work(cell.pins.count)); _ = try construction(.inspect(pin))
                guard cell.pin(named: pin) == nil else { continue }
                _ = try construction(.checkpoint)
                try append(finding("timing.design.pin-invalid", "A connected pin is absent from its cell.", try joined(instance.name, "/", pin, construction: construction)), findings: &findings, construction: construction)
            }
        }
        for (net, count) in drivers {
            _ = try construction(.checkpoint)
            guard count > 1 else { continue }
            try append(finding("timing.design.multiple-drivers", "A physical net has conflicting drivers.", net), findings: &findings, construction: construction)
        }
        for instance in design.instances {
            _ = try construction(.inspect(instance.cell))
            guard !knownCells.contains(instance.cell) else { continue }
            _ = try construction(.checkpoint)
            try append(finding(
                "timing.library.instance-cell-missing",
                "A design instance does not resolve in the bound timing libraries.",
                instance.name
            ), findings: &findings, construction: construction)
        }
    }

    private func validate(
        _ parasitics: TimingParasitics,
        design: TimingDesign,
        findings: inout FindingBuffer, construction: Construction
    ) rethrows {
        let parasiticReport = try validateSignalIntegrityParasitics(parasitics, construction: construction)
        defer { withExtendedLifetime(parasiticReport) {} }
        for value in parasiticReport.value.findings {
            try append(value, findings: &findings, construction: construction)
        }
        let designNets = try identifiers(try concatenate(try project(design.nets, { $0.name }, construction: construction),
            try project(try select(design.ports, { $0.net == nil }, construction: construction), { $0.name }, construction: construction),
            construction: construction), construction: construction)
        defer { withExtendedLifetime(designNets) {} }
        for network in parasitics.networks {
            _ = try construction(.checkpoint)
            if !designNets.value.contains(network.name) {
                try append(finding("timing.parasitic.network-invalid", "A parasitic network is absent from the logical design.", network.name), findings: &findings, construction: construction)
            }
            for record in network.capacitances {
                _ = try construction(.checkpoint)
                let endpoints = try capacitanceEndpoints(record, construction: construction)
                defer { withExtendedLifetime(endpoints) {} }
                for endpoint in endpoints.value {
                    _ = try construction(.checkpoint)
                    if !designNets.value.contains(endpoint.ownerNet) {
                        try append(finding("timing.parasitic.endpoint-invalid", "A parasitic endpoint owner is absent from the logical design.", endpoint.ownerNet), findings: &findings, construction: construction)
                    }
                }
            }
        }
    }

    private func validateUnique(_ values: Payload<[String]>, kind: String,
        findings: inout FindingBuffer, construction: Construction) rethrows {
        defer { withExtendedLifetime(values) {} }
        let receipt = try construction(.stringSet(values.value.count))
        defer { withExtendedLifetime(receipt) {} }
        var seen = Set<String>(minimumCapacity: values.value.count)
        for value in values.value {
            _ = try construction(.checkpoint)
            _ = try construction(.inspect(value))
            if !seen.insert(value).inserted {
                try append(finding(try joined("timing.", kind, ".duplicate", construction: construction),
                    try joined("Canonical ", kind, " identities must be unique.", construction: construction), value),
                    findings: &findings, construction: construction)
            }
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
    private typealias Construction = (ConstructionEvent) throws -> LibertySourceStorageReservation?

    private enum ConstructionEvent {
        case checkpoint
        case work(Int)
        case inspect(String)
        case sum(Int, Int)
        case array(Int, Int)
        case payload(Int)
        case stringSet(Int)
        case identifiers(Int)
        case stringOwners(Int)
        case drivers(Int)
        case temporaryText(Int)
        case retainedText(Int, Int, Int)
        case producedText(String, LibertySourceStorageReservation?)
        case findingGrowth(Int)
    }

    private final class Payload<Value> {
        let value: Value
        let receipt: LibertySourceStorageReservation?
        private let metadata: LibertySourceStorageReservation?
        init(_ value: Value, receipt: LibertySourceStorageReservation?, metadata: LibertySourceStorageReservation?) {
            self.value = value; self.receipt = receipt; self.metadata = metadata
        }
    }

    private struct TextAnchorStorage: ~Copyable, Sendable {
        let value = Mutex<String?>(nil)
        let metadata: LibertySourceStorageReservation
        init(metadata: LibertySourceStorageReservation) { self.metadata = metadata }
    }

    private final class TextAnchor: Sendable {
        private let storage: TextAnchorStorage
        init(metadata: LibertySourceStorageReservation) { storage = TextAnchorStorage(metadata: metadata) }
        func complete(_ text: String) { storage.value.withLock { $0 = text } }
    }

    private struct FindingBuffer {
        var values: [TimingCanonicalValidationFinding] = []
        var receipt: LibertySourceStorageReservation?
        var capacity = 0
    }

    /// This callback context is confined to one synchronous validation invocation.
    private final class Accounting {
        let transform: TimingTextTransform
        private let metadata: LibertySourceStorageReservation
        private var pendingText: TextAnchor?

        init(transform: TimingTextTransform) throws {
            let metadata = try transform.storage.reserve(
                (TimingTextTransform, LibertySourceStorageReservation, TextAnchor?).self,
                capacity: 1, kind: .temporaryBytes)
            self.transform = transform; self.metadata = metadata
        }

        func admit(_ event: ConstructionEvent) throws -> LibertySourceStorageReservation? {
            switch event {
            case .checkpoint:
                try transform.storage.step()
            case .work(let units):
                guard units >= 0 else { throw LibertySourceError.arithmeticOverflow }
                try transform.storage.step(UInt64(units))
            case .inspect(let value):
                try transform.storage.step(UInt64(value.utf8.count))
            case .sum(let first, let second):
                _ = try LibertyParseStorage.add(first, second)
                try transform.storage.step()
            case .array(let stride, let count):
                guard stride >= 0, count >= 0 else { throw LibertySourceError.arithmeticOverflow }
                let bytes = UInt64(stride).multipliedReportingOverflow(by: UInt64(count))
                guard !bytes.overflow else { throw LibertySourceError.arithmeticOverflow }
                try transform.storage.step(UInt64(count))
                return try transform.resources.reserveStorage(kind: .temporaryBytes, byteCount: bytes.partialValue)
            case .payload(let stride):
                guard stride >= 0 else { throw LibertySourceError.arithmeticOverflow }
                try transform.storage.step()
                return try transform.storage.reserve(UInt8.self, capacity: stride, kind: .temporaryBytes)
            case .stringSet(let count):
                return try transform.reserveSet(String.self, capacity: count)
            case .identifiers(let count):
                return try transform.reserveSet(UInt64.self, capacity: count)
            case .stringOwners(let count):
                return try transform.reserveDictionary(String.self, String.self, capacity: count)
            case .drivers(let count):
                return try transform.reserveDictionary(String.self, Int.self, capacity: count)
            case .temporaryText(let count):
                try transform.storage.step(UInt64(count))
                return try transform.storage.reserve(UInt8.self, capacity: count, kind: .temporaryBytes)
            case .retainedText(let first, let second, let third):
                guard pendingText == nil else { throw TimingError.invariantViolation("Unfinished canonical text construction") }
                let count = try LibertyParseStorage.add(LibertyParseStorage.add(first, second), third)
                let lease = try transform.storage.reserve(UInt8.self, capacity: count, kind: .liveOwnedBytes)
                let anchorMetadata = try transform.storage.reserve(
                    UInt8.self, capacity: MemoryLayout<TextAnchorStorage>.stride, kind: .liveOwnedBytes)
                try transform.storage.step(UInt64(count))
                let anchor = TextAnchor(metadata: anchorMetadata)
                // All holder metadata and insertion capacity are admitted before
                // the semantic body constructs its actual String payload.
                try transform.storage.hold(anchor, receipt: lease, kind: .liveOwnedBytes)
                pendingText = anchor
                return lease
            case .producedText(let value, let receipt):
                guard let anchor = pendingText else { throw TimingError.invariantViolation("Missing canonical text admission") }
                // This transfer cannot call an exhausted/cancelled accountant.
                // The immutable failure/report owner already retains this anchor.
                anchor.complete(value)
                pendingText = nil
                guard let receipt, UInt64(value.utf8.count) <= receipt.byteCount else {
                    throw TimingError.invariantViolation("Canonical text exceeded its source-derived admission")
                }
            case .findingGrowth(let oldCapacity):
                guard oldCapacity >= 0 else { throw LibertySourceError.arithmeticOverflow }
                let doubled = oldCapacity.multipliedReportingOverflow(by: 2)
                guard !doubled.overflow else { throw LibertySourceError.arithmeticOverflow }
                return try transform.storage.reserve(TimingCanonicalValidationFinding.self,
                    capacity: max(1, doubled.partialValue), kind: .liveOwnedBytes)
            }
            return nil
        }
    }

    private func publish(_ result: Payload<TimingCanonicalValidationReport>, transform: TimingTextTransform) throws
        -> TimingTransformValue<TimingCanonicalValidationReport> {
        defer { withExtendedLifetime(result) {} }
        if let receipt = result.receipt {
            try transform.storage.hold(result.value.findings, receipt: receipt, kind: .liveOwnedBytes)
        }
        return try transform.finish(result.value)
    }

    private func payload<Value>(_ value: Value, receipt: LibertySourceStorageReservation? = nil,
        construction: Construction) rethrows -> Payload<Value> {
        let metadata = try construction(.payload(MemoryLayout<(Value, LibertySourceStorageReservation?, LibertySourceStorageReservation?)>.stride))
        return Payload(value, receipt: receipt, metadata: metadata)
    }

    private func sum(_ first: Int, _ second: Int, construction: Construction) rethrows -> Int {
        _ = try construction(.sum(first, second))
        return first + second
    }

    private func project<C: Collection, Element>(_ input: C, _ body: (C.Element) -> Element,
        construction: Construction) rethrows -> Payload<[Element]> {
        let receipt = try construction(.array(MemoryLayout<Element>.stride, input.count))
        var values: [Element] = []; values.reserveCapacity(input.count)
        for item in input { _ = try construction(.checkpoint); values.append(body(item)) }
        return try payload(values, receipt: receipt, construction: construction)
    }

    private func project<Element, Result>(_ input: Payload<[Element]>, _ body: (Element) -> Result,
        construction: Construction) rethrows -> Payload<[Result]> {
        defer { withExtendedLifetime(input) {} }
        return try project(input.value, body, construction: construction)
    }

    private func select<C: Collection>(_ input: C, _ predicate: (C.Element) -> Bool,
        construction: Construction) rethrows -> Payload<[C.Element]> {
        let receipt = try construction(.array(MemoryLayout<C.Element>.stride, input.count))
        var values: [C.Element] = []; values.reserveCapacity(input.count)
        for item in input { _ = try construction(.checkpoint); if predicate(item) { values.append(item) } }
        return try payload(values, receipt: receipt, construction: construction)
    }

    private func concatenate<Element>(_ first: Payload<[Element]>, _ second: Payload<[Element]>,
        construction: Construction) rethrows -> Payload<[Element]> {
        defer { withExtendedLifetime((first, second)) {} }
        let count = try sum(first.value.count, second.value.count, construction: construction)
        let receipt = try construction(.array(MemoryLayout<Element>.stride, count))
        var values: [Element] = []; values.reserveCapacity(count)
        for value in first.value { _ = try construction(.checkpoint); values.append(value) }
        for value in second.value { _ = try construction(.checkpoint); values.append(value) }
        return try payload(values, receipt: receipt, construction: construction)
    }

    private func identifiers(_ input: Payload<[String]>, construction: Construction) rethrows -> Payload<Set<String>> {
        defer { withExtendedLifetime(input) {} }
        let receipt = try construction(.stringSet(input.value.count))
        var values = Set<String>(minimumCapacity: input.value.count)
        for value in input.value { _ = try construction(.inspect(value)); values.insert(value) }
        return try payload(values, receipt: receipt, construction: construction)
    }

    private func union(_ first: Payload<Set<String>>, _ second: Payload<[String]>,
        construction: Construction) rethrows -> Payload<Set<String>> {
        defer { withExtendedLifetime((first, second)) {} }
        let count = try sum(first.value.count, second.value.count, construction: construction)
        let receipt = try construction(.stringSet(count))
        var values = Set<String>(minimumCapacity: count)
        for value in first.value { _ = try construction(.inspect(value)); values.insert(value) }
        for value in second.value { _ = try construction(.inspect(value)); values.insert(value) }
        return try payload(values, receipt: receipt, construction: construction)
    }

    private func resistanceEndpoints(_ input: [TimingParasitics.ResistanceRecord],
        construction: Construction) rethrows -> Payload<[TimingParasitics.Endpoint]> {
        let count = try sum(input.count, input.count, construction: construction)
        let receipt = try construction(.array(MemoryLayout<TimingParasitics.Endpoint>.stride, count))
        var values: [TimingParasitics.Endpoint] = []; values.reserveCapacity(count)
        for record in input { _ = try construction(.checkpoint); values.append(record.first); values.append(record.second) }
        return try payload(values, receipt: receipt, construction: construction)
    }

    private func capacitanceEndpoints(_ record: TimingParasitics.CapacitanceRecord,
        construction: Construction) rethrows -> Payload<[TimingParasitics.Endpoint]> {
        let count = record.second == nil ? 1 : 2
        let receipt = try construction(.array(MemoryLayout<TimingParasitics.Endpoint>.stride, count))
        var values: [TimingParasitics.Endpoint] = []; values.reserveCapacity(count)
        values.append(record.first); if let second = record.second { values.append(second) }
        return try payload(values, receipt: receipt, construction: construction)
    }

    private func flatten<Element>(_ input: [[Element]], construction: Construction) rethrows -> Payload<[Element]> {
        var count = 0
        for values in input { _ = try construction(.checkpoint); count = try sum(count, values.count, construction: construction) }
        let receipt = try construction(.array(MemoryLayout<Element>.stride, count))
        var result: [Element] = []; result.reserveCapacity(count)
        for values in input { for value in values { _ = try construction(.checkpoint); result.append(value) } }
        return try payload(result, receipt: receipt, construction: construction)
    }

    private func trimmedIsEmpty(_ input: String, construction: Construction) rethrows -> Bool {
        let receipt = try construction(.temporaryText(input.utf8.count))
        defer { withExtendedLifetime(receipt) {} }
        return input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func joined(_ first: String, _ separator: String, _ second: String,
        construction: Construction) rethrows -> String {
        let count = try sum(try sum(first.utf8.count, separator.utf8.count, construction: construction),
            second.utf8.count, construction: construction)
        let receipt = try construction(.retainedText(first.utf8.count, separator.utf8.count, second.utf8.count))
        var result = String(); result.reserveCapacity(count)
        result.append(first); result.append(separator); result.append(second)
        _ = try construction(.producedText(result, receipt))
        return result
    }

    private func append(_ value: @autoclosure () throws -> TimingCanonicalValidationFinding,
        findings: inout FindingBuffer, construction: Construction) rethrows {
        _ = try construction(.checkpoint)
        if findings.values.count == findings.capacity {
            let receipt = try construction(.findingGrowth(findings.capacity))
            let capacity = max(1, findings.capacity * 2)
            _ = try construction(.work(findings.values.count))
            var replacement: [TimingCanonicalValidationFinding] = []; replacement.reserveCapacity(capacity)
            replacement.append(contentsOf: findings.values)
            findings.values = replacement; findings.receipt = receipt; findings.capacity = capacity
        }
        findings.values.append(try value())
    }

}

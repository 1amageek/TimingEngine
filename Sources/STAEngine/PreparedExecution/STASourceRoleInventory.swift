import CircuiteFoundation
import TimingCore

/// Derives required source roles from retained inputs, independently of execution reports.
internal enum STASourceRoleInventory {
    static func scenario(design: TimingDesign, source: OwnedLibertySource, library: ArtifactReference,
                         mode: String, corner: String, limits: STAExecutionLimits,
                         resources: any LibertySourceResourceAccounting, stateBudget: NativeSTAStateBudget,
                         work: inout UInt64) throws -> [STASourceEvidence.Role] {
        var roles: [STASourceEvidence.Role] = []
        func append(_ role: STASourceEvidence.Role) throws {
            try resources.check(); try Task.checkCancellation()
            let next = work.addingReportingOverflow(1)
            guard !next.overflow, next.partialValue <= limits.maximumPathWorkUnits else {
                throw STAPreparationError.capacity("Source inventory work exceeds the native allowance")
            }
            guard roles.count < limits.maximumPathStates else {
                throw STAPreparationError.capacity("Source role inventory exceeds the state allowance")
            }
            try stateBudget.reserve(1); try resources.chargeWork(1)
            work = next.partialValue; roles.append(role)
        }
        for instance in design.instances {
            try resources.check()
            let scan = source.cells.count.addingReportingOverflow(source.library.cells.count)
            guard !scan.overflow else { throw STAPreparationError.capacity("Source inventory lookup overflow") }
            let lookupWork = work.addingReportingOverflow(UInt64(scan.partialValue))
            guard !lookupWork.overflow, lookupWork.partialValue <= limits.maximumPathWorkUnits else {
                throw STAPreparationError.capacity("Source inventory lookup work exceeds the native allowance")
            }
            try resources.chargeWork(UInt64(scan.partialValue)); work = lookupWork.partialValue
            guard let original = source.cells.first(where: { $0.name == instance.cell }) else {
                throw TimingError.invariantViolation("A mapped instance lost its exact source cell")
            }
            let cell = try source.library.cell(named: instance.cell)
            try append(.init(modeID:mode,cornerID:corner,library:library,instance:instance.name,
                cell:instance.cell,pin:"",kind:.normalPower))
            for pin in original.pins {
                try append(.init(modeID: mode, cornerID: corner, library: library,
                    instance: instance.name, cell: instance.cell, pin: pin.name, kind: .pin))
            }
            for pin in original.powerPins {
                try append(.init(modeID: mode, cornerID: corner, library: library,
                    instance: instance.name, cell: instance.cell, pin: pin.name, kind: .powerPin))
            }
            if let model = cell.sequentialModel {
                let plan = try NativeSTASequentialExecution.compile(model: model, source: original, work: &work,
                    limits: limits, stateBudget: stateBudget, sourceResources: resources)
                try append(.init(modeID: mode, cornerID: corner, library: library,
                    instance: instance.name, cell: instance.cell, pin: "", kind: .sequentialDefinition))
                for kind in [STAAnalysisKind.recovery, .removal] where plan.controlPins.isEmpty
                    && !(model.timingChecks ?? []).contains(where: { $0.kind.rawValue == kind.rawValue }) {
                    try append(.init(modeID: mode, cornerID: corner, library: library,
                        instance: instance.name, cell: instance.cell, pin: plan.clockPin,
                        kind: .checkApplicability, applicableKind: kind))
                }
                for pin in plan.controlPins {
                    for kind in [STAAnalysisKind.recovery, .removal]
                        where !(model.timingChecks ?? []).contains(where: { $0.constrainedPin == pin && $0.kind.rawValue == kind.rawValue }) {
                        try append(.init(modeID: mode, cornerID: corner, library: library,
                            instance: instance.name, cell: instance.cell, pin: pin,
                            kind: .checkApplicability, applicableKind: kind))
                    }
                }
                if cell.pulseWidthConstraints.isEmpty {
                    try append(.init(modeID: mode, cornerID: corner, library: library,
                        instance: instance.name, cell: instance.cell, pin: plan.clockPin,
                        kind: .checkApplicability, applicableKind: .pulseWidth))
                }
            }
            for law in cell.pulseWidthConstraints {
                guard let identity = law.sourceIdentity else { throw TimingCharacterizationError.missingSourceFact("positioned pulse law") }
                try append(.init(modeID: mode, cornerID: corner, library: library,
                    instance: instance.name, cell: instance.cell, pin: law.pin, relatedPin: law.relatedPin,
                    kind: .pulseWidth, source: identity, constrainedEdge: law.openingEdge,
                    relatedEdge: law.openingEdge == .rise ? .fall : .rise))
            }
            for arc in cell.directionalControlArcs {
                try append(.init(modeID: mode, cornerID: corner, library: library,
                    instance: instance.name, cell: instance.cell, pin: arc.toPin, relatedPin: arc.fromPin,
                    kind: .directionalControlPropagation, source: arc.sourceIdentity))
            }
            for arc in cell.arcs where !arc.isConstraint {
                guard let identity = arc.sourceIdentity else {
                    throw TimingCharacterizationError.missingSourceFact("source propagation identity")
                }
                try append(.init(modeID: mode, cornerID: corner, library: library,
                    instance: instance.name, cell: instance.cell, pin: arc.toPin, relatedPin: arc.fromPin,
                    kind: .propagation, source: identity))
            }
            for check in cell.sequentialModel?.timingChecks ?? [] {
                guard let identity = check.sourceIdentity else {
                    throw TimingCharacterizationError.missingSourceFact("source check identity")
                }
                try append(.init(modeID: mode, cornerID: corner, library: library,
                    instance: instance.name, cell: instance.cell, pin: check.constrainedPin, relatedPin: check.relatedPin,
                    kind: .sequentialCheck, source: identity, constrainedEdge: check.constrainedEdge,
                    relatedEdge: check.relatedEdge, checkKind: check.kind))
            }
        }
        return roles
    }
}

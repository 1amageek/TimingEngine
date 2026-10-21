import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation
import TimingCore
import TimingPDKProfileInspection

/// Checked immutable owner; execution never reopens source materializations.
public struct PreparedSTAExecution: Sendable {
    public let request: STARequest
    public let executionInputIdentity: ContentDigest
    public var grammarPolicyIdentity: String { "timing.liberty.owned.v1" }
    public let processSelection: STAProcessSelection
    public let effectiveConfiguration: STAEffectiveConfiguration
    public var configurationDigest: ContentDigest { effectiveConfiguration.digest }
    public let characterization: [STACharacterizationObservation]
    public let libraryConsumption: [STALibraryConsumption]
    public let sourceRoleInventory: [STASourceEvidence.Role]
    public var inputReferences: [ArtifactReference] { request.inputs }
    internal let sourceResources: any LibertySourceResourceAccounting
    internal var transformRetention: NativeSTATransformRetention? = nil
    internal let transformResources: (any LibertySourceResourceAccounting)?
    internal let runtimeIdentityReadBudget: ArtifactAccessBudget
    internal let clockCharacterization: [String: CharacterizedTimingLibrary]
    internal let design: TimingDesign
    internal let processInputs: STATimingProcessInputs
    internal let constraints: [String: TimingConstraintSet]
    internal let parasiticSource: TimingParasitics?
    internal let parasitics: TimingLumpedParasitics?
    internal let modeIDs: [String]
    internal let limits: STAExecutionLimits
    internal let designBindingBudget: NativeSTADesignBindingBudget
    public let inspectedSources: TimingInspectedLibertySources?
    internal init(request: STARequest, design: TimingDesign, processInputs: STATimingProcessInputs,
        constraints: [String: TimingConstraintSet], parasitics: TimingLumpedParasitics?, parasiticSource: TimingParasitics?, modeIDs: [String],
        catalog: TimingInspectedLibertySources?, configuration: STAEffectiveConfiguration,
        characterization: [STACharacterizationObservation], sourceResources: any LibertySourceResourceAccounting, clockCharacterization: [String: CharacterizedTimingLibrary], limits: STAExecutionLimits,
        transformResources: (any LibertySourceResourceAccounting)? = nil,
        runtimeIdentityReadBudget: ArtifactAccessBudget = FileSystemTimingArtifactReader.defaultReadBudget) throws {
        let roleBudget = NativeSTAStateBudget(maximum: limits.maximumPathStates,
            transformResources: transformResources)
        let temporary = NativeSTATransformStorage(budget: roleBudget, kind: .temporaryBytes)
        let retained = NativeSTATransformStorage(budget: roleBudget, kind: .liveOwnedBytes)
        self.runtimeIdentityReadBudget = runtimeIdentityReadBudget
        if let transformResources {
            let inputReferences = try NativeSTARequestTransforms.references(request, storage: temporary)
            let encoded = try TimingJSONEncoding.encode(inputReferences,
                prefix: "timing.sta.execution.inputs.v1\0", formatting: [.sortedKeys], resources: transformResources)
            let digester = SHA256ContentDigester()
            let copy = try digester.foundationDataCopyCost(byteCount: UInt64(encoded.value.count))
            let digest = try SHA256ContentDigester.managedCost(byteCount: UInt64(encoded.value.count))
            let byteCount = copy.temporaryByteCount.addingReportingOverflow(digest.temporaryByteCount)
            guard !byteCount.overflow, let scratchBytes = Int(exactly: byteCount.partialValue),
                  let digestBytes = Int(exactly: digest.retainedByteCount) else { throw LibertySourceError.arithmeticOverflow }
            let scratch = try roleBudget.reservePayload(UInt8.self, capacity: scratchBytes, kind: .temporaryBytes)
            try retained.reserve(UInt8.self, capacity: digestBytes)
            try roleBudget.chargeScheduledWork(copy.workUnits)
            try roleBudget.chargeScheduledWork(digest.workUnits)
            executionInputIdentity = try digester.digest(data: encoded.value, using: .sha256)
            try transformResources.check()
            withExtendedLifetime(scratch) {}
            withExtendedLifetime(encoded) {}
        } else {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var bytes = Data("timing.sta.execution.inputs.v1\0".utf8)
            bytes.append(try encoder.encode(request.inputs))
            executionInputIdentity = try SHA256ContentDigester().digest(data: bytes, using: .sha256)
        }
        try temporary.reserveSet(String.self, capacity: design.instances.count)
        let usedCells = Set(try temporary.map(design.instances, \.cell))
        var consumption: [STALibraryConsumption] = []
        for corner in processInputs.selection.corners {
            let temporary = NativeSTATransformStorage(budget: roleBudget, kind: .temporaryBytes)
            guard let source = processInputs.sourcesByCorner[corner.cornerID],
                  let reference = processInputs.selection.librariesByCorner[corner.cornerID] else {
                throw STAPreparationError.characterization("Missing retained library consumption source")
            }
            let cells = try temporary.filter(source.cells) { usedCells.contains($0.name) }
            let cellNames = try retained.sorted(try temporary.map(cells, \.name), by: <)
            var pinNames: [String] = []
            for cell in cells {
                for pin in cell.pins {
                    try temporary.append(retained.joined(cell.name, ".", pin.name), to: &pinNames)
                }
            }
            let sortedPins = try retained.sorted(pinNames, by: <)
            let selectedConditions = try temporary.filter(characterization) { $0.cornerID == corner.cornerID && $0.selected }
            let conditionNames = try retained.map(selectedConditions, \.conditionName)
            try retained.append(STALibraryConsumption(cornerID: corner.cornerID, source: reference,
                cellNames: cellNames, pinNames: sortedPins, conditionNames: conditionNames), to: &consumption)

        }
        libraryConsumption = consumption
        var roles: [STASourceEvidence.Role] = []
        if request.requireStrictSourceEvidence {
            var roleWork: UInt64 = 0
            for mode in modeIDs {
                for corner in processInputs.selection.corners {
                    guard let source = processInputs.sourcesByCorner[corner.cornerID],
                          let reference = processInputs.selection.librariesByCorner[corner.cornerID] else {
                        throw STAPreparationError.characterization("Missing exact source role inventory")
                    }
                    let scenarioStorage = NativeSTATransformStorage(budget: roleBudget, kind: .temporaryBytes)
                    let scenario = try STASourceRoleInventory.scenario(design: design, source: source, library: reference,
                        mode: mode, corner: corner.cornerID, limits: limits, resources: sourceResources,
                        stateBudget: roleBudget, work: &roleWork, transformStorage: scenarioStorage)
                    let total = roles.count.addingReportingOverflow(scenario.count)
                    guard !total.overflow, total.partialValue <= limits.maximumPathStates else {
                        throw STAPreparationError.capacity("Complete source role inventory exceeds the state allowance")
                    }
                    // One retained output inventory; no display-path traversal supplies these roles.
                    try retained.append(contentsOf: scenario, to: &roles)
                    withExtendedLifetime(scenarioStorage) {}
                }
            }
        }
        sourceRoleInventory = roles
        transformRetention = try retained.finish()
        withExtendedLifetime(temporary) {}
        designBindingBudget = try NativeSTADesignBindingBudget(limits: limits, resources: sourceResources, transformResources: transformResources)
        self.sourceResources = sourceResources
        self.transformResources = transformResources
        self.clockCharacterization = clockCharacterization
        self.request = request; self.design = design; self.processInputs = processInputs
        self.processSelection = processInputs.selection; self.constraints = constraints; self.parasitics = parasitics; self.parasiticSource = parasiticSource
        self.modeIDs = modeIDs; self.limits = limits; self.inspectedSources = catalog; effectiveConfiguration = configuration; self.characterization = characterization
    }
}

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
        characterization: [STACharacterizationObservation], sourceResources: any LibertySourceResourceAccounting, clockCharacterization: [String: CharacterizedTimingLibrary], limits: STAExecutionLimits) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = Data("timing.sta.execution.inputs.v1\0".utf8)
        bytes.append(try encoder.encode(request.inputs))
        executionInputIdentity = try SHA256ContentDigester().digest(data: bytes, using: .sha256)
        let usedCells = Set(design.instances.map(\.cell))
        var consumption: [STALibraryConsumption] = []
        for corner in processInputs.selection.corners {
            guard let source = processInputs.sourcesByCorner[corner.cornerID],
                  let reference = processInputs.selection.librariesByCorner[corner.cornerID] else {
                throw STAPreparationError.characterization("Missing retained library consumption source")
            }
            let cells = source.cells.filter { usedCells.contains($0.name) }
            consumption.append(.init(cornerID: corner.cornerID, source: reference,
                cellNames: cells.map(\.name).sorted(), pinNames: cells.flatMap { cell in cell.pins.map { cell.name + "." + $0.name } }.sorted(),
                conditionNames: characterization.filter { $0.cornerID == corner.cornerID && $0.selected }.map(\.conditionName)))
        }
        libraryConsumption = consumption
        var roles: [STASourceEvidence.Role] = []
        if request.requireStrictSourceEvidence {
            let roleBudget = NativeSTAStateBudget(maximum: limits.maximumPathStates)
            var roleWork: UInt64 = 0
            for mode in modeIDs {
                for corner in processInputs.selection.corners {
                    guard let source = processInputs.sourcesByCorner[corner.cornerID],
                          let reference = processInputs.selection.librariesByCorner[corner.cornerID] else {
                        throw STAPreparationError.characterization("Missing exact source role inventory")
                    }
                    let scenario = try STASourceRoleInventory.scenario(design: design, source: source, library: reference,
                        mode: mode, corner: corner.cornerID, limits: limits, resources: sourceResources,
                        stateBudget: roleBudget, work: &roleWork)
                    let total = roles.count.addingReportingOverflow(scenario.count)
                    guard !total.overflow, total.partialValue <= limits.maximumPathStates else {
                        throw STAPreparationError.capacity("Complete source role inventory exceeds the state allowance")
                    }
                    // One retained output inventory; no display-path traversal supplies these roles.
                    roles.append(contentsOf: scenario)
                }
            }
        }
        sourceRoleInventory = roles
        designBindingBudget = try NativeSTADesignBindingBudget(limits:limits,resources:sourceResources)
        self.sourceResources = sourceResources
        self.clockCharacterization = clockCharacterization
        self.request = request; self.design = design; self.processInputs = processInputs
        self.processSelection = processInputs.selection; self.constraints = constraints; self.parasitics = parasitics; self.parasiticSource = parasiticSource
        self.modeIDs = modeIDs; self.limits = limits; self.inspectedSources = catalog; effectiveConfiguration = configuration; self.characterization = characterization
    }
}

import Foundation
import CircuiteFoundation

public struct TimingParasiticReductionEvidence: Sendable, Hashable, Codable {
    public struct InventoryComparison: Sendable, Hashable, Codable {
        public let net: String
        public let declaredCapacitance: Double
        public let localRecordCapacitance: Double
        public let incidentOperatorCapacitance: Double
        public var difference: Double { declaredCapacitance - incidentOperatorCapacitance }
        public var hasIncomingOnlyListing: Bool { localRecordCapacitance != incidentOperatorCapacitance }

        public init(net: String, declaredCapacitance: Double, localRecordCapacitance: Double, incidentOperatorCapacitance: Double = 0) {
            self.net = net
            self.declaredCapacitance = declaredCapacitance
            self.localRecordCapacitance = localRecordCapacitance
            self.incidentOperatorCapacitance = incidentOperatorCapacitance
        }
    }

    public static let currentPolicyID = "equipotential-cap-load-v1"
    public let policyID: String
    public let assumptions: [String]
    public let collapsedIntraNetCapacitances: [TimingParasitics.CapacitanceRecord]
    public let mirroredSourceGroups: [[TimingParasitics.SourceID]]
    public let inventoryComparisons: [InventoryComparison]
    public let effectiveLoads: [String: Double]

    public var isDistributedSignoffEvidence: Bool { false }

    public func diagnostics(prefix: String) -> [DesignDiagnostic] {
        var result = [DesignDiagnostic(severity: .warning, code: prefix + ".equipotential_cap_load_approximation",
            message: "Equipotential cap-load approximation assumes stationary other nets and does not evaluate distributed finite-resistance dynamics.",
            suggestedActions: ["inspect_parasitic_reduction_evidence", "use_distributed_analysis_before_signoff"])]
        if !collapsedIntraNetCapacitances.isEmpty {
            result.append(DesignDiagnostic(severity: .warning, code: prefix + ".intra_net_dynamic_capacitance_not_evaluated",
                message: "\(collapsedIntraNetCapacitances.count) same-net capacitance operators retain exact endpoints and values but contribute zero under the equipotential projection.",
                suggestedActions: ["inspect_collapsed_intra_net_capacitances", "use_distributed_analysis_before_signoff"]))
        }
        if inventoryComparisons.contains(where: { $0.difference != 0 }) {
            result.append(DesignDiagnostic(severity: .warning, code: prefix + ".declared_capacitance_inventory_differs",
                message: "D_NET declarations differ from resolved incident operator totals; derived loads use preserved CAP records.",
                suggestedActions: ["inspect_inventory_comparisons"]))
        }
        return result
    }

    init(collapsedIntraNetCapacitances: [TimingParasitics.CapacitanceRecord],
         mirroredSourceGroups: [[TimingParasitics.SourceID]],
         inventoryComparisons: [InventoryComparison], effectiveLoads: [String: Double]) {
        self.policyID = Self.currentPolicyID
        self.assumptions = ["equipotential-within-each-logical-net", "stationary-other-net-for-cap-load", "distributed-finite-resistance-dynamics-not-evaluated"]
        self.collapsedIntraNetCapacitances = collapsedIntraNetCapacitances
        self.mirroredSourceGroups = mirroredSourceGroups
        self.inventoryComparisons = inventoryComparisons
        self.effectiveLoads = effectiveLoads
    }
}

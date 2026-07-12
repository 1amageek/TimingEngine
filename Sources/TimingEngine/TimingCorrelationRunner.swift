import Foundation
import STAEngine

public struct TimingCorrelationRunner: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 1e-15) {
        self.tolerance = tolerance
    }

    public func compare(
        native: STAPayload,
        reference: TimingReferenceResult
    ) -> TimingCorrelationResult {
        let setupDifference = difference(native.worstSetupSlack, reference.worstSetupSlack)
        let holdDifference = difference(native.worstHoldSlack, reference.worstHoldSlack)
        let setupPassed = matches(native.worstSetupSlack, reference.worstSetupSlack)
        let holdPassed = matches(native.worstHoldSlack, reference.worstHoldSlack)
        let passed = setupPassed && holdPassed
        var diagnostics: [String] = []
        if !setupPassed { diagnostics.append("worst_setup_slack_mismatch") }
        if !holdPassed { diagnostics.append("worst_hold_slack_mismatch") }
        return TimingCorrelationResult(
            oracleID: reference.oracleID,
            status: passed ? .passed : .failed,
            setupSlackDifference: setupDifference,
            holdSlackDifference: holdDifference,
            passed: passed,
            tolerance: tolerance,
            diagnostics: diagnostics
        )
    }

    private func matches(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs - rhs) <= tolerance
        default: return false
        }
    }

    private func difference(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs - rhs
    }
}

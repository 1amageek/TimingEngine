import Foundation
import STAEngine

public struct TimingExternalOracleCorrelator: Sendable {
    public var tolerance: Double

    public init(tolerance: Double = 1e-15) {
        self.tolerance = tolerance
    }

    public func compare(
        native: STAPayload,
        external: STAPayload,
        oracleID: String
    ) -> TimingCorrelationResult {
        let base = TimingCorrelationRunner(tolerance: tolerance).compare(
            native: native,
            reference: TimingReferenceResult(
                oracleID: oracleID,
                worstSetupSlack: external.worstSetupSlack,
                worstHoldSlack: external.worstHoldSlack
            )
        )
        var diagnostics = base.diagnostics
        if native.analyzedModes != external.analyzedModes { diagnostics.append("analyzed_modes_mismatch") }
        if native.analyzedCorners != external.analyzedCorners { diagnostics.append("analyzed_corners_mismatch") }
        if native.provenance != external.provenance { diagnostics.append("input_provenance_mismatch") }
        let passed = base.passed && diagnostics.isEmpty
        return TimingCorrelationResult(
            oracleID: oracleID,
            status: passed ? .passed : .failed,
            setupSlackDifference: base.setupSlackDifference,
            holdSlackDifference: base.holdSlackDifference,
            passed: passed,
            tolerance: tolerance,
            diagnostics: diagnostics
        )
    }
}

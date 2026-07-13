import Foundation
import DesignFlowKernel
import LogicIR
import TimingCore
import PDKCore

@available(*, deprecated, message: "Use SignalIntegrityFoundationEngine for all new executions.")
public protocol LegacySignalIntegrityAnalyzing: Sendable {
    func execute(
        _ request: SignalIntegrityRequest
    ) async throws -> SignalIntegrityExecutionResult
}

@available(*, deprecated, message: "Use SignalIntegrityFoundationEngine for all new executions.")
public typealias SignalIntegrityAnalyzing = LegacySignalIntegrityAnalyzing

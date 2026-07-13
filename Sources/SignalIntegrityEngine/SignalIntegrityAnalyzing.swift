import Foundation
import XcircuitePackage
import LogicIR
import TimingCore
import PDKCore

@available(*, deprecated, message: "Use SignalIntegrityFoundationEngine for all new executions.")
public protocol LegacySignalIntegrityAnalyzing: Sendable {
    func execute(
        _ request: SignalIntegrityRequest
    ) async throws -> XcircuiteEngineResultEnvelope<SignalIntegrityPayload>
}

@available(*, deprecated, message: "Use SignalIntegrityFoundationEngine for all new executions.")
public typealias SignalIntegrityAnalyzing = LegacySignalIntegrityAnalyzing

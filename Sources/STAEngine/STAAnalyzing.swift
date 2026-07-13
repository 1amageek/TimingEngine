import Foundation
import XcircuitePackage
import LogicIR
import TimingCore
import PDKCore

@available(*, deprecated, message: "Use STAFoundationEngine for all new executions.")
public protocol LegacySTAAnalyzing: Sendable {
    func execute(
        _ request: STARequest
    ) async throws -> XcircuiteEngineResultEnvelope<STAPayload>
}

@available(*, deprecated, message: "Use STAFoundationEngine for all new executions.")
public typealias STAAnalyzing = LegacySTAAnalyzing

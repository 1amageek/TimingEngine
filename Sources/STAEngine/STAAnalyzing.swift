import Foundation
import XcircuitePackage
import LogicIR
import TimingCore
import PDKCore

public protocol STAAnalyzing: Sendable {
    func execute(
        _ request: STARequest
    ) async throws -> XcircuiteEngineResultEnvelope<STAPayload>
}

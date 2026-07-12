import Foundation
import XcircuitePackage
import LogicIR
import TimingCore
import PDKCore

public protocol SignalIntegrityAnalyzing: Sendable {
    func execute(
        _ request: SignalIntegrityRequest
    ) async throws -> XcircuiteEngineResultEnvelope<SignalIntegrityPayload>
}

import Foundation

public protocol TimingExternalOracleRunning: Sendable {
    func execute(_ request: TimingExternalOracleRequest) async throws -> TimingExternalOracleResult
}

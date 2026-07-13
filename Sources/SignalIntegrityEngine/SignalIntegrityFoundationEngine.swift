@_exported import CircuiteFoundation

/// Foundation engine seam for coupling-aware signal-integrity analysis.
public protocol SignalIntegrityFoundationEngine: Engine
where Request == SignalIntegrityFoundationRequest, Output == SignalIntegrityExecutionResult {}

public typealias SignalIntegrityEngineProtocol = SignalIntegrityFoundationEngine

import CircuiteFoundation

/// Executes coupling-aware signal-integrity analysis through the shared engine contract.
public protocol SignalIntegrityExecuting: Engine
where Request == SignalIntegrityRequest, Output == SignalIntegrityExecutionResult {}

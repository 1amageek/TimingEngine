import CircuiteFoundation

/// Executes static timing analysis through the shared engine contract.
public protocol STAExecuting: Engine
where Request == STARequest, Output == STAExecutionResult {}

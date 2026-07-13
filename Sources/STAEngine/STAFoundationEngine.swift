@_exported import CircuiteFoundation

/// Foundation engine seam for static timing analysis.
public protocol STAFoundationEngine: Engine
where Request == STAFoundationRequest, Output == STAExecutionResult {}

public typealias STAEngineProtocol = STAFoundationEngine

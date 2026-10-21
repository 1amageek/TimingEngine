import CircuiteFoundationFileSystem

/// Controlled transform failures preserve the caller cause and secondary cleanup.
public enum TimingTransformError: Error, Sendable {
    case unsupportedCapability(String)
    case resource(any Error)
    case cleanupFailed(primary: any Error, secondary: any Error)
}

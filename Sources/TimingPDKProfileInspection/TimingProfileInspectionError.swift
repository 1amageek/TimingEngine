import TimingCore

public enum TimingProfileInspectionError: Error, Sendable {
    case closedSession, unadmittedSource, conflictingSource, emptyCatalog
}

import TimingCore

public struct STAEndpoint: Sendable, Hashable, Codable {
    public var modeID: String
    public var cornerID: String
    public var endpoint: String
    public var setupSlack: Double?
    public var holdSlack: Double?
    public var recoverySlack: Double?
    public var removalSlack: Double?
    public var pulseWidthSlack: Double?
    public var dataSlew: Double?
    public var dataArrival: Double?
    public var requiredArrival: Double?
    public var staticValue: TimingDesign.Constant?
    public var staticChecks: [STAAnalysisKind]?
    public var excludedChecks: [STAAnalysisKind]?
    public var unconstrainedChecks: [STAAnalysisKind]?
    public var notApplicableChecks: [STAAnalysisKind]?

    public init(
        modeID: String,
        cornerID: String,
        endpoint: String,
        setupSlack: Double? = nil,
        holdSlack: Double? = nil,
        recoverySlack: Double? = nil,
        removalSlack: Double? = nil,
        pulseWidthSlack: Double? = nil,
        dataArrival: Double? = nil,
        dataSlew: Double? = nil,
        requiredArrival: Double? = nil,
        staticValue: TimingDesign.Constant? = nil,
        staticChecks: [STAAnalysisKind]? = nil,
        excludedChecks: [STAAnalysisKind]? = nil,
        unconstrainedChecks: [STAAnalysisKind]? = nil,
        notApplicableChecks: [STAAnalysisKind]? = nil
    ) {
        self.modeID = modeID
        self.cornerID = cornerID
        self.endpoint = endpoint
        self.setupSlack = setupSlack
        self.holdSlack = holdSlack
        self.recoverySlack = recoverySlack
        self.removalSlack = removalSlack
        self.pulseWidthSlack = pulseWidthSlack
        self.dataArrival = dataArrival
        self.dataSlew = dataSlew
        self.requiredArrival = requiredArrival
        self.staticValue = staticValue
        self.staticChecks = staticChecks
        self.excludedChecks = excludedChecks; self.unconstrainedChecks = unconstrainedChecks
        self.notApplicableChecks = notApplicableChecks
    }
}


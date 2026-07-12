import Foundation
import TimingCore

public struct STAPathStage: Sendable, Hashable, Codable {
    public var instance: String
    public var cell: String
    public var inputPin: String
    public var inputNet: String
    public var outputNet: String
    public var inputEdge: TimingEdge
    public var outputEdge: TimingEdge
    public var delay: Double
    public var outputSlew: Double
    public var load: Double

    public init(
        instance: String,
        cell: String,
        inputPin: String,
        inputNet: String,
        outputNet: String,
        inputEdge: TimingEdge,
        outputEdge: TimingEdge,
        delay: Double,
        outputSlew: Double,
        load: Double
    ) {
        self.instance = instance
        self.cell = cell
        self.inputPin = inputPin
        self.inputNet = inputNet
        self.outputNet = outputNet
        self.inputEdge = inputEdge
        self.outputEdge = outputEdge
        self.delay = delay
        self.outputSlew = outputSlew
        self.load = load
    }
}

public struct STAPath: Sendable, Hashable, Codable {
    public var modeID: String
    public var cornerID: String
    public var startpoint: String
    public var endpoint: String
    public var arrival: Double
    public var required: Double
    public var slack: Double
    public var stages: [STAPathStage]

    public init(
        modeID: String,
        cornerID: String,
        startpoint: String,
        endpoint: String,
        arrival: Double,
        required: Double,
        slack: Double,
        stages: [STAPathStage]
    ) {
        self.modeID = modeID
        self.cornerID = cornerID
        self.startpoint = startpoint
        self.endpoint = endpoint
        self.arrival = arrival
        self.required = required
        self.slack = slack
        self.stages = stages
    }
}

public struct STAEndpoint: Sendable, Hashable, Codable {
    public var modeID: String
    public var cornerID: String
    public var endpoint: String
    public var setupSlack: Double?
    public var holdSlack: Double?
    public var recoverySlack: Double?
    public var removalSlack: Double?
    public var pulseWidthSlack: Double?
    public var dataArrival: Double?
    public var requiredArrival: Double?

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
        requiredArrival: Double? = nil
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
        self.requiredArrival = requiredArrival
    }
}

public struct STAViolation: Sendable, Hashable, Codable {
    public var kind: STAAnalysisKind
    public var modeID: String
    public var cornerID: String
    public var endpoint: String
    public var slack: Double
    public var suggestedActions: [String]

    public init(
        kind: STAAnalysisKind,
        modeID: String,
        cornerID: String,
        endpoint: String,
        slack: Double,
        suggestedActions: [String] = []
    ) {
        self.kind = kind
        self.modeID = modeID
        self.cornerID = cornerID
        self.endpoint = endpoint
        self.slack = slack
        self.suggestedActions = suggestedActions
    }
}

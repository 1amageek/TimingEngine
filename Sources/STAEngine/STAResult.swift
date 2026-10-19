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
    public var inputWireDelay: Double?
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
        load: Double,
        inputWireDelay: Double? = nil
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
        self.inputWireDelay = inputWireDelay
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
    public var analysisKind: STAAnalysisKind?

    public init(
        modeID: String,
        cornerID: String,
        startpoint: String,
        endpoint: String,
        arrival: Double,
        required: Double,
        slack: Double,
        stages: [STAPathStage],
        analysisKind: STAAnalysisKind? = .setup
    ) {
        self.modeID = modeID
        self.cornerID = cornerID
        self.startpoint = startpoint
        self.endpoint = endpoint
        self.arrival = arrival
        self.required = required
        self.slack = slack
        self.stages = stages; self.analysisKind = analysisKind
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

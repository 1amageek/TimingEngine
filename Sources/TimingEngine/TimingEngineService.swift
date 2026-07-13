import Foundation
import SignalIntegrityEngine
import STAEngine

public struct TimingEngineService: Sendable {
    public let sta: any STAAnalyzing
    public let signalIntegrity: any SignalIntegrityAnalyzing
    public let foundationSTA: any STAFoundationEngine
    public let foundationSignalIntegrity: any SignalIntegrityFoundationEngine
    public let corpus: any TimingCorpusRunning
    public let qualification: any TimingQualificationEvaluating

    public init(
        sta: any STAAnalyzing = NativeSTAEngine(),
        signalIntegrity: any SignalIntegrityAnalyzing = NativeSignalIntegrityEngine(),
        foundationSTA: (any STAFoundationEngine)? = nil,
        foundationSignalIntegrity: (any SignalIntegrityFoundationEngine)? = nil,
        workspaceRoot: URL? = nil,
        corpus: any TimingCorpusRunning = LocalTimingCorpusRunner(),
        qualification: any TimingQualificationEvaluating = TimingQualificationEvaluator()
    ) {
        self.sta = sta
        self.signalIntegrity = signalIntegrity
        self.foundationSTA = foundationSTA ?? NativeSTAFoundationEngine(workspaceRoot: workspaceRoot)
        self.foundationSignalIntegrity = foundationSignalIntegrity
            ?? NativeSignalIntegrityFoundationEngine(workspaceRoot: workspaceRoot)
        self.corpus = corpus
        self.qualification = qualification
    }
}

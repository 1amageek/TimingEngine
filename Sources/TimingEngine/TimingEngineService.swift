import Foundation
import SignalIntegrityEngine
import STAEngine

public struct TimingEngineService: Sendable {
    public let sta: any STAAnalyzing
    public let signalIntegrity: any SignalIntegrityAnalyzing
    public let corpus: any TimingCorpusRunning
    public let qualification: any TimingQualificationEvaluating

    public init(
        sta: any STAAnalyzing = NativeSTAEngine(),
        signalIntegrity: any SignalIntegrityAnalyzing = NativeSignalIntegrityEngine(),
        corpus: any TimingCorpusRunning = LocalTimingCorpusRunner(),
        qualification: any TimingQualificationEvaluating = TimingQualificationEvaluator()
    ) {
        self.sta = sta
        self.signalIntegrity = signalIntegrity
        self.corpus = corpus
        self.qualification = qualification
    }
}

import Foundation
import SignalIntegrityEngine
import STAEngine
import TimingCore

public struct TimingEngineService: Sendable {
    public let sta: any STAExecuting
    public let signalIntegrity: any SignalIntegrityExecuting
    public let corpus: any TimingCorpusRunning
    public let evidenceAssessment: any TimingEvidenceEvaluating

    public init(
        sta: (any STAExecuting)? = nil,
        signalIntegrity: (any SignalIntegrityExecuting)? = nil,
        workspaceRoot: URL? = nil,
        corpus: (any TimingCorpusRunning)? = nil,
        evidenceAssessment: any TimingEvidenceEvaluating = TimingEvidenceEvaluator()
    ) {
        self.sta = sta ?? NativeSTAEngine(workspaceRoot: workspaceRoot)
        self.signalIntegrity = signalIntegrity ?? NativeSignalIntegrityEngine(workspaceRoot: workspaceRoot)
        self.corpus = corpus ?? LocalTimingCorpusRunner(
            sta: self.sta,
            signalIntegrity: self.signalIntegrity,
            reader: FileSystemTimingArtifactReader(workspaceRoot: workspaceRoot)
        )
        self.evidenceAssessment = evidenceAssessment
    }

}

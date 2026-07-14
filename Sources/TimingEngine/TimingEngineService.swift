import Foundation
import SignalIntegrityEngine
import STAEngine
import TimingCore

public struct TimingEngineService: Sendable {
    public let sta: any STAFoundationEngine
    public let signalIntegrity: any SignalIntegrityFoundationEngine
    public let corpus: any TimingCorpusRunning
    public let qualification: any TimingQualificationEvaluating

    public init(
        sta: (any STAFoundationEngine)? = nil,
        signalIntegrity: (any SignalIntegrityFoundationEngine)? = nil,
        workspaceRoot: URL? = nil,
        corpus: (any TimingCorpusRunning)? = nil,
        qualification: any TimingQualificationEvaluating = TimingQualificationEvaluator()
    ) {
        self.sta = sta ?? NativeSTAEngine(workspaceRoot: workspaceRoot)
        self.signalIntegrity = signalIntegrity ?? NativeSignalIntegrityEngine(workspaceRoot: workspaceRoot)
        self.corpus = corpus ?? LocalTimingCorpusRunner(
            sta: self.sta,
            signalIntegrity: self.signalIntegrity,
            reader: FileSystemTimingArtifactReader(workspaceRoot: workspaceRoot)
        )
        self.qualification = qualification
    }

}

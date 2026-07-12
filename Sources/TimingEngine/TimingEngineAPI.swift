import Foundation
import SignalIntegrityEngine
import STAEngine
import TimingCore
import XcircuitePackage

public enum TimingEngineAPI {
    public static let contractVersion = 1
    public static let implementationVersion = "1.1.0"

    public static let nativeCapabilities = [
        XcircuiteEngineCapability(
            engineID: "timing.sta",
            contractVersion: contractVersion,
            supportedInputFormats: [.liberty, .sdc, .spef, .json, .verilog],
            supportedOutputFormats: [.json, .sdf],
            features: ["liberty-parsing", "sdc-parsing", "timing-graph", "mmmc-setup-hold", "recovery-removal", "pulse-width", "derate-ocv", "path-groups", "clock-groups", "provenance-digests", "repair-candidates"],
            limitations: ["advanced-statistical-ocv", "process-qualified-signoff"]
        ),
        XcircuiteEngineCapability(
            engineID: "timing.signal-integrity",
            contractVersion: contractVersion,
            supportedInputFormats: [.spef, .sdc],
            supportedOutputFormats: [.json],
            features: ["coupling-capacitance", "delta-delay", "noise-ratio", "provenance-digests"],
            limitations: ["waveform-resolved-noise", "process-qualified-signoff"]
        ),
    ]

    public static func makeNativeSTA(
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil
    ) -> NativeSTAEngine {
        NativeSTAEngine(reader: reader, artifactStore: artifactStore)
    }

    public static func makeNativeSignalIntegrity(
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil
    ) -> NativeSignalIntegrityEngine {
        NativeSignalIntegrityEngine(reader: reader, artifactStore: artifactStore)
    }
}

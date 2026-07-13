@_exported import CircuiteFoundation
import Foundation
import SignalIntegrityEngine
import STAEngine
import TimingCore

public enum TimingEngineAPI {
    public static let contractVersion = 1
    public static let implementationVersion = "1.1.0"

    public static let nativeCapabilities = [
        TimingEngineCapability(
            engineID: "timing.sta",
            contractVersion: contractVersion,
            supportedInputFormats: [.liberty, .json, .verilog, sdcFormat, .spef],
            supportedOutputFormats: [.json],
            features: ["foundation-request", "liberty-parsing", "sdc-parsing", "timing-graph", "mmmc-setup-hold", "recovery-removal", "pulse-width", "derate-ocv", "path-groups", "clock-groups", "provenance-digests", "artifact-persistence", "repair-candidates"],
            limitations: ["advanced-statistical-ocv", "process-qualified-signoff"]
        ),
        TimingEngineCapability(
            engineID: "timing.signal-integrity",
            contractVersion: contractVersion,
            supportedInputFormats: [.json, .verilog, sdcFormat, .spef],
            supportedOutputFormats: [.json],
            features: ["foundation-request", "coupling-capacitance", "delta-delay", "noise-ratio", "provenance-digests", "artifact-persistence"],
            limitations: ["waveform-resolved-noise", "process-qualified-signoff"]
        ),
    ]

    public static func makeNativeSTA(
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil
    ) -> NativeSTAEngine {
        NativeSTAEngine(
            reader: reader,
            artifactStore: artifactStore,
            workspaceRoot: workspaceRoot
        )
    }

    public static func makeNativeSignalIntegrity(
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil
    ) -> NativeSignalIntegrityEngine {
        NativeSignalIntegrityEngine(
            reader: reader,
            artifactStore: artifactStore,
            workspaceRoot: workspaceRoot
        )
    }

    public static func makeFoundationSTA(
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil
    ) -> any STAFoundationEngine {
        NativeSTAEngine(
            reader: reader,
            artifactStore: artifactStore,
            workspaceRoot: workspaceRoot
        )
    }

    public static func makeFoundationSignalIntegrity(
        reader: any TimingArtifactReading = FileSystemTimingArtifactReader(),
        artifactStore: (any TimingArtifactStoring)? = nil,
        workspaceRoot: URL? = nil
    ) -> any SignalIntegrityFoundationEngine {
        NativeSignalIntegrityEngine(
            reader: reader,
            artifactStore: artifactStore,
            workspaceRoot: workspaceRoot
        )
    }

    private static let sdcFormat: ArtifactFormat = {
        do {
            return try ArtifactFormat(rawValue: "sdc")
        } catch {
            preconditionFailure("The canonical SDC artifact format is invalid.")
        }
    }()
}

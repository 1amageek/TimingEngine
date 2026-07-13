# TimingEngine Interface Contract

The canonical public shape is:

```swift
public protocol STAFoundationEngine: Engine
where Request == STAFoundationRequest, Output == STAExecutionResult {}
```

Requests carry a Foundation schema version, run ID and verified `ArtifactReference` values. Domain results conform independently to `ArtifactProducing`, `DiagnosticReporting` and `EvidenceProviding`; payloads contain domain metrics, while evidence and diagnostics remain inspectable without a universal result envelope.

There is no compatibility envelope or adapter layer. The canonical service,
corpus runner, CLI and OpenSTA process integration exchange Foundation requests
and domain results directly.

The `TimingEngine` umbrella product exposes these seams through
`TimingEngineService.sta`, `TimingEngineService.signalIntegrity`,
`TimingEngineAPI.makeNativeSTA` and `TimingEngineAPI.makeNativeSignalIntegrity`.

## Products

### TimingCore

Liberty, SDC, SPEF, SDF, provenance and canonical timing references.

### STAEngine

MMMC setup and hold analysis.

### SignalIntegrityEngine

Coupling-aware crosstalk analysis.

### TimingEngine

Umbrella API, corpus replay, reference correlation and qualification decisions.


## Error contract

- Throw only when execution cannot produce a valid Foundation result.
- Represent design findings and failed checks as typed diagnostics and a completed domain payload.
- Represent missing prerequisites or insufficient semantics as `blocked`.
- Preserve cancellation as `cancelled`.
- Do not swallow parser, process or persistence failures.

## Runtime integration

An integrating runtime must:

1. resolve project-relative references at its own workspace boundary;
2. verify input digests;
3. evaluate ToolQualification requirements;
4. invoke the injected engine protocol;
5. persist every returned artifact;
6. map diagnostics and status to FlowStageResult;
7. attach design, PDK and tool provenance;
8. leave approval and resume handling to DesignFlowKernel.

The runtime preserves the run ID, input digests, output artifact digests and
structured diagnostics while passing between flow stages.

# TimingEngine Interface Contract

## Legacy compatibility shape

```swift
public protocol DomainExecuting: Sendable {
    func execute(
        _ request: DomainRequest
    ) async throws -> XcircuiteEngineResultEnvelope<DomainPayload>
}
```

The Foundation-native public shape is:

```swift
public protocol STAFoundationEngine: Engine
where Request == STAFoundationRequest, Output == STAExecutionResult {}
```

Requests carry a Foundation schema version, run ID and verified `ArtifactReference` values. Domain results conform independently to `ArtifactProducing`, `DiagnosticReporting` and `EvidenceProviding`; payloads contain domain metrics, while evidence and diagnostics remain inspectable without a universal result envelope.

The legacy `XcircuiteEngineResultEnvelope` shape remains only at the current Xcircuite adapter boundary and is promoted into Foundation results before the Foundation-facing engine returns.

The `TimingEngine` umbrella product exposes these seams through
`TimingEngineService.foundationSTA`, `TimingEngineService.foundationSignalIntegrity`,
`TimingEngineAPI.makeFoundationSTA` and `TimingEngineAPI.makeFoundationSignalIntegrity`.

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

## Xcircuite adapter

The adapter must:

1. resolve project-relative references through XcircuitePackage;
2. verify input digests;
3. evaluate ToolQualification requirements;
4. invoke the injected engine protocol;
5. persist every returned artifact;
6. map diagnostics and status to FlowStageResult;
7. attach design, PDK and tool provenance;
8. leave approval and resume handling to DesignFlowKernel.

The adapter migration must preserve the run ID, input digests, output artifact digests and structured diagnostics when it switches from the legacy envelope to the Foundation result types.

# TimingEngine Interface Contract

## Engine protocols

```swift
public protocol STAExecuting: Engine
where Request == STARequest, Output == STAExecutionResult {}
```

Signal-integrity execution follows the same direct-conformance pattern. Requests are `Sendable`, schema-versioned values containing immutable `ArtifactReference` inputs. Results expose domain payloads and conform independently to `ArtifactProducing`, `DiagnosticReporting` and `EvidenceProviding`.

There is no compatibility envelope or runtime adapter layer. Native implementations conform to the public engine protocols directly.

## Evidence interfaces

| Interface | Role |
|---|---|
| `TimingCorpusRunning` | Replay retained timing observations |
| `TimingExternalCorrelationVerifying` | Reopen raw artifacts and reconstruct correlation |
| `TimingEvidenceEvaluating` | Produce a non-authoritative evidence assessment |
| `TimingPDKEvidenceBuilding` | Observe PDK manifest/assets under a declared workspace root |

`TimingEvidenceAssessment` is an observation report. Its derived outcome is not a production qualification or flow approval.

## Artifact access

`TimingArtifactReading` is asynchronous because artifact access may involve I/O. Filesystem and in-memory implementations verify byte count and SHA-256 before returning bytes. Production evidence validation uses ToolQualification's verified-reader protocol directly; synchronous trust paths are not part of the contract.

External correlation requires one explicit workspace root. Every retained artifact is workspace-relative and is resolved only against that root.

## Error contract

- Throw when no valid typed result or assessment can be produced.
- Emit typed diagnostics for design findings.
- Represent missing prerequisites or unsupported semantics as blocked.
- Preserve cancellation as cancelled.
- Do not swallow parsing, process, integrity or persistence errors.

## Runtime integration

An integrating runtime resolves project references, verifies digests, invokes the injected engine, persists returned artifacts and maps diagnostics to flow stage results. ToolQualification evaluates process evidence. DesignFlowKernel owns approval and resume transitions.

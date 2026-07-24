# TimingEngine Interface Contract

## Engine protocols

```swift
public protocol STAExecuting: Engine
where Request == STARequest, Output == STAExecutionResult {}
```

Signal-integrity execution follows the same direct-conformance pattern. Requests are `Sendable`, schema-versioned values containing immutable `ArtifactReference` inputs. Results expose domain payloads and conform independently to `ArtifactProducing`, `DiagnosticReporting` and `EvidenceProviding`.

There is no compatibility envelope or runtime adapter layer. Native implementations conform to the public engine protocols directly.

Callers initialize `NativeSTAEngine` or `NativeSignalIntegrityEngine` directly,
or inject protocol-conforming implementations into `TimingEngineService`.
Each native engine owns its `TimingCapability` declaration. Capability records
use `schemaVersion`; decoding rejects records from an unsupported schema.

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

## OpenSTA process boundary

`opensta-oracle-adapter` requires `--workspace-root` and a stable
`--run-id`. It creates exactly one immutable execution directory at
`.timingengine/runs/<run-id>/opensta/`, snapshots the measured executable and
all declared design, Liberty, SDC, PDK, and optional SPEF inputs, and executes
only those snapshots. Generated Tcl, stdout, stderr, and snapshot references
remain in that run directory. Reusing an existing run directory, path-unsafe
run IDs, input mutation, and executable mutation fail closed.

## Error contract

- Throw when no valid typed result or assessment can be produced.
- Emit typed diagnostics for design findings.
- Represent missing prerequisites or unsupported semantics as blocked.
- Preserve cancellation as cancelled.
- Do not swallow parsing, process, integrity or persistence errors.

## Runtime integration

An integrating runtime resolves project references, verifies digests, invokes
the injected engine, persists returned artifacts and maps diagnostics to flow
stage results. ToolQualification evaluates process evidence. DesignFlowKernel
owns approval and resume transitions.

`TimingEngineService.nativeCapabilities` aggregates native capability records
for the CLI without acting as an engine factory.

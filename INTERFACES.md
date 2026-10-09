# TimingEngine Interface Contract

## Engine protocols

```swift
public protocol STAExecuting: Engine
where Request == STARequest, Output == STAExecutionResult {}
```

Signal-integrity execution follows the same direct-conformance pattern. Requests are `Sendable`, schema-versioned values containing `TimingArtifactBinding` inputs: a location-independent `ArtifactReference` plus one execution-scoped `ArtifactAvailability`. Results retain the same exact input bindings, expose domain payloads, and conform independently to `ArtifactProducing`, `DiagnosticReporting` and `EvidenceProviding`.

There is no compatibility envelope or runtime adapter layer. Native implementations conform to the public engine protocols directly.

Native preparation and exact execution interfaces are owned by
[PreparedExecution](Sources/STAEngine/PreparedExecution/DESIGN.md).
Their source/configuration/characterization contracts and schema v4 migration are
implemented. STAExecuting remains the direct engine interface.

Callers initialize `NativeSTAEngine` or `NativeSignalIntegrityEngine` directly,
or inject protocol-conforming implementations into `TimingEngineService`.
Each native engine owns its `TimingCapability` declaration. Capability records
use `schemaVersion`; decoding rejects records from an unsupported schema.

## Evidence interfaces

Native STA requires explicit `requestedCornerIDs` and explicit supported corner
IDs on every `TimingLibraryReference`. The retained PDK manifest must validate
and match `processID` / `pdkVersion`. Each selected corner's Liberty view and
cross-view mapping must bind the supplied library's exact SHA-256 and byte count.
Each corner receives its own parsed library. `STAPayload.processSelection` retains
the admitted process/version, manifest identity, PVT corner definitions and exact
library identities; blocked results omit this selection and publish no report.
The detailed authority is [ProcessCorners](Sources/STAEngine/ProcessCorners/DESIGN.md).

`timingengine run-sta` requires `--corner`, `--process` and `--pdk-version` together
with design, library, constraints and PDK manifest paths. A missing option or
unknown/mismatched selection exits nonzero. Developers can verify the native
process/corner path using:

```bash
python3 -c 'import subprocess; subprocess.run(["swift", "test", "--build-path", ".build", "--filter", "STAProcessCornerTests|TimingCLIProcessTests"], timeout=300, check=True)'
```

| Interface | Role |
|---|---|
| `TimingCorpusRunning` | Replay retained timing observations |
| `TimingExternalCorrelationVerifying` | Reopen raw artifacts and reconstruct correlation |
| `TimingEvidenceEvaluating` | Produce a non-authoritative evidence assessment |
| `TimingPDKEvidenceBuilding` | Observe PDK manifest/assets under a declared workspace root |

`TimingEvidenceAssessment` is an observation report. Its derived outcome is not a production qualification or flow approval.

## Artifact access

`TimingArtifactReading` is asynchronous because artifact access may involve I/O. The filesystem implementation opens the declared availability through `ArtifactRootCapability`, consumes bounded pages, verifies the terminal receipt, and propagates session/root close failures. The in-memory implementation verifies byte count and SHA-256 for the same content identity. Synchronous trust paths are not part of the contract.

External correlation requires one explicit workspace root. Every retained artifact uses a workspace-root `ArtifactAvailability` and is resolved only through that root capability. ToolQualification consumes retained raw evidence through the host integration boundary; TimingCore does not depend on ToolQualification.

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

## Prepared native STA

`NativeSTAEngine` conforms directly to `STAExecutionPreparing` and
`STAPreparedExecuting`. Call `prepare(request, resources:)`, compare the actual
prepared observations, then `execute(prepared)`. `STAExecutionResources` supplies
one verified reader, optional `TimingInspectedLibertySources`, owned grammar limits
and accounting, and independent native transform/scenario ceilings. Prepared owner
construction is internal and non-Codable. Execution never reopens artifact paths.

`STARequest`, `STAExecutionResult` and report payload use schema v4. The request
configuration digest is only an expectation; effective provenance is produced from
resolved settings. `STACharacterizationPolicy.declaredCornerSelection` retains raw
source facts and exact declared selection. `requireObservedConditions` requires
one explicit `STACharacterizationBinding` per corner and exact voltage/temperature
match. Numeric process remains unmapped. Supplied randomSeed is unsupported.

The CLI accepts `--condition`, `--max-paths` and
`--expected-configuration-digest`; condition selects the observed policy. Native
actual config/characterization records are present in emitted v4 results. Old
schemas are rejected by the canonical reader, including external correlation.

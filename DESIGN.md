# TimingEngine Design

## Purpose and Scope

TimingEngine owns canonical timing data, MMMC static timing analysis, signal-integrity analysis, retained observations and independent-oracle correlation.

Parent: [LSI](../DESIGN.md). Direct affected module children are indexed below;
each child owns its implementation and verification contract.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [LSI](../DESIGN.md) | parent | Domain versus host/trust authority | Platform composition | Timing evidence is not approval |
| [TimingCore](Sources/TimingCore/DESIGN.md) | child | Canonical values and owned Liberty codec | Independent domain floor | No PDK reverse dependency |
| [STAEngine](Sources/STAEngine/DESIGN.md) | child | Exact native STA and preparation | Scenario execution | Prepared interfaces and v4 schema |
| [SignalIntegrityEngine](Sources/SignalIntegrityEngine/DESIGN.md) | child | Coupling analysis | Separate domain result | STA prepared proof does not generalize |
| [TimingPDKProfileInspection](Sources/TimingPDKProfileInspection/DESIGN.md) | child | Owned Liberty/profile adapter | Optional product boundary | Optional product |

## Responsibilities and Boundaries

Own domain meaning and execution; host owns persistence and flow/trust policy.

## Architecture

```mermaid
flowchart LR
    Inputs["Liberty / SDC / SPEF / design IR"] --> Timing["TimingEngine\nanalysis + observations"]
    Timing --> Evidence["ArtifactReference + provenance + diagnostics"]
    Evidence --> Qualification["ToolQualification\nprocess evidence validation"]
    Qualification --> Policy["DesignFlowKernel\npolicy + approval"]
    Policy --> Runtime["Xcircuite\npersistence + resume"]
```

TimingEngine can report that a retained corpus or oracle comparison agrees for a declared scope. It does not decide that a tool is production-qualified and does not approve a release. `ToolQualification` validates raw process evidence. `DesignFlowKernel` applies flow policy and approval. `Xcircuite` owns concrete workspace and run persistence.

## Contracts and Invariants

### Trust model

The following states are independent:

| State | Owner | Meaning |
|---|---|---|
| Execution completed | TimingEngine backend | A typed analysis result was produced |
| Corpus replay valid | TimingEngine | Retained expected observations were reproduced |
| Oracle correlation passed | TimingEngine verifier | Raw native and oracle outputs agree within a declared tolerance |
| Process evidence accepted | ToolQualification | Raw evidence was reconstructed and validated for a process scope |
| Flow approved | DesignFlowKernel | Policy and human approval permit promotion |

Persisted decision fields are not trusted. `TimingEvidenceAssessment.outcome` is derived from findings. External correlation is accepted only after workspace containment, digest, byte-count, producer, invocation, input and metric reconstruction checks.

The external oracle consumer uses the public `STAExecutionResult` decoder as its
schema authority. It accepts the current STA schema and rejects obsolete or
unsupported schemas as `external_oracle_output_invalid`; it does not maintain a
separate version literal. Run identity is checked after canonical decoding.
The real process tests in [CorpusTests](Tests/TimingEngineTests/CorpusTests.swift)
verify current-schema consumption, run mismatch, and v1/v2 rejection through
retained JSON bytes emitted by `/bin/cat`.

The OpenSTA execution boundary does not trust a caller-declared tool identity. The adapter resolves the executable, validates that it is a regular executable file, measures its SHA-256, and verifies its reported version. It then creates one immutable, create-only run workspace under the caller's declared workspace root, copies the executable and all input artifacts into that workspace, and invokes only those snapshots. Executable and input bytes are verified again after analysis. The observed digest is stored as the supporting tool producer build so ToolQualification can bind the result to its independently verified `binaryDigest`.

The checked-in Sky130A directory is an input manifest, not a foundry corpus. Its required Liberty file is deliberately external; absence or digest drift is reported as incomplete PDK evidence. No checked-in decision artifact may convert that missing input into qualification.

## Artifact boundary

Correlation artifacts keep location-independent `ArtifactReference` identity separate from workspace-root `ArtifactAvailability`. The caller supplies one explicit workspace root, and bounded `ArtifactRootCapability` sessions reject root mismatch, symlink traversal, digest/size drift, budget exhaustion, and close failure. OpenSTA execution artifacts are retained beneath `.timingengine/runs/<run-id>/opensta/`; an existing run workspace is never replaced, and run IDs must be stable path-safe identities rather than sanitized aliases. Native and oracle outputs must retain the same input artifact identities and an independent oracle executable identity. A declared executable version without a matching measured digest is not production evidence.

## Dependency direction

[TimingCore](Sources/TimingCore/DESIGN.md), through its native
[LibertyCodec](Sources/TimingCore/LibertyCodec/DESIGN.md) component, owns source-preserving strict Liberty
characterization and checked load/slew evaluation consumed by CTS. Ordinary STA
parsing cannot establish that strict source-admission contract.

[TimingCore cap-load reduction](Sources/TimingCore/ParasiticReduction/DESIGN.md)
owns explicit equipotential approximation over preserved source inventory. Native
STA and [SignalIntegrityEngine](Sources/SignalIntegrityEngine/DESIGN.md) retain its
loss evidence. D_NET inventory is not an effective load. Native algorithm identity
3.0.0 and request/result v4 prevent old result-scope reuse; distributed post-layout
signoff remains outside this approximate cap-load scope.

Native STA process/corner intake is owned by
[STAEngine](Sources/STAEngine/DESIGN.md) and its
[ProcessCorners component](Sources/STAEngine/ProcessCorners/DESIGN.md).
Every completed native STA report retains the validated process identity and
exact PVT/corner-to-Liberty selection. Input bindings preserve materialization;
the selection preserves location-independent identity. Missing or contradictory
process/corner inputs block before report publication. No default corner is
invented and libraries from different corners are never merged for analysis.

Optional [TimingPDKProfileInspection](Sources/TimingPDKProfileInspection/DESIGN.md)
is a direct module child and owns the Liberty/profile adapter and retained grammar
catalog. TimingCore stays independent of PDKKit. STAEngine indexes its
prepared handoff. Both connections are implemented.

TimingEngine depends on the portable `CircuiteFoundation` contracts and opts into Foundation, Crypto, and FileSystem products only in targets that perform serialization, digesting, or local access. It does not import Xcircuite or circuit-studio. ToolQualification remains a downstream trust consumer and is not a dependency of TimingCore.

## Non-responsibilities

- Parasitic extraction
- Placement or routing mutation
- Tool self-qualification
- Flow approval, waiver, release or resume policy
- Concrete `.xcircuite` storage

The scalar correlation analyzer consumes the same published cap-load reduction contract through TimingParasiticReducing and identifies the changed load semantics as `timing.reference.scalar-v2`. Its numerical correlation remains local model evidence, not distributed RC or process-qualified signoff.

## Exact PDK Identity Dependency Adoption

[Package.swift](Package.swift) owns the exact revisions consumed by this package.
This adoption consumes the updated PDKCore product directly or transitively.
[Checked PDK identity values](../PDKKit/Sources/PDKCore/Identity/DESIGN.md)
and their immutable schema-2 representation remain owned by the lower contract.
Manifest discovery/exact loading remains owned by
[PDKDiscovery](../PDKKit/Sources/PDKDiscovery/ManifestLoading/DESIGN.md).
Transitive revisions must agree with the composing Xcircuite graph without overrides.
This dependency change preserves this package's domain implementation; lower
behavioral evidence and host identity/provenance tests establish the consumed
contract, not process qualification or unexecuted domain test coverage.

## Verification and Change Impact

The [CI workflow](.github/workflows/sky130A-qualification.yml) consumes the
[CoreSpice host deployment contract](../CoreSpice/DESIGN.md#responsibilities-and-boundaries)
for its runner and compiler selection. Setup verifies the host OS and architecture,
the official installer signature, and the selected release compiler before the
existing verification steps. Configuration alone is not executed CI or process
qualification evidence.

TimingCore and STAEngine own their affected behavioral tests and new prepared-path
completion conditions. The optional adapter owns independent real-admission tests;
Xcircuite owns cumulative normal-graph/CLI/resume integration. Existing codec and
strict corner proof is reused until its assumptions change. Prepared interfaces, optional product and v4 schema retain actual execution observations;
native behavioral scope remains distinct from qualification.

## Initial Source Context Release Candidate

This isolated candidate starts at public TimingEngine 1e16c86 and composes the
existing TimingCore and STAEngine source contracts through 2fb83f7 with the
1790ec7 initial-context change. The exact file/blob selection is retained outside
the package by the release preparer. That composition passed the selected native
development qualification and one comprehensive source review. The current release
candidate changes only the dependency admission below; canonical public-graph
build and consumer evidence are required before its publication.

The package retains existing public products. TimingCore/STAEngine request/result
schema 4 and initial source-context record version 1 keep their own codec and
authority contracts; older results gain no new source authority.
[STAEngine](Sources/STAEngine/DESIGN.md) owns preparation and execution, and
[SourceFamilies](Sources/STAEngine/NativeExecution/ConservativeCoupling/SourceFamilies/DESIGN.md)
owns the before-response normalized family projection.
[ScalarReference](Sources/TimingEngine/ScalarReference/DESIGN.md) is composed because
its existing sequential and typed-constraint consumers must agree with TimingCore.
It cannot promote source-defined sequential/alias/exception cases into its scalar
profile. SI behavior remains the public-base implementation. Oracle execution consumes
the bounded-process compatibility below; the CLI composes the strict request
transport below while its ordinary file route remains unchanged.
The exact consumed Logic floor consists of portable Boolean/value and
identity/provenance contracts; no Logic host parser or serialization symbol is
consumed. Existing unused serialization imports are omitted from this candidate.

No descriptor-storage or analytic-causal-tube implementation is composed. Physical
rails, time and voltage laws, actual-cell electrical behavior, physical root joins,
flow approval, and process/release qualification remain external. Only primary-port
source entries may be considered independent physical boundaries; prescribed cell
outputs remain model assumptions.

Publication requires a coherent public exact dependency graph, bounded native
build and the initial-context/producer tests on this composed tree. Old receipts
remain evidence only for their exact source and dependency premises. Native results
do not grant new WASM/Embedded execution scope.

### Owned Code Publication License

The human owner explicitly authorized MIT publication of TimingEngine-owned code
on 2026-10-19. [LICENSE](LICENSE) records that grant;
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) excludes third-party dependencies
and external PDK/model assets from relicensing. Existing qualification input bytes
remain unchanged. This license decision changes no numerical or source authority.

### Exact Public Dependency Admission

The public release floor is LogicDesign 4d3e0649, PDKKit 1050fef9,
CircuiteFoundation 5f132c58, SignoffToolSupport e15ea6cd and ToolQualification
601ff593. PDKKit pins public mask a1104f11 and CoreSpice cfcadac5; that CoreSpice
pins public swift-osdi 1.2.0. These exact prerequisite commits have been published.

The prior development evidence remains bound to PDKKit 9f54fd14 and CoreSpice
bb754369 with explicit Git availability mirrors. It is not evidence for this
public graph. This candidate requires a fresh canonical URL resolution without
mirrors, path dependencies or edited checkouts, followed by the same bounded
native build and 134 selected source/context, API/CLI, process and Liberty tests.
All production and test blobs remain exact to reviewed composition 4c8a4fc;
only this design record and the PDKKit manifest pin change. Existing products,
symlinks, fixture identities, numerical gates and resource limits remain unchanged.
The generated exact public lock and workspace state are retained with the new
qualification evidence. A delta-only review checks this dependency admission;
no previous development receipt is relabeled as public evidence.

The selected native Swift 6.4 release compiler is the host default; its actual
path, version, execution limits and dependency/source bindings are recorded before
the bounded build. No root-finding, physical voltage law, causal tube or full
model/process timing guarantee follows from this source-context qualification.

### Bounded External Process Dependency Compatibility

The public SignoffToolSupport process contract requires finite caller-selected
combined-output and cleanup limits. The public-base oracle callers cannot compile
against that contract. This candidate therefore composes the existing process
consumer migration from 7ed4695, without changing numerical/source-context bodies.
[OpenSTAOracleAdapter](Sources/OpenSTAOracleAdapter/DESIGN.md) owns executable CLI
cleanup; [TimingEngine](Sources/TimingEngine/DESIGN.md) owns the public external
oracle request schema-3 and same-cause/raw-Data/cleanup-handle handoff. Original
source-context, scalar and native STA contracts remain unchanged. This is required
dependency compatibility, not a new external oracle or qualification authority.

### Strict Request CLI Consumer Composition

The existing conservative API/CLI saved-payload and fresh-preparation test requires
its original schema-4 request transport. This candidate composes the original
88c2c2e endpoint, shared helper visibility, fixtures and refusal tests as one
[TimingCLI](Sources/TimingCLI/DESIGN.md) contract. It preserves finite transport,
source work/storage/deadline and native limits, and validates with the same
Prepared owner before storage. It neither drops that actual consumer nor changes
the source/context/numerical model. Ordinary numeric analysis/derate extensions
from other commits are not needed by this endpoint and are not composed.

The unchanged public-base SI implementation keeps its exact public-base
ExecutionContractTests blob. Two later SI-only fixture substitutions require the
non-composed SI semantic extension and therefore are not selected. Every original
test remains present; no new SI behavior or assertion relaxation is introduced.

The strict-request process tests retain the complete original shared executable
helper from 88c2c2e (the drain-before-wait change originates in 19a544f). It drains
all stdout before waiting for termination and sends unused stderr to the original
null sink. This prevents pipe-capacity deadlock without truncating JSON or changing
the tested CLI/numerical behavior. The outer verification wrapper owns bounded
timeout cleanup of observed candidate descendants, including separate process groups.

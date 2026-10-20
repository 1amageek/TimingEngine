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

### Historical Exact Public Dependency Admission

The dependency floor of that qualification was LogicDesign 5e1d3eec, PDKKit f59dfd1d,
CircuiteFoundation 5f132c58, SignoffToolSupport e15ea6cd and ToolQualification
601ff593. PDKKit pins public mask 67410f83 and CoreSpice cfcadac5; that CoreSpice
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


## Historical STA Consumer Source-Floor Alignment

That candidate starts at public `0d7179e39f242b6fe7b3d0e1929485697d2076a3`.
All production/test/resource bytes, modes and symlink targets remain exact to that
public source, including prepared STA, initial source contexts and contained
immutable artifact publication. Only root documentation, the following two exact
selectors and the freshly resolved lock change:

| Dependency | Exact public revision | Required lower contract |
|---|---|---|
| LogicDesign | `5e1d3eec838a0add91c617413682d186a5182335` | Published validated actual-cell IR source floor; existing STA value/identity use remains unchanged |
| PDKKit | `f59dfd1dbdd20545ddf97e6a0ab9a956ad7ca809` | Canonical technology metadata admission aligned with its public mask source floor |

CF, Signoff, ToolQualification, CoreSpice and SDK selectors retain the existing
public dependency premises. Fresh resolution uses canonical HTTPS without local
paths, edits or mirrors. Original public `0d7179` source/context, 134-case and
artifact-store qualification receipts retain their original input/source scopes;
they are not relabeled as execution on the new dependency graph.

The affected consuming profile executes the six original
`STAPreparedExecutionTests`, then the unchanged four-source public consumer and
six input fixtures: actual prepare/context/execution, same-owner source validation,
resource/cancellation/refund, typed artifact binding, fresh reader and a separate
cold process comparing complete API/CLI payloads. The candidate CLI uses its actual
new compiled production closure. Client linking has no test/package privilege and
uses only public API. Full old suites are not repeated when their owned source and
premises are unchanged. This is Native dependency compatibility, not a new source
family existence, all-history physical response, process or release guarantee.
The public-base SI implementation remains unchanged; no private SI schema-4 source
or equivalence claim is introduced.


## Prior Native Flow Dependency Alignment

This pin-only successor starts at public TimingEngine
`77255cdd2e89d94876775baf328e1647d96451ec`. Its production, test and resource
bytes, file modes, symlink targets, products and licenses remain unchanged.
PDKKit is pinned to published `a538326cec683bbd41a971c123d817e6093233e3`,
whose unchanged PDK APIs now select public CoreSpice
`40eefa8efe9960def7d7151298e96f898cbebab2`. Other direct selectors are unchanged.
The tracked lock is regenerated from canonical HTTPS with no mirrors, paths or
edited checkouts. This reconciles exact revisions for consuming Physical flows;
it adds no Timing API, numerical algorithm or source-family guarantee.

Qualification executes the six original prepared-admission and prepared-behavior
tests in `STAPreparedExecutionTests` on that actual graph, including immutable
execution, corner/source identity, strict budgets, cancellation and schema reading.
Earlier full suites and API/CLI cold-persistence receipts retain their original
source and dependency scope and are not reported as rerun on this successor.


## Prior Cancellation Dependency Alignment

This pin-only successor starts at public TimingEngine `0177d7da87bfe824f79e8dbce19ffcc00a65f70b`.
All production/test/resource bytes, modes, products and license boundaries remain
unchanged. The following exact published selectors reconcile the same Core graph:

| Dependency | Exact revision |
|---|---|
| PDKKit | `d27217e8312c072f4fde731d722e48f3040d5a5b` |

The transitive CoreSpice revision is `5fa29e8accb1ff9de0d1e5f8bc9efe128accf0b7`. Its only
production change from `40eefa8e` checks per-call cancellation after the first
Native voltage-observation reservation, before metadata reservation. It changes
no public API, parser, STA, PDK or Logic semantics. PDK source inspection uses
`SPICEParser.parseProfile`; CoreSpiceIO has no dependency on the CoreSpice target
that owns Native Flow. Timing uses its own STA/PDK products, and Logic required
STA and replay use NativeSTAEngine. These consumer paths cannot call the changed
Native Flow observation assembly.

Fresh canonical HTTPS resolution and exact source preservation establish this
mechanical compatibility step without paths, mirrors or edited dependencies.
Existing consumer runtime receipts retain their original graph scope; no tests
or builds are reported as rerun here. CoreSpice owns the demonstrated first-
reservation cancellation red/green and finding-only recheck. The final Physical
consumer compile/runtime owns integration on the reconciled graph, not these
pin-only publications. No new physical/history/process or release guarantee is
granted. The existing tracked lock is regenerated from that actual public graph.


## Historical Source Containment Dependency Alignment

This pin-only successor starts at public TimingEngine `d6d0bec0ee5b97a25687ad0db02e127b6d3a9df0`.
All production/test/resource bytes, modes, products and license boundaries remain
unchanged. Exact published selectors are:

| Dependency | Exact revision |
|---|---|
| PDKKit | `2c35305fd943174b98009368cf0481f3b308718f` |

The transitive CoreSpice revision is `70ebb46d96edf58a173fccc3f76ccb163076238f`. Its only
production change from `5fa29e8a` accepts identical valid finite source-enclosure
endpoints before applying the existing directed containment test. No public API,
parser, PDK, STA or Logic value contract changes. PDK uses
`CoreSpiceIO.SPICEParser.parseProfile`; CoreSpiceIO does not depend on the target
owning Native Flow. Timing uses STA/PDK products, and Logic required STA and
replay use NativeSTAEngine. None of these paths invokes the changed Flow assembly.

Fresh canonical HTTPS resolution and exact source preservation qualify this
mechanical pin reconciliation without paths, mirrors or edited dependencies.
Existing consumer runtime receipts retain their original graph scope; builds and
tests are not rerun or claimed on this successor graph. CoreSpice owns the actual
identical-enclosure red/green and scoped review. Final Physical consumer execution
owns integration. This grants no new full-history, physical-root or release
guarantee. The existing tracked lock is regenerated from the actual public graph.


## Current Simulation-Parameter Dependency Alignment

This pin-only successor starts at public `bc88162612c089c66d1a4022230d23958a7738c0`.
All production, test, resource, product, mode and license contracts are retained.

| Dependency | Published revision |
|---|---|
| PDKKit | `1bd686f8a4b47a90ef136b5f7dbcca7390971b8e` |

The resolved CoreSpice source is `82eb35e8bc57402880db3529c8a1dc2045349d87`.
CircuiteFoundation remains `5f132c58209123433e0e479e1ea61096e46061ba`;
swift-osdi remains stable `1.2.0`. PDK controlled-decoder source from public
`ef26637aad6507bd4544d6958486bdcae0fba147` is retained. CoreSpice owns its
simulation-parameter correction and focused qualification. Prior consumer runtime
receipts retain their original graph scope and are reused only for unchanged
source and assumptions. This step records canonical public dependency resolution;
no numerical build or test is claimed as rerun. The final Physical consumer owns
compiled/runtime integration on this graph. No stable tag or broader physical,
interval or history qualification is granted. The tracked lock records this graph.

# Prepared STA Execution

## Purpose and Scope

Status: implemented. Parent: [STAEngine](../DESIGN.md). No children.
Own immutable native STA preparation, effective configuration identity and exact
handoff to scenario execution. Preserve strict process/corner/source rules.

## Responsibilities and Boundaries

ProcessCorners owns manifest/source joins. TimingCore owns grammar, graph,
constraints and numerical values. This component composes actual outputs and
settings before analysis. PDK owns expectation/matching; host owns availability,
DB/ledger and qualification policy. NativeSTAEngine still conforms directly to
STAExecuting; no factory or compatibility envelope is introduced.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Module](../DESIGN.md) | parent | Native engine/report behavior | Same scenario algorithm | Immutable checked owner and v4 observations |
| [ProcessCorners](../ProcessCorners/DESIGN.md) | depends on | Exact per-corner library and selection | Strict join | No merged library or PVT interpolation |
| [LibertyCodec](../../TimingCore/LibertyCodec/DESIGN.md) | depends on | Owned real library/raw conditions | Shared grammar | Numeric process is not named-process proof |
| [Inspection](../../TimingPDKProfileInspection/DESIGN.md) | optional depends on | Retained inspected catalog | Parse once through analysis | No reverse TimingCore/PDKKit dependency |
| [SequentialExecution](../NativeExecution/PathAnalysis/SequentialExecution/DESIGN.md) | depends on | Compile exact source roles | Independent required inventory | Compilation alone is not timed execution |
| [Host](../../../../Xcircuite/Sources/Xcircuite/ProfileExecution/DESIGN.md) | used by | Actual prepared input/config observations | Compare before execution | Caller digest is only an expectation |

## Architecture

```text
exact readers/catalog -> process join + design/SDC/optional SPEF intake
 -> effective scenarios/characterization/config -> PreparedSTAExecution
 -> host PDK match -> same owner scenario analysis -> retained result
```

## Contracts and Invariants

Current facts: STATimingProcessInputs checks exact manifest/source joins and reuses
retained owned Liberty grammar or parses verified bytes through the same codec.
STARequest.configurationDigest is an optional expected identity. References:
[loader](../ProcessCorners/STATimingProcessInputs.swift), [request](../STARequest.swift),
[engine](../NativeSTAEngine.swift).

ST-01: Verify actual design, SDC, optional SPEF and manifest inputs. Profile mode
uses the exact inspected catalog; ordinary mode uses the same owned codec on
verified bytes. Retain complete input identity, parser/policy identities, actual
libraries and declared per-corner PVT. Corner libraries stay separate. Execute
never reopens input availability or replaces a prepared library.

ST-02: Effective config includes actual resolved modes/corners/scenarios, analysis
kinds, maxPaths, variation/derates, post-layout requirement, global input slew and
default-rule versions, characterization policy/bindings, algorithm/reduction
identities and any effective seed/semantic limit. Hash actual resolved values in
versioned domain-separated canonical framing. Caller configurationDigest becomes
an optional expected digest and must match, never supplying actual provenance.
Resolve empty requested modes against actual constraints first. Unknown or ignored
settings cannot claim application. Source identity is separate; run ID, timestamps,
availability and source-intake ceilings are excluded. Effective output/analysis
limits remain inside config identity. Preserve precedence and reject nonfinite/overflow.
The initial deterministic native lane does not consume randomSeed; a supplied seed
is typed unsupported rather than hashed and reported as effective. Only settings
actually used by the scenario algorithm may enter an applied-configuration record.

ST-03: STACharacterizationPolicy has `declaredCornerSelection` and
`requireObservedConditions`. The first proves exact declared source selection and
retains raw metadata without claiming a selected observed characterization group.
The second requires explicit condition-name bindings per corner, resolves each
against that exact library and compares observed voltage/temperature exactly with
the selected nominal values. Missing/duplicate/incomplete groups fail. Preserve
numeric process as unmapped metadata; an additional explicit numeric-value demand
requires actual equality, but neither case manufactures named-process evidence.
No first group or assumed default is selected. Unselected groups are not operating
points. STA has no solved circuit supply/temperature trace and must not publish one.
Neither case qualifies models or provides complete named-process sourcePVT coverage.

ST-04: PreparedSTAExecution is a Sendable internal-constructor, non-Codable owner
of real libraries/catalog, graph, resolved constraints, parasitic reduction,
scenarios, identities and observations. The same owner supplies analysis and output
claims. Mutable workspace is per execution, not shared with immutable libraries.

Protocols implemented directly by NativeSTAEngine:

```swift
public protocol STAExecutionPreparing: Sendable {
    func prepare(_ request: STARequest, resources: STAExecutionResources)
        async throws(STAPreparationError) -> PreparedSTAExecution
}
public protocol STAPreparedExecuting: Sendable {
    func execute(_ prepared: PreparedSTAExecution)
        async throws(STAExecutionError) -> STAExecutionResult
}
```

STAExecutionResources supplies verified readers, optional inspected catalog,
source/accounting policies and finite scenario/execution limits, including maximumPathStates and maximumPathWorkUnits.
Temporary zero-symbol constant-function LogicBit slots plus live route records share
the maximumPathStates admission bound; source lookup and DAG work use the cumulative
maximumPathWorkUnits ceiling. This does not establish allocator/RSS accounting.
These applied route limits enter effective configuration encoding v4 / STA 3.4.0. It grants
availability, not semantic identity. Ordinary STAExecuting.execute(request)
delegates prepare/execute; profile callers use the explicit prepared boundary
to match before execution. Protocol implementations delegate checked owner
construction; no public unchecked prepared initializer is provided.

## Runtime Flows

Verify/intake -> strict process join -> resolve config -> final cancellation check
-> prepared owner -> caller profile match -> actual scenarios -> domain-valid
completed output -> exact report. Failure publishes no completed report.

## State, Ownership, and Lifecycle

Prepared storage is immutable; each run owns workspace, cancellation and report
capacity. Catalog/codec receipts live to last prepared/result copy. Raw library
extraction does not transfer managed lifetime. Stage accounting owns new non-PDK
inputs and scenario materialization, not a reopened admission counter. Reader
sessions await close. Concurrency never weakens storage/isolation by target.

## Failure, Concurrency, and Constraints

Typed failures preserve source/process/corner/resource/cancellation causes and
distinguish expected config mismatch, missing/unsupported characterization and
unsupported bounded transform. Conservative native-backend faults retain their
`NativeSTAConservativeCouplingError.nativeBackendFailure` cause through the
prepared API's existing `STAExecutionError.underlying` boundary. The request API
emits a failed result with `timing.sta.native_backend_failed`; native capability
refusal emits a blocked unsupported result. Neither is a crossing-certificate
refusal. Capacity, cancellation and deadline causes retain their existing paths.
A bounded replay mismatch retains every exact equality/rejection condition.
Only after failure, diagnostics name at most twelve compared components and the
first differing element per component. Source detail selects only the first
mismatching source-evidence section/element; equal evidence is not expanded.
The first conservative-wire mismatch includes its bounded query identity and
fixed source/delay/slew/error/derivative bit patterns. Diagnostic output is bounded
to 4,100 UTF-8 bytes, with names individually truncated before concatenation.
Diagnostic scans charge the retained source accountant and check its existing
cancellation/deadline; exhaustion remains a typed resource failure. No artifact,
public schema, mathematical acceptance criterion or algorithm identity changes.
Liberty codec bounds cover Liberty only. Other
design/SDC/SPEF/graph/analysis transforms have explicit budgets or refuse before
an unbounded operation; they cannot inherit the codec's proof. Native macOS
evidence establishes no WASM/Embedded or process qualification.

## Verification and Change Impact

STAPreparedExecutionTests uses real distinct-corner delays. Prove effective
variation/mode/maxPaths/slew/policy identity changes, wrong caller digest, execution
after path mutation, raw numeric process/partial metadata, explicit group selection,
missing/wrong voltage/temperature, independent concurrent runs and budget/cancellation.
Reuse unchanged strict STAProcessCornerTests and codec evidence. Implement request/
result/report schema v4 with actual input/config and characterization records;
migrate CLI, corpus, external correlation readers and host together. Current schema is v4. Older schemas fail explicitly; external producers
can report only their actually implemented scope.

## Implemented Read Contract and Limits

`PreparedSTAExecution` exposes immutable request/input references, a domain-framed
`executionInputIdentity`, `effectiveConfiguration`/`configurationDigest`, exact
`processSelection`, raw/selected characterization, graph-selected `libraryConsumption`
and optional `inspectedSources`.
The latter retains the actual admitted contextual graph; source contexts are never
copied from a consumption expectation. Execution uses its retained libraries and
parsed inputs after source paths change. Each invocation allocates new scenario
workspace and never shares mutable algorithm state.

`STAExecutionLimits` independently caps input bytes before native transforms,
design elements, scenario fan-out and requested paths. `STALibertyResources` caps
actual grammar work/live+temporary payload bytes and checks one monotonic deadline.
These are distinct scope contracts: transform ceilings are not allocator/RSS
accounting and do not inherit the strict Liberty storage guarantee. Unavailable
strict transform accounting is explicitly refused when requested. Intake limits
are excluded from effective config; the requested semantic path output limit is
included. The native lane is deterministic and rejects a supplied randomSeed.

The effective config decoder recomputes the digest from the retained values and
rejects tampering. Default mode is resolved before hashing. Global input slew and
output load are taken from parsed constraints. Source IDs and materialization paths
are outside configuration identity. Report/result v4 contains the actual effective
configuration and raw/selected observations; external engines omit records outside
their implemented scope.

Behavioral owners:
[STAPreparedExecutionTests](../../../Tests/NativePreparedProof/Tests/STAPreparedExecutionTests)
and unchanged strict process-corner regression. Tests are ordinary SwiftPM targets;
[the independent proof package](../../../Tests/NativePreparedProof/Package.swift)
selects those same sources without compiling unrelated legacy test products.

Native 3.5/configuration v5 retains optional explicit STADistributedRCOptions and full immutable v3 SPEF source topology alongside the legacy load projection. Every selected corner uses its retained source thresholds and cell loads. All effective options enter configuration identity; nil preserves the explicitly approximate legacy lane. [DistributedRC](../NativeExecution/DistributedRC/DESIGN.md) owns numerical admission.

Native3.6/configurationv6 retains actual per-mode primary clock source facts (waveform, rise/fall transitions, uncertainty, propagated selection) in effective identity. Clock source bytes and exact corners remain separately bound by immutable preparation; explicit propagation is never inferred from a SPEF artifact.

Configuration v6 also binds the candidate-derived exact mode/corner/root/FF receiver scope. The owner retains the original source accountant so cooperative deadline/cancellation checks continue through clock/data execution. Request-owned logical state admission and numerical step/work scopes are defined by NativeExecution; no caller source budget is reset.

## Strict Source Evidence Extension

Status: supported native opt-in implementation and behavioral verification are complete.
Verification covers 175 affected native test methods and the digest-checked actual
Sky130 sequential helper. Production, post-route integration and process
qualification remain separate completion scopes.

### Source check applicability and pulse inputs

The native pulse extension uses the current effective configuration v9, algorithm
3.9.0 and source evidence v3. Ordinary requested-kind and scalar-summary compatibility is
preserved; source-qualified applicability never comes from that scalar summary.
The prepared inventory includes every positioned pulse law on every mapped pin,
including separate high/low laws and asynchronous control pins. Complete owned
source absence produces an explicit check-applicability role; an omitted or
unknown source fact does not establish non-applicability. Requested kinds may
remain setup/hold/recovery/removal/pulseWidth in one preparation. Upper consumers
use validated public check status and do not infer a smaller kind list or prepare
twice to discover it.

`STAControlPulseSource` is an explicit operating input with modeID, sourcePort,
referenceClock, period, risePhase, fallPhase, riseTransition and fallTransition.
Its exact values enter STARequest and effective configuration. Its named primary
input, mode and reference clock must resolve exactly; period must match that
reference clock. Phases refer to the common period origin, not an inferred input
delay. Existing input-delay bounds, when present, must contain the declared
source threshold crossing. Duplicate or foreign sources, contradictory delays,
nonfinite/overlapping waves and missing source conditions fail explicitly.
This is a conditional input, not measured waveform or qualification evidence.
Receiver values are produced through the actual candidate RC and admitted
source buffer/inverter path; caller receiver values cannot bypass that path.
`STARequest.requireStrictSourceEvidence` is an explicit opt-in. Its resolved value,
the source-evidence contract version and effective evidence limits enter the
effective configuration identity and retained report. Ordinary STA keeps its
existing extrapolation behavior. An absent/false policy or legacy report never
establishes strict complete source consumption.

Preparation derives the required role inventory independently from the exact
design, selected per-corner owned Liberty, resolved mode constraints and requested
checks. It retains this inventory and the source-qualified numerical/functional
owners through execution. Inventory covers each connected mapped instance's
propagation, sequential launch, data/capture, clock and asynchronous control roles;
physical literal outputs and source-declared nontiming roles are explicit facts.
Unconnected or unrequested roles retain their reason rather than disappearing.
Inventory is not inferred from selected critical paths or caller-supplied mappings.
`STALibraryConsumption` remains an intake inventory, not a numerical evaluation
receipt. Source-local arc/check/table identities are owned by LibertyCodec;
preparation binds them to the exact corner's library ArtifactReference.

```text
exact inputs -> immutable source-qualified role inventory
    -> all scenario evaluations and role dispositions
    -> complete source evidence -> maxPaths-limited report views
verified saved inputs -> new prepared owner -> retained evidence validation
```

Strict execution requires complete role dispositions and a checked actual sample
for every performed numerical lookup, including FF launch and capture/control
checks outside displayed path stages. Static binary, exact exclusion, unrequested
and unconnected coverage are nonnumerical and distinct from unknown coverage.
Unknown, unsupported or missing required source/evaluation coverage cannot publish
a completed strict report. Numerical samples and role outcomes are owned by
[PathAnalysis](../NativeExecution/PathAnalysis/DESIGN.md#complete-source-consumption-and-strict-samples).

Saved evidence is compared with an independently reconstructed prepared inventory
and exact input/configuration identities through a protocol requirement directly
implemented by NativeSTAEngine. A payload's own inventory, completeness flag or
recomputed digest is insufficient. Canonical decoding checks local structure,
finite numbers and references; source-complete acceptance additionally requires
the prepared comparison and source-bound sample validation. Missing roles/samples,
duplicate or foreign identities and stale source/candidate/configuration evidence
are rejected even when an edited report is rehashed. Old evidence cannot acquire
strict status through decoding defaults.

New inventory, sample, disposition and validation traversal slots/work are admitted
before growth against finite native state/work limits across scenarios. They do
not reset retained Liberty accounting, deadline or cancellation. Exhaustion fails
without truncating evidence or publishing a partial strict report. This extends
logical workspace admission, not the unsupported whole-transform allocator/RSS
guarantee.

Verification requires maxPaths-independent coverage, noncritical roles, FF launch,
capture/control and literal coverage, checked-domain refusal, exact/insufficient
budgets, cancellation and saved/reloaded rehashed-omission/stale-input refusal.
Sequential execution eligibility and actual timing support remain separate:
source qualification alone does not implement latch transparency or enable/control
timing. See the PathAnalysis execution-support boundary before admitting a role.

`STAOperatingSupplyAssumption` retains an explicit caller condition for exact
instance/cell/corner/library/PG-pin/source-pg-type and binary value. The same values
enter request, effective configuration identity and retained strict evidence.
Source joining and power-down-function truth are owned by the sequential execution
helper; missing, duplicate, mismatched, true or unknown power-down facts fail.
Names, pg_type and nominal voltage never imply binary values. These assumptions
are not measured supplies, electrical qualification or functional equivalence
proof. Physical callers retain the same conditions; separate ECO proof and
qualification owners must independently include their required assumptions.

### Total supply conditions and retained design binding

Effective configuration encoding 9 / `timing.sta.3.9.0` binds the stronger complete
PG condition contract and source evidence schema 3. Every declared PG pin requires
one caller value, including pins unused by power-down expressions. Old strict
evidence requires preparation and replay; ordinary timing is not electrically
qualified by this change.

`PreparedSTAExecution.requireDesignBinding(to:)` verifies the actual retained
parsed design against a host-projected candidate through bounded semantic matching.
Top/schema, named instances/masters/connections, port direction/clock/net, and
explicit net capacitance/constants must agree exactly. Declaration order and
`port.net == nil` versus the same explicit port name are equivalent. Duplicate,
missing or additional named entries refuse. No topology is inferred from request
digests, and no netlist or Boolean semantics are reconstructed by the host.
Checked work/storage admission uses the retained source accountant and prepared
path limits before loops or allocation, without resetting a deadline or budget.
The synchronous operation retains only cumulative accounting after return and
publishes no new source or candidate authority. PhysicalHandoff consumes only this checked operation.

Prepared copies share one `NativeSTADesignBindingBudget` (`Mutex<UInt64>` in common
source) for cumulative comparison work. Source callbacks execute outside the lock.
Name matching and duplicate detection use charged byte comparisons and fixed local
slots, with no table materialization. The counter metadata has one retained exact
source-byte reservation. No target-specific storage or isolation branch is added.
Failure is `STADesignBindingError.mismatch`, `.capacity` or `.resource`; underlying
cancellation/accounting causes remain available without publishing a bound value.


| Shared state | Native / WASM / Embedded declaration | Read and mutation | Release |
|---|---|---|---|
| Design-binding work | One common `Mutex<UInt64>` | `charge` / `withLock`, with source callbacks outside the lock | Prepared owner and exact retained reservation |

There are no conditional storage, conformance or isolation declarations in this
extension. Native behavioral verification owns this sprint; existing portable
capability evidence is not generalized into a new WASM execution claim.


## Certified Coupled Boundary Model

The new opt-in requires strict source execution and an explicit bounded-operating-
history premise. Configuration v10 / `timing.sta.3.15.0` binds its resource caps,
source model, retained load-model identity and typed input-transition authority.
The encoding grammar remains v10; algorithm 3.15.0 identifies the execution method
owned by [ConservativeCoupling](../NativeExecution/ConservativeCoupling/DESIGN.md)
and participates in digest framing. The native-owned deterministic Swift factor
feeds the same continuous checker; factor and selection policy are defined only
by that child design. Its declared full-rail linear-ramp source
family and unique-event result contract retain mathematical model identity v1.
Conservative 3.10.0, 3.11.0, 3.12.0, 3.13.0, 3.13.1 and 3.14.0 configurations and reports are rejected by the current decoder;
their preserved historical CLI images remain the inspection path. A request carrying an old explicit configuration
digest is rejected rather than silently rebound to the new algorithm.
The older modes retain configuration v9 and algorithm 3.9.0, including their old
digest framing. Request schema 4 gains an optional conservative field; omitted
fields decode as absent. Old results cannot satisfy the new required model.

The [ConservativeCoupling](../NativeExecution/ConservativeCoupling/DESIGN.md)
source-domain contract uses full-domain owned characterization, rather than point
lookups. A parser-created default slew has no source-authority status.

The direct STAInitialSourceContextPreparing protocol is owned by [SourceFamilies](../NativeExecution/ConservativeCoupling/SourceFamilies/DESIGN.md). It consumes this exact retained owner without source rereads and leaves existing result schemas unchanged.

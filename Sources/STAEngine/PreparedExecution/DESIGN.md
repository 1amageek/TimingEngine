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


## Strict Transform Accounting

Status: the selected Native host prepare/execute and saved-result paths passed
the finite qualification below. `requiresStrictTransformAccounting` composes the
following cumulative resource contracts. This work changes resource
admission and lifetime, not parsing semantics, STA equations, source applicability,
effective configuration, or saved-result authority.

```text
one caller source accountant / cancellation / cumulative work
  -> controlled exact artifact read
  -> controlled design + SDC + SPEF intake / PDK manifest intake
  -> canonical joins + reduction + configuration + source inventory
  -> retained PreparedSTAExecution
  -> same native graph / scenario execution
  -> retained actual result + bounded artifact encoding
```

### Owning boundaries and required handoffs

| Owner | Required strict operation | Implemented boundary |
|---|---|---|
| TimingCore artifact I/O | Admit destination and simultaneous read-page payload before growth; preserve exact digest/size and asynchronous close failures | Additive controlled reader requirement; unsupported legacy conformers refuse |
| TimingCore CanonicalModel / PathConstraints / SPEF | Same admitted grammar and diagnostics, with checked capacity before every owned buffer growth and charged bounded traversal | Controlled grammar overloads retain their actual payload and failure owners |
| PDKDiscovery | Source-faithful manifest decoding and semantic validation using caller-controlled storage/work/cancellation | Public audited raw-span and controlled-manifest APIs retain document/failure owners |
| ProcessCorners | Exact existing manifest/corner/library joins, using the same accountant and retaining selected input owners | Consumes the controlled PDK handoff without duplicating PDK grammar or semantics |
| PreparedExecution | Input/configuration/inventory construction and retained publication | Retains actual admitted input payloads and reservations through the last prepared copy |
| NativeExecution | Actual graph/scenario/output construction, sorting and traversal, using the existing algorithms | Concrete payload/work admissions share the original caller accountant |

The existing `LibertySourceResourceAccounting` is the cumulative Timing-side
resource authority. New strict operations must use this same instance; they may
not create a fresh deadline, counter, or hidden unlimited budget. Existing Liberty
owned-source accounting remains separate ownership of the same caller budget,
without duplicate charges for shared retained payloads.

Admission measures declared managed payload capacities using checked counts and
concrete element strides, including simultaneously live source, destination,
copy-on-write migration and scratch buffers. It does not infer allocator capacity,
object overhead, physical memory, or RSS from a byte multiplier. Input byte and
logical element limits remain independently enforced. Foundation JSONDecoder internal parser workspace and allocator/runtime overhead
are outside this managed-payload contract, as they are outside the existing
Liberty logical-capacity contract. The source/schema owner must nevertheless
pre-admit the actual decoded DTO, string, array and map payloads from checked
source-proved counts/envelopes before decoding. A post-decode walk or an arbitrary
input-byte multiplier cannot establish this guarantee. Work and cancellation
claims cover the explicit admitted source/schema and transformation operations;
Foundation-internal instruction counts or interruptibility are not invented.

Every external resource callback is followed by a cancellation/deadline check
before the next allocation, traversal or publication. Work is admitted before the
operation, including fixed buffer initialization and copies. The retained owner
keeps both actual immutable payloads and their reservations; failure releases
invocation-local workspace and publishes no prepared/result authority. Prepared
and result copies share their respective owners. Raw extracted mutable values
remain caller-owned and require the corresponding retained owner, as for
`OwnedLibertySource`; this is not an automatic accounting claim for arbitrary
caller copies or mutations.

Legacy nonstrict overloads and injected conformers retain their current behavior.
Any additive controlled protocol requirement must refuse explicitly by default
when a legacy conformer has no controlled implementation. A custom reader or
parser cannot gain strict capability from its type name or from an outer guessed
reservation. Controlled file intake reuses the selected CircuiteFoundation controlled source
discovery and its immutable page/copy ownership. The host uses the agreed audited raw-Span PDK handoff;
the selected Native success/refusal paths passed the qualification below.

### Falsifiable completion evidence

- The existing real prepared fixture succeeds under strict accounting and produces
  the identical full STA payload/configuration/source evidence as the nonstrict
  path. Existing ordinary behavior and grammar/refusal fixtures remain unchanged.
- Tiny source, decoded-value, graph and scenario capacities refuse before the
  corresponding growth; no successful post-growth accounting is accepted.
- Repeated operations share cumulative work and storage admission. Cancellation
  triggered by the first caller reservation/work callback prevents subsequent
  allocation/work, using the same live caller context.
- Failure publishes no prepared/result/artifact; reservations for actual retained
  payloads survive copies and return after the final owner, including failed
  publication and cancellation. Temporary workspace is independently released.
- Custom legacy parser/reader conformers fail strict admission explicitly. Exact
  process/corner validation, full payload equality, saved-input replay and typed
  lower failures remain independently checked; saved metrics never replace STA.

### Strict Native qualification scope

The reviewed final public graph selects CF/TQ `26.1021.1`, LogicDesign
`9fbffcb1dfbf37517dfc05aa0f37f53c6a5e7659`, PDKKit
`82fddd548af704b3f0723eada8e5b09df2dad6e4` and unchanged SignoffToolSupport.
Its actual clean lock also binds CoreSpice `2b22cd47` and SDK `1.2.2` transitively.
The fixed Swift 6.4.0 / macOS 27 Native product builds and runtime gates passed:

| Selected product | Declarations | Expanded cases | Suites | Skips / issues |
|---|---:|---:|---:|---:|
| LibertyCodecTests | 35 | 66 | 5 | 0 / 0 |
| TimingEngineTests | 34 | 42 | 4 | 0 / 0 |
| STAPreparedExecutionTests | 9 | 14 | 2 | 0 / 0 |

These 78 declarations and 122 cases compose two unchanged final-graph product
runs with the final Prepared run after its test-helper cardinality correction;
they are not one monolithic full-suite run. The original failed helper check,
resource-control failures and genuine T1/T2 RED observations remain preserved.
The ONE comprehensive review and its finding-limited T1/T2/T3 recheck closed
without remaining findings. Final source changes after that execution remove
only fulfilled qualification comments and update documentation; functional Swift,
tests, package and lock bytes remain bound to the compiled freeze.

This evidence covers only selected host Native logical managed-payload intake,
graph/scenario transforms, rich failures and saved-result resource/lifetime
composition. It does not cover allocator/RSS ceilings, WASM/Embedded execution,
all-phase/root-domain/history/corner guarantees, physical qualification or the
separate genuine whole-flow CLI/public consumer. Existing unsupported semantic
branches and their markers remain authoritative.


### Audited host JSON specialization

STAEngine uses PDKDiscovery's existing audited raw-Span decoder for TimingDesign
and TimingParasitics. TimingCore receives the typed host decoder dependency; it
never imports PDKDiscovery or duplicates JSON grammar. Raw decoded documents have
nil sourceReference and grant no content authority. The actual controlled input
binding/byte owner stays retained independently. Custom schema constructors,
CodingKeys and derived validation remain Timing-owned accounting obligations.

The thin PDK bridge forwards parserWork, decoded-element/scalar and diagnostic
traversals to the existing cumulative work owner, and forwards exact live/temporary
byte extents. Balanced decodeNesting is finite and uses the caller-selected
sourceLimits.maximumNestingDepth for strict JSON grammar too. Other PDK capture or
profile dimensions are not used by this raw specialization and explicitly refuse.
The first underlying caller failure is retained under a common Mutex; callbacks
run outside it, and are checked before and after. This adapter never changes the
existing PDK counter version or resets caller work/deadline.

## Strict Native Transform Retention

Strict intake supplies the same optional `transformResources` to the existing
prepared initializer. Nil preserves legacy construction. Native graph/execution
payload admission is owned by [NativeExecution](../NativeExecution/DESIGN.md),
not by a new budget allowance. Prepared copies retain admitted role/consumption
payloads and the original source owners; a decoded record cannot reconstruct a
strict accounting owner. Public value copies separated from their owning prepared
or result value remain caller-owned accounting responsibilities.

Input-identity construction uses the CF-owned Data-copy and SHA managed-cost
contracts. Their temporary payloads coexist during the original hash call; the
returned digest backing is retained by the prepared value. Planning adds no new
encoding or SHA implementation, and copy/hash work is charged once to the same
original transform accountant before execution.


### Saved DTO Custom Construction

#### CF digest normalization on saved-result decode (T3)

The saved-result composition uses CF's checked ContentDigest Codable control and
PDK's explicit additionalUserInfo overload. Its actual saved-result path passed
the six new cases within the selected Native qualification above.
It adds no JSON parser, saved DTO, hash, validation authority or resource budget.
The existing legacy/custom decoder branches and semantic result replay stay intact.

```text
original LibertySourceResourceAccounting
    -> SAME NativeSTAPDKAccounting (first original caller error + typed sentinel)
        -> NativeSTAContentDigestControl
            -> explicit CF decoding context in SAME PDK raw decoder
                -> CF-owned Unicode normalization and validation
                    -> (document, control) success owner
                    -> whole lower error + control failure owner
```

The private control forwards check, scheduled work, temporary capacity and retained
normalized backing to the same PDK accountant. Its callbacks throw the existing
PDKAdmissionResourceError, so PDK's typed resource catch preserves that layer;
the accountant's first-error slot retains the original Liberty/caller error.
CF owns its exact mapping scratch, conversion overlap, normalization/validation
work and original Unicode/ContentDigestError semantics. Timing admits the control's
actual stored fields, Mutex<State>, receipt array backing and one-entry context
dictionary before constructing or growing them. The type-erased temporary lease's
concrete pair of payload/metadata receipts is admitted before constructing its
opaque returned value. Class pointer stride is not used as the control's
stored-payload size. Object headers and allocator rounding remain
outside the existing logical-payload contract.

Receipt growth separately admits the replacement backing while the old backing
and receipts stay held. It publishes under Mutex only after successful admission;
concurrent changes retry against the same cumulative work/cancellation owner.
Only short state access, reserveCapacity and append happen under this Mutex.
Upstream callbacks, post-callback checks and old/rejected-backing release happen
outside it. No release callback checks cancellation.

Success retains the complete PDK document and digest control inside the existing
TimingTransformValue. On failure, an already-admitted fixed Error slot in the
control retains the complete existing lower error; the original failure metadata
constructs TimingControlledTransformFailure without new admission or cancellation
callbacks. Its cause priority stays first original caller error, then the existing
audited originalFailure/domainCause, then the complete lower error. The control's
first-error ancestor never records the new outer failure, avoiding a control cycle.
Whole failure copies retain raw syntax/source strings and normalized reservations
until their final owner ends. Freely detached values/causes remain caller-owned.

PDK's generic catch still maps unrecognized custom Decodable failures to its
existing unsupportedValue. Timing's preexisting originalFailure capture can
expose the original CF domain cause while retaining that whole PDK failure; this
does not claim PDK itself preserves arbitrary CF errors. Other decode callers keep
the original preservingCause overload and behavior.

The STAPreparedExecutionTests owner adds actual saved-result uppercase/many-digest
parity, independent original-path work comparison, tiny cumulative work/storage,
callback cancellation, invalid long/Unicode cause parity and copied-failure final
refund. The fixture mutates only encoded digest text, preserving every numerical
token and the same actual prepared/executed result. The fixture checks exactly the two structured ContentDigest fields in effective configuration and provenance environment; artifact IDs use their existing single-string codec. These tests and actual replay
passed under the composed public graph within the finite scope above.

| State | Storage / isolation | Mutation / release |
|---|---|---|
| Digest receipts, backing and terminal lower error | One concrete Storage with Mutex<State> | Atomic publication; replaced backing releases outside lock; final shared control release refunds |
| Original caller failure | Existing NativeSTAPDKAccounting Mutex<State> | First underlying caller error only; never the outer control-owning failure |
| Mapping/conversion workspace | CF-scoped concrete lease wrapper around the admitted temporary owner | Same callback/check path and scope unwind |

No target condition changes storage or synchronization. This STAEngine composition
is the existing host Native lane; CF Core's separately qualified portable control
does not imply that the host PDK/Timing integration runs on WASM or Embedded.

The public bounded decode entry retains the PDK raw document. Its nested Decodable
initializers read PDKAdmissionDecodingContext.accountingKey, using the decoder's
existing retained accountant via NativeSTADecodingResources. Work, concrete scratch
and owned payload reservations return to the same original Timing invocation; no
second quota or userInfo authority is created. Missing context preserves legacy
generic Decoder behavior. A present malformed context refuses. Each custom
initializer must explicitly admit derived collections/hashes; generic arena
accounting is not claimed to cover those operations. Saved DTOs remain proposals
until prepare/execute/source-evidence replay succeeds on actual retained sources.

The controlled saved-result entry and reverse decoder accountant share the actual
PDK admission context. Custom STA DTO validation delegates to the owning
[NativeExecution](../NativeExecution/DESIGN.md) contract for its derived buffers;
raw JSON field admission does not stand in for those constructor allocations.


### Effective Configuration Wire

The controlled initializer preserves the existing configuration fields and wire
framing. Sorting compares the same ordered fields directly, avoiding temporary
comparison-key arrays. Each modes/defaults/source-clock table has its concrete
requested capacity admitted before filling. Configuration framing retains one
growing Data owner; old and newly requested buffers coexist under both leases
during growth. Scalar decimal scratch is represented before String construction;
JSON frames borrow the admitted encoded bytes without a Data→String copy. The
CF-owned scalar digest construction-cost contract is composed on the selected
public graph. No identity version or legacy digest bytes change.

### Controlled canonical and replay diagnostics

Strict preparation invokes the controlled canonical validator using the same source accountant. The one-library argument array and finding-code ordering workspace are admitted before construction. A retained report remains alive through diagnostic inspection.

Strict replay retains its numerical replay owners through comparison and constructs the original detailed mismatch text using a construction-local owned text buffer. Each replacement capacity is admitted while the previous payload remains live; numeric hexadecimal/decimal temporaries and UTF-8 replacement decoding have explicit representation bounds before construction. The original 96-byte field and 4096-byte message clipping semantics remain unchanged. The terminal replay error retains the final text reservation. Strict preparation prepays a failure boundary retaining its loaded source owners before subsequent joins; failure metadata is prepaid before error construction, and no accounting callback is required after throwing. Legacy replay keeps its existing path.

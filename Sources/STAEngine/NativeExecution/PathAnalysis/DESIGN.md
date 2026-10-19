# PathAnalysis

## Purpose and Scope
Own bounded exact-route functional STA over the admitted ideal-clock, cap-load
profile. Parent: [NativeExecution](../DESIGN.md). Child:
[SequentialExecution](SequentialExecution/DESIGN.md).

## Responsibilities and Boundaries
Own route propagation, typed selector resolution, exception evaluation and endpoint
coverage. Consume canonical design/library/constraints and effective workspace limits.
No source I/O, artifact publication, circuit equivalence or release authority.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [LibertyCodec](../../../TimingCore/LibertyCodec/DESIGN.md) | depends on | Owned normalized source functions | Original source authority | Retain OwnedLibertySource during traversal |
| [LogicValues](../../../../../LogicDesign/Sources/LogicIR/LogicValues/DESIGN.md) | depends on | LogicBit inverted/and/or/xor | Shared truth semantics | X/Z is never a static binary guess |
| [NativeExecution](../DESIGN.md) | parent | Scenario observations | Host composition | Publish only complete results |
| [PathConstraints](../../../TimingCore/PathConstraints/DESIGN.md) | depends on | Typed SDC subset | Selectors and scopes | Unsupported internal cuts fail |
| [PreparedExecution](../../PreparedExecution/DESIGN.md) | depends on | Effective finite limits | Immutable handoff | Limits enter configuration identity |
| [SequentialExecution](SequentialExecution/DESIGN.md) | child | Compiled source roles, normal-power conditions and timed FF/latch transfers | Actual sequential execution | Mixed FF/latch and transparent cycles are outside the admitted profile |

## Architecture
```text
validated connectivity -> deterministic topology -> launch/edge route arena
  -> endpoint alias + ordered through matching -> exception precedence
  -> numeric / static / excluded / unconstrained per-check coverage
  -> bounded materialization of worst setup and hold paths
```

## Contracts and Invariants

### Physical literal tie coverage

The admitted per-corner OwnedLibertySource remains retained during scenario analysis.
For a nonsequential cell with no canonical or source functional input pins, constant
output facts are admitted from the existing normalized Boolean source contract with
empty symbols. The run-local traversal consumes constants/invert/and/or/xor through
LogicIR LogicBit primitives, validating every prior-node edge and output range.
Unknown/high-impedance results are never approximated as binary constants.
Every source pin must be an output with a normalized zero-symbol function, including
unconnected outputs. Sequential facts, unsupported functional groups, three-state,
x-function and state function semantics prevent cell admission. Mapping selection
policies such as area/dont_use are not timing functional authority. No cell-name rule, parser or Boolean
optimizer is introduced. Other functions still require actual propagated timing.

These constants belong to the run-local physical-net coverage map. Actual mapped
instances, pins, area and source consumption remain unchanged; they are not extra
TimingDesign.Net.constant drivers. Each literal output independently covers all
connected port aliases and FF data endpoints with nil numeric slack/arrival. A
constant D never initializes Q: ordinary FF Q retains its clock-to-Q launch. This
closes the zero-input dual-output tie counterexample while preserving dynamic
missing-measurement refusal. No generic combinational constant propagation is added.

| Source / owner | Handoff | Result |
|---|---|---|
| Owned Liberty normalized function | Exact selected corner source retained | Zero-symbol binary constant DAG only |
| Run-local analyzer map | Physical output net, per alias constraints | Static setup/hold coverage |
| Mapped TimingDesign | Original instance and pins | No driver/provenance rewrite |
| Sequential timing model | Clock-to-Q launch | Q remains dynamic |

Native algorithm 3.4.0 / effective configuration v4 separates these coverage
semantics from prior evidence; request/result schema v4 remains unchanged.
The accepted 04E mapping profile evaluates zero-input functions such as !0 as one
(MappingFunctionMatcher.truth). Pinned LogicIR provides no public whole-DAG evaluator;
its validated operation/value contracts are reused, rather than adding an IR facade.
Temporary LogicBit slots plus live route records are admitted against the caller
maximumPathStates before allocation. Each source-cell/pin lookup and operation is
charged to cumulative path work. This is workspace admission, not a strict whole-
transform allocator/RSS guarantee. Slots cannot escape and release on return/throw.

STATieCellTests and actual TimingCLIProcessTests own dual-output/alias/no-table
success, source-semantic refusal and constant-D/dynamic-Q counterexamples.

### Native numerical model 3.4.0

Cell delays and output slews consume the actual route slew and summed physical
load. Cell derates apply to cell delay only; this equipotential profile has zero
wire propagation delay, so wire derates never multiply a cell LUT. Ordinary LUT
extrapolation remains supported and every propagated numerical result must be finite.

Source-bound setup/hold checks select the actual data transition and related clock
edge and evaluate the full constrained/related slew table. The ideal capture edge
is rising at zero or falling at half-period; setup uses the next selected edge and
hold the current selected edge. Explicit zero checks are measured; absent requested
checks on dynamic, nonexcluded data fail. Binary static checks and false-path
exclusion retain their existing distinct coverage, without fabricating measurements.

Recovery uses late control arrival before the next declared related-clock edge;
removal uses early control arrival after the current declared edge. Checks retain
physical reset/preset pin identity and rise/fall table meaning. Every contributing
control route must have an explicit min/max launch arrival for the requested check;
missing, constant-without-transition, unrelated-clock or nonfinite control facts
fail. Control checks remain independent of data false paths and static D. Ideal
clock slew is the admitted global input slew; no propagated clock-tree/waveform model
is claimed. Run-local check work is charged to the existing cumulative path-work
limit. Algorithm/configuration identity changes prevent stale numerical reuse.

`STANumericalModelTests` and actual `TimingCLIProcessTests` own analytical successful,
missing/unsupported, edge, derate, control-arrival and persisted-result cases.
A route retains its launch, every timing arc, transition and separate early/late
arrival and slew. Reconverging paths are never merged before exception checks.
The run-local noncopyable arena uses predecessor indices; stage arrays are made only
for selected reports. State/work admission precedes append or route matching. Owner
limits select the operational bounds; exceeding them fails, never truncates analysis.
Report maxPaths truncates reports only. Cancellation is checked during work charging.

Each output alias evaluates its own to selector, I/O delay and capture clock. FF
endpoints use instance/data-pin identity; source points are input ports or FF Q pins.
Clock lookup resolves the declared clock source through the actual physical net;
a clock name cannot substitute an unrelated sequential clock source. Internal path cuts are refused. Through groups match visited pin/net/instance facts
in path order. Selectors resolving no objects fail before analysis.

False path wins per check. Max/min delay overrides multicycle for its check. Explicit
setup/hold multicycle scopes override an overlapping both-scope constraint. Conflicting
same-priority values on a matching route fail; declaration order cannot pick a value.
Setup shift is (N-1) times the selected clock period. Hold shift is setup shift minus
H times the independently selected hold clock period. Both-scope H is zero. A missing
launch clock uses the capture clock for cycle counting; missing capture clock blocks
multicycle. Base FF setup includes setup time/uncertainty; hold includes hold time/
uncertainty. Max/min override clock-derived required time while retaining endpoint
setup/hold or external I/O delay and uncertainty. These are ideal-clock constraints;
nondefault clock phase or differing launch/capture periods are explicitly refused.
Each I/O check role has one clock reference; input min/max share that reference.
Multiple I/O clock references are explicitly refused, never collapsed to the first
record. No general phase/frequency-domain timing guarantee is added.

For each check, choose the route with least slack, not greatest arrival alone. Hold
paths use early delay/slew and arrival-minus-required slack. Constant drivers seed no
transitions. Constant D never makes Q static. Static and fully excluded checks have
nil numeric slack but distinct explicit coverage. A false path is not functional
proof and does not exempt circuit equivalence. Missing eligible constraints remain
unconstrained, even when another route/alias is measured. Control checks remain
independent of data false paths and static data.

## State, Ownership, and Lifecycle
One invocation owns the noncopyable workspace. Arrays/dense indices retain all route
storage until report materialization; no pointer, shared mutable owner or target
conditional isolation is introduced. Late failure releases the whole workspace.

## Failure, Concurrency, and Constraints
maximumPathStates bounds live scenario arena records; maximumPathWorkUnits is
cumulative across all scenarios and bounds traversal and
selector matching independently of report count. Effective limits are retained and
hashed by preparation. Numeric overflow/nonfinite propagation, contradictory matches,
missing clocks/arcs and resource exhaustion fail explicitly without a report.
The pre-existing whole-transform strict allocation accountant remains unsupported.

## Verification and Change Impact
STAPathExceptionTests checks analytic route tables, reconvergence, alias selection,
ordered through, min/early paths, multicycle hold restoration, precedence, constants,
controls, limits and malformed input. Runtime owns source-to-cell proof/STA/save/reload
and rehashed-exclusion refusal; Xcircuite owns composing candidate/flow verification.

Opt-in distributed native 3.5 composes the [DistributedRC](../DistributedRC/DESIGN.md) contract before each receiver LUT, data/control check and port endpoint. Existing ideal-clock constraints remain; distributed finite-R clock nets explicitly fail. Each route retains its sink-specific wire delay/slew separately from cell derates.

Native3.6 composes [ClockPropagation](../ClockPropagation/DESIGN.md) for explicitly propagated primary clocks. Receiver clock arrival/slew and exact root edge/phase replace ideal assumptions only in that declared distributed profile; legacy nil-distributed behavior stays ideal.

## Complete Source Consumption and Strict Samples

Status: supported native opt-in implementation and behavioral verification are complete.
Verification covers 175 affected native test methods and the digest-checked actual
Sky130 sequential helper. Production, post-route integration and process
qualification remain separate completion scopes.

### Source applicability and static asynchronous state

Required pulse roles are actual TimingCell pulse laws, distinguished by exact
source identity and opening edge. A complete source with no law or asynchronous
control produces typed source-not-applicable coverage. A source-proven constant
control produces static-control-not-applicable coverage for its transition
checks; an unconstrained primary input remains unknown. These statuses are
distinct from static data and from a measured passing check.
The public check statuses are sourceNotApplicable, staticControlNotApplicable and
staticStateNotApplicable, alongside the existing measured/static-data/excluded/
unrequested/unconnected/unknown statuses. A check-applicability role identifies
the analysis kind whose source absence was proven. Actual law roles never vanish
when they become static; their exact source identities retain the static reason.

Full normalized clear/preset bindings, actual constant nets and explicit PG
conditions determine asynchronous state. Proven inactive controls preserve
clock-to-Q launch. Asserted clear or preset fixes the declared state pair and
each original output binding; it seeds binary output coverage and generates no
clock-to-Q transition. Setup/hold capture under held asynchronous state has typed
static-state-not-applicable coverage without claiming that physical D is static.
Simultaneous unsupported clear/preset actions and unresolved state fail.
Positioned directional clear/preset arcs remain in the required source inventory;
constant-control/state no-transition dispositions retain those exact identities.

Dynamic pulse checking consumes explicit source inputs through
[PulsePropagation](../PulsePropagation/DESIGN.md). Successful pulse/control checks
do not implement directional asynchronous Q propagation. If a requested endpoint
depends on that unavailable timing, it remains unknown and strict completion
fails. A pulse-only scope may classify unused output propagation as unrequested;
it never upgrades that classification to an output timing guarantee.

For each high/low law, both actual opening-edge contexts are queried against the
checked source law and retained independently. Each context uses the earliest
corresponding closing event and its original nominal root phase/cycle pairing;
receiver delay cannot select another nominal cycle. The minimum resulting slack
includes uncertainty once. A crossed or negative width fails rather than being
wrapped into a positive period. Scalar laws retain no fabricated slew query.
Samples retain the exact law, source query, opening/closing arrivals, context,
root edges/phases, cycle offset, actual width, uncertainty and slack. Prepared
replay compares all applicability, static-state and pulse receipts, independent
of displayed maxPaths.
The opt-in policy and independently derived role inventory are owned by
[PreparedExecution](../../PreparedExecution/DESIGN.md#strict-source-evidence-extension).
PathAnalysis owns actual execution receipts and per-role dispositions. Report
`maxPaths` limits only materialized display paths; it never limits the inventory,
performed-evaluation receipts, check dispositions or their validation scope.

Each receipt binds mode/corner, mapped instance and exact source role, source-local
arc/check/table identity, actual transition and early/late context, actual lookup
operands, raw evaluated result and applied numerical transformation. Propagation
records actual input slew/output load and delay/output slew; sequential constraints
record constrained/related slews, edges and signed constraint values. Source-domain
checks precede publishing a numerical receipt. Strict evaluation consumes the
retained source-qualified evaluator, without scalar fallback, extrapolation or a
second lookup using a representative operating point. Ordinary STA retains its
existing numerical contract outside this opt-in.

Receipts are collected where evaluation occurs: input launch context, FF
clock-to-Q seeds, combinational/clock propagation, data capture, recovery/removal
and pulse-width checks. FF launch is not lost because its existing route point has
no display step; control checks are not lost because they bypass candidate paths.
Dense run-local point/sample indices retain operand origins and source identity
without materializing every full path. Display stages project those same records.
Sequential samples retain each queried branch's attained/infimum/supremum
coordinate, original causal interval, signed epoch, release, window, waiting and
borrowing facts. All bounded early/late candidates are evaluated and retained;
the selected envelope never replaces an actual source query with an epsilon
coordinate or an invented route point. Clock-buffer samples enter the same arena
at evaluation, independently of the displayed critical path limit.
Existing wire/clock observations remain their owners' evidence and are referenced
by the actual received slew/arrival rather than replaced by default values.

| Disposition | Required witness | Numerical meaning |
|---|---|---|
| Evaluated | Actual checked samples and operand origins | Source-bound measurement |
| Static binary | Exact normalized functional source and binary value | No invented zero delay/slack |
| Excluded | Resolved exact exception/check scope | No numerical pass or equivalence claim |
| Unrequested/unconnected | Independently derived role and precise reason | No timing measurement |
| Unknown/unsupported | Missing or unsupported required fact | Blocks strict completion |

Mixed measured and unknown routes never collapse to complete coverage. Every
required inventory role must have a valid disposition, with no foreign or duplicate
identity. A count or a self-declared complete flag cannot substitute for exact set
comparison. Receipt query/result/range and upstream references are validated against
the retained source-qualified owner and exact prepared inputs on reload. Source,
design, constraints, corner, variation, policy or evidence-version changes invalidate
reuse; report truncation never repairs missing evidence.

### Sequential execution-support boundary

SourceCodec owns the full source sequential definition and eligibility; this
component must execute the admitted role semantics. A scalar dataPin or the first
symbol of a compound next-state expression is not that definition. The existing
simple edge-FF launch/check path does not by itself support enabled FFs, multiple
data/control roles or latches. Supported edge-FF execution must consume all admitted
source data/enable/control dependencies and their actual requested checks. Latch
execution must own its transparent interval and closing-edge semantics; a latch
cannot enter the existing edge-FF seed path. Missing implementations refuse the
role explicitly. Such refusal is a safety boundary, not completion of the broader
sequential-placement goal. Static D never initializes or suppresses dynamic Q,
and data exclusions never suppress independent control checks.
Clock preparation and execution consume the compiled source plan's clock/gate
pin, active/closing edges and complete output inventory. Optional legacy scalar
pin projections do not determine eligibility. Connected outputs use independent
actual source arcs; unconnected outputs retain explicit source coverage.

Inventory/receipt/reference/output growth and validation work share finite logical
state/work admission before allocation or append; source accountant/deadline and
cancellation remain active. Exhaustion releases the invocation workspace and
publishes no partial strict result. The implementation does not claim strict
allocator/RSS accounting for existing transforms.

Focused falsification covers maxPaths 1 versus larger reports with identical full
role/sample scope, a noncritical cell absent from display paths, step-less FF launch,
capture/control checks outside paths, literal static and explicit exclusions,
unknown refusal, out-of-domain or missing strict tables, signed/zero constraints,
budget/cancellation and source/config/query/role tampering after save/reload. Enabled
FF/latch success requires separate actual execution evidence for the admitted
semantics; no inventory-only test closes that gap.

### Setup optimization applicability

`STAPayload.setupApplicability` is Native-owned and compared by exact prepared replay.
`measured` requires a finite actual aggregate. `sourceNotApplicable` requires no active
setup path or unconstrained endpoint, at least one explicitly static/NA setup endpoint,
and every prepared setup role to have source-proved static data/state or source absence.
`unknown` never admits placement. Upper consumers preserve NA as a distinct cost state;
they do not manufacture numeric zero or infer applicability from a nil aggregate.

`STAPayload.validateSetupApplicabilityStructure()` shares the Native derivation
predicate with saved report decoding and Upper admission. It rejects contradictory
aggregate, finite endpoint, active setup path, or measured role claims without
reconstructing Liberty truth. Structural consistency never grants source qualification.
Before allocation, checked bounds admit at most `R+C+E+P+1` retained slots and
`3R+C+E+P+1` work units against the effective configuration (roles, coverage, endpoints,
paths). The fresh/replay owner also charges this work to the cumulative source
accountant; Upper charges its own operation budget before invoking the helper.
Failure is `STASetupApplicabilityError.invalidStructure` or `.capacity`, with no
associated values. The helper is synchronous, value-only, and retains no state.

An endpoint inspection is one logical work unit with at most five analysis kinds
in each static/NA list. O(1) cardinality guards precede membership scans and bounded
duplicate checks; oversized lists fail capacity and duplicates fail structure.
The configuration kind list is likewise bounded to five before membership scans.
This work unit is a bounded semantic operation, not one primitive CPU instruction.
Native endpoint composition appends each applicable kind once.

### Total checked normal-power evidence

Strict source evidence schema 3 and algorithm 3.9.0 require one checked normal-power
observation per mapped instance and exact scenario. The independent inventory
contains a normal-power role for each instance. Each observation binds the Core
source receipt to that role's exact artifact/cell/instance/corner/mode. PG pin
coverage retains the corresponding explicit binary values. Reexecution compares
every receipt, including all declared PG and every original power-down function.
Schema-2 evidence is stale and cannot claim this stronger contract.

This intentionally stops accepting absent values for declared but unreferenced PG
pins in strict execution. Valid fixtures now supply real explicit caller conditions.
Non-strict timing does not become power-qualified. Request/result transport 4,
cell timing mathematics and ordinary extrapolation remain unchanged.


## Certified Coupled Boundary Model

Certified mode consumes [ConservativeCoupling](../ConservativeCoupling/DESIGN.md)
wire intervals. Arrival and slew extrema are independent: earlySlew stores the
slew lower bound and lateSlew the upper bound, with no arrival correlation claim.
Every downstream LUT evaluates the whole slew/load rectangle and all internal
knots. Delay and output-slew extrema are independently propagated. All five check
kinds consume the maximum source law over their complete slew domain. Ideal and
propagated capture checks obtain related slew from the same explicit clock boundary
as clock-to-Q launch; a global input transition cannot replace a supplied clock
transition. Conservative
CPPR is zero. Directed arithmetic encloses cell/wire derates, path arrivals,
required times and reported slack. Unproved latch epoch classification fails.

The source owner spans every dynamic driver in the complete preserved topology,
using positive explicit primary/clock transitions or the positive minimum over
all relevant characterized output-transition domains. Constants have zero slope.
For a cell source, the existing prescribed boundary load is the exact load already
used by the host's NLDM lookup. Source slope authority evaluates every relevant
propagation group and each source-declared output direction at that singleton
load, retaining the complete declared input-slew axes and every interior knot.
The owned public characterized range evaluator supplies these bounds; a point
input query or a clipped input-slew intersection cannot substitute for the full
domain. Incompatible domains, missing loads, incomplete declared direction pairs and nonpositive
transition minima fail explicitly. Directional-control groups retain their exact
kind/source identity and existing constant-control exclusion. Primary ports and
constant sources retain their current authority. This changes neither the fixed
NLDM load model nor the full-rail operating-history, phase or quiet-source premise.
`STAConservativeSourceLoadTests` owns fixed-load versus full-load regressions,
interior input knots, every arc/output edge, FF clock-to-Q and load refusal.
After one immutable operator preparation, source domains may be refined using
receiver slew bounds proved under the previous complete source box. Every relevant
input pin of a cell driver must have both edge bounds before any dependent output
is narrowed. All arc/direction evaluations retain the same fixed load and exact
source identities; their hull intersects the previous output domain. Ports and
constants remain unchanged. Each round reads only the previous box, then publishes
its complete subset through the lower `restrictSources` contract without graph or
factor reconstruction. No clock timing pass, phase or quiet assumption is used.

The deterministic loop stops when no bound changes its binary64 representation.
Every round, input query, collection growth and source evaluation consumes the same
cumulative state/work/source deadline budgets; the coordinate-certificate attempt
limit is not reused as an independent round counter. Only a query's explicit
unprovedCrossing, unprovedUniqueTransition or CandidateNotCertified may leave an
input unproved. That input prevents narrowing its dependent output; it supplies no
fallback bound. All other errors propagate. Inputs outside the preserved electrical
network have no receiver proof and therefore cannot narrow an output.

Actual source domains and the existing NLDM load-selection approximation are
retained in conservative observations. This boundary/load abstraction is a model
premise, not a physical-driver guarantee. The same request-scoped budget and source
accountant cover host joins, exact query caching, receipts and numerical work.
Source-join collections and endpoint names are admitted before growth; every
visited net, port, cell pin, arc and source selector charges the shared work counter
and checks cancellation. Driver-to-authority joins retain an index rather than
repeatedly scanning the authority array.


### Certified Directional and Sequential History Authority

[ConservativeCoupling](../ConservativeCoupling/DESIGN.md#staged-source-history-certificates)
owns centered directional/phase/isolated-event bounds and the internal history
contract. This component retains each cell output direction independently over its
complete relevant owned input/arc ranges and fixed load; it must not union rise
and fall into one source range. Previous-box refinement keeps that direction and
all its source/load/receipt bindings. Primary data phases and unknown sources stay
unrestricted.

Wire preparation uses the staged owned waves from
[ClockPropagation](../ClockPropagation/DESIGN.md#certified-source-history-publication),
intersects each old per-edge source range with its proved wave slew (empty
intersection fails), and publishes restrictSources, addingSourceHistory, source
authorities and the checked response-cache generation atomically after all frontier
queries have used the old box. Numerical facts are reused; roots remain unchanged. It stores no duplicate caller
query-phase metadata: the lower solver derives a clock query's reference envelope
from its own canonical source history, edge and slew. Publication/invalidation and
all collection growth use the original shared budget/accountant.

The strict FF timing path can add a Q minimum-plateau fact only after ALL its
receiving CLK rise/fall queries complete. Reuse the actual qualified per-output-
edge CQ transfer arrival/slew ranges and their existing source receipts; do not
reevaluate a new glitch model or assume timing checks passed. Eligibility requires
the exact supported FF/unary-state output, no asynchronous/additional controls and
validated normal power. Apply the lower Q-support/gap contract with selected
output thresholds and full-rail durations. Unknown, gated or ineligible cells gain
no restriction. Arbitrary initial state, holding Q, either output direction and
skipped clock cycles remain admitted. An unproved/invalid/nonpositive gap cannot
become a favorable history fact. Completed clock events may justify Q history;
Q history may not justify its own prerequisite clock proof.

Fresh source validation rebuilds these facts in the same staged order from the
exact design/SDC/Liberty/normal-power/load inputs. It does not accept a serialized
history verdict. Tests cover directional source identity/range retention, staged
cache generations, Q-before-clock refusal, unsupported-control/power facts,
qualified Q hold/skip behavior and exact required receiver/source coverage.

The [initial source context](../ConservativeCoupling/SourceFamilies/DESIGN.md) uses the same constants, loads and initial source selection before response preparation. Its separate initialRoots operation does not run refinement or derived history publication.

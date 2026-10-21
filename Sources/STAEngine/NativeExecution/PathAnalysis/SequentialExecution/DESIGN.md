# Sequential Execution

## Purpose and Scope

Own source-defined sequential timing eligibility, FF launch/check roles and
acyclic latch transparency. Parent: [PathAnalysis](../DESIGN.md). No children.
This is an internal helper component; it introduces no public engine or policy.
The root approved this contract and the composing model and checked-sample interfaces.

## Responsibilities and Boundaries

TimingCore owns normalized Liberty definitions, exact pin/state/supply binding,
positioned arcs/checks and checked numerical samples. This helper consumes those
values without reparsing expressions or guessing an enable mux from pin names.
PathAnalysis owns the route arena, exceptions, numerical sample lookup, retained
receipts, endpoint coverage, publication and scenario identity.

The helper does not interpret a source cell with an unavailable single-pin
compatibility view as combinational or substitute legacy FF behavior for a latch.
Explicit caller-authored legacy scalar models retain their distinct legacy kind.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PathAnalysis](../DESIGN.md) | parent / used by | Actual route transitions and shared budgets | Composes returned transfers/checks into the arena | Preserve parent route and receipt identities |
| [TimingCore](../../../../TimingCore/DESIGN.md) | depends on | Explicit source versus legacy sequential definitions | Full normalized pin/state/supply bindings | Optional compatibility pin views are not source authority |
| [LibertyCodec](../../../../TimingCore/LibertyCodec/DESIGN.md) | depends on | Original functions and positioned numerical groups | Immutable source authority | Missing/conditional groups are never synthesized |
| [ClockPropagation](../../ClockPropagation/DESIGN.md) | depends on | Receiver rise/fall events and source root phase | Actual clock windows | Ideal clocks need an explicit period/waveform |

## Architecture

```text
bound source definition -> eligibility plan: FF or latch, all referenced pin roles
actual pin transition + receiver clock events + checked source samples
    -> FF launch / source check / latch window transfer
    -> timed result + causal parent + actual sampled arc/check + borrow/window facts
    -> PathAnalysis arena and independent complete-consumption receipts
```

## Contracts and Invariants

The planned internal `NativeSTASequentialExecution` first compiles one complete
bound source declaration into a mode/corner-independent plan. Every next-state
input reference is retained, including data and enable references. State variables
are distinct named slots, not physical data pins. Each output retains its exact
state/function binding and its own source timing arcs. The initial execution
profile admits a single declaration and a single physical clock/gate expression
with optional inversion. Multiple groups, compound clocks, additional clocks,
unbound symbols or unavailable required semantics fail with typed unsupported
errors. They remain source sequential models and never become combinational.

Timing methods consume actual pin/edge, early/late arrival and receiver slew,
physical output load, parent route index, and actual clock events or an explicit
ideal clock waveform. They consume checked `TimingSourcePropagationSample` and
check samples supplied by PathAnalysis; ordinary LUT summaries are not substitutes.
Returned early/late results retain the actual sampled input pin/edge, query slew,
load, raw cell delay, applied envelope delay, output slew and receipt index.
Causal data identity is separate from the timed clock/gate arc identity.

FF outputs launch only on the declared source clock edge, through each output's
actual clock-to-Q sample. Referenced next-state pins require the requested source
setup/hold checks, with physical constrained pin and source related edge retained.
Clear/preset checks consume their actual control routes and source recovery/removal
edges independently of data checks. Missing source checks never become zero.
Conditions and power-down functions require exact bound Boolean facts: unknown
cannot be assumed false or converted to a binary constant. The numerical owner
must explicitly admit any conditional group before it can be consumed here.

Latch output is not initially seeded as an FF launch. Its physical data
dependencies participate with combinational cells in a finite acyclic order;
transparent feedback cycles fail instead of using an unbounded fixed point.
A high-enable latch opens on rise and closes on fall; an inverted enable reverses
those roles. The source close-edge setup/hold checks remain endpoint checks.
The actual receiver events define early/late opening and closing boundaries.

For an isolated data transition ready before opening, release uses the opening
enable-to-Q sample. A transition within the transparent interval uses its actual
data-to-Q sample. A transition after closing waits for a subsequent opening,
using checked constant-time period arithmetic; the original close-edge violation
is retained. Borrowed time is the nonnegative data arrival beyond the selected
opening within its transparent interval. Window/cycle and deferred-release facts
remain explicit. Early and late bounds may select different source arcs, so they
retain separate samples. No gate/data arc substitution or zero waiting fallback
is permitted. Finite, ordered clock windows and representable cycle arithmetic
are mandatory; incompatible root clocks or overlapping uncertainty bounds fail.

## Runtime Flows

Compile exact bindings -> resolve both clock edges -> obtain requested checked
samples -> execute one FF launch/check or latch transfer -> append only a complete
finite result. PathAnalysis retains the original data parent even when an opening
clock arc determines a latch release, and separately records that timed arc.

## State, Ownership, and Lifecycle

Static asynchronous controls use the same normalized Boolean execution owner.
The opcode evaluator is shared internally through a slot-value closure; the
existing strict Boolean entry point still requires every original symbol.
The static entry point supplies LogicBit unknown for genuinely unbound slots,
without moving state or PG names into the physical-input compartment. Actual
constant inputs and exact explicit PG conditions may prove clear/preset truth.
Inactive controls preserve dynamic launch and unknown initial state. One asserted
control fixes the source-defined state pair and original output projections.
Unknown truth and unsupported simultaneous actions cannot establish a static
state. This extension adds no default initial state or dynamic async timing.

Plans and results are invocation-owned values. The retained source owner outlives
execution; no source pointers or borrowed views escape. Temporary normalized-DAG
slots and result records are admitted through the existing shared
`NativeSTAStateBudget` before allocation. Its cumulative logical-slot contract
is preserved; this is not a whole-heap or measured zero-copy guarantee.

## Failure, Concurrency, and Constraints

Methods receive `work: inout UInt64`, `STAExecutionLimits`, optional existing
source resource accounting and the shared state budget. They precharge each
visited binding, Boolean operation, arc/check selection and emitted result to
the same cumulative path-work counter. Checked arithmetic precedes increments;
cancellation/deadline checks occur at admission boundaries. No closure borrows
PathAnalysis's mutable self while an independent helper is executing.
No new operational ceiling is inferred. Existing state/work limits bound plan,
temporary-slot and transfer counts; period arithmetic does not loop over cycles.
Unsupported semantics, missing samples, nonfinite arithmetic, exhausted budgets
and cancellation propagate as typed failures without partial successful results.

## Verification and Change Impact

The helper's independent tests must reject the original enabled-FF first-token
counterexample, consume all D/EN/control checks, preserve clock polarity and
per-output bindings, and reject missing required checks and unbound source slots.
Latch tests distinguish pre-open enable-to-Q, transparent data-to-Q, close-edge
setup/hold, positive time borrowing, deferred post-close release, and an acyclic
two-latch chain from a refused transparency cycle. Budget exact/one-below,
cancellation and nonfinite cases must use the actual helper path.

An actual-source candidate is the retained Sky130 `dlxtp_1`: data `D`, enable
`GATE`, D setup/hold on the falling close edge, D-to-Q combinational and GATE-to-Q
rising-edge NLDM groups. Those groups contain no timing `when`; output
power-down requires explicit source supply facts. This inspected source supports
only that declared initial profile, not general conditional cells. The selected initial source profile is this actual cell. PathAnalysis and host strict-consumption tests
own full report/adoption evidence and algorithm/configuration identity changes.

### Normal Operating Power

`validateNormalPower` consumes the exact admitted `LibertySourceCell`, instance,
corner and library artifact identity. Every assumption in that instance/corner
scope must uniquely match the original cell, library, PG pin and raw `pg_type`;
other instance/corner scopes are validated by their composing owner. All consumed
assumptions and every declaration/pin-level power-down function position are
returned in a conditional normal-profile receipt. The composing owner verifies
complete request-assumption consumption. No PG role or pin name implies a value.

Every original power-down function must evaluate to false using only explicitly
joined supply assumptions and source-proven input constants. Missing supplies,
dynamic/unbound symbols, unsupported functions, true power-down and conflicting
assumptions fail. State variables are never initialized to zero. This receipt
is conditional logical eligibility, not electrical supply qualification.
The actual `dlxtp_1` test supplies explicit VPWR=1 and VGND=0 assumptions and
rejects their omission, changed source PG kind, cell or artifact identity.

### Concrete Internal Interface

`compile` returns kind, physical clock/gate pin, active/open edge, close edge,
all next-state data references, asynchronous control references, bound output
definitions, full function bindings and source checks. `evaluateNextState`
requires explicit input and state values and interprets the original normalized
program. No optional compatibility view is an execution authority.

Latch transfer selects bounded early/late arrays of `SampleRequest` candidates
from the actual transition interval and receiver windows. The caller evaluates
all exact original data/gate arcs and supplies checked sample/receipt arrays. `complete`
verifies the query and source identities before producing timed bounds. A
separate causal parent is retained when a gate arc determines release. FF
launch uses the declared edge and original per-output clock-to-Q samples.
These operations precharge the shared work counter and logical-slot budget.

Transparent latch/combinational DAG ordering and cycle rejection are owned by
PathAnalysis composition; a single helper transfer cannot prove that topology.
Mixed FF/latch execution is outside the initial admitted transparency profile.

Plan admission uses a conservative `4*S*S` comparison-work envelope, where S
is the sum of source pin/PG/binding/check counts, normalized symbol/operation
counts and two. This covers the bounded nested membership/identity searches;
it is an abstract work-unit envelope, not estimated FLOPs. Temporary dictionaries,
arrays and result elements reserve cumulative logical slots before population.
The source owner and caller samples remain immutable retained values; Swift COW
may allocate on mutation, and this component makes no zero-copy claim.

Completion takes explicit early/late cell-delay scales. Only the raw source cell
delay is scaled; physical branch waiting, window, borrowed time and cycle retain
clock semantics. The final scaled early/late arrival envelope must be finite and
ordered. Applied envelope delay is measured from the causal interval endpoint.

### Reviewer Finding Repair Contract (Approved; Production Waits for Root RED Observation)

F1 requires an interval envelope, not evaluation only at its two arrival endpoints.
For input [a,b], opening [oe,ol], closing [ce,cl] and period P, possible data
branches intersect [a,b] with (oe+kP,cl+kP), k in Z. Possible gate branches
intersect [a,b] with [ce+(k-1)P,ol+kP], also k in Z. Finite negative arrivals
remain in their actual signed epochs; no arrival is folded into epoch zero.
Each branch's output is monotone in its coordinate for a fixed actual source
sample. Therefore only its first and last intersecting epochs are needed, found
by checked floor/ceil arithmetic, without iterating through epochs.

Each early context requests at most the earliest data and earliest gate samples;
each late context requests at most the latest data and latest gate samples.
Data bounds at an open/close boundary are explicitly infimum/supremum coordinates,
not fabricated actual input transitions. The LUT query still uses the original
physical data pin/edge, caller-provided contextual data slew and actual load.
Gate candidates retain their actual physical gate pin/edge and contextual gate
slew. No epsilon time or artificial table operating point is constructed.
Clock uncertainty is conservatively represented by the union of admitted windows;
window ordering remains the existing nonoverlap contract.

`TransferRequest` will expose bounded early/late candidate arrays (each <=2).
Completion consumes exact-length checked sample and receipt-index arrays, applies
the contextual cell scale to every candidate's raw delay, and selects minimum
and maximum arrivals. All evaluated candidates retain source receipts through
PathAnalysis; the selected bound retains branch, epoch, coordinate meaning,
selected input coordinate, waiting, window and receipt identity. The selected
bound's applied envelope delay is output arrival minus the corresponding causal
input interval endpoint; physical branch waiting remains a separate field.
This preserves parent-envelope arithmetic when an interior branch wins.
The input interval, rather than a manufactured interior route point, is causal.
FF requests remain singleton candidate arrays.

The number of candidates, table samples, result slots and arithmetic operations
is independent of interval epoch count. Requests reserve their bounded arrays
before population and precharge four arc scans plus constant arithmetic work.
Completion charges every candidate and checks cancellation at candidate boundaries.
Nonfinite arithmetic and unrepresentable phase shifts remain explicit failures.

F2 preserves role unions. A physical pin referenced by both next-state data and
asynchronous control requires setup, hold, recovery and removal checks, each
joined to its original source group and actual constrained/related edge. No role
has precedence over another.

F3 adds exact original physical-input and PG pin sets to the Plan. Every provided
input/state/PG dictionary key must belong exclusively to its corresponding source
compartment. Required slots are resolved from `TimingSequentialFunctionBinding.Symbol`,
not from a merged name dictionary. A state supplied in physical inputs, an input
supplied in states, an unknown key or a PG value in another compartment fails.
`evaluateNextState` receives an explicit PG dictionary (default empty); a missing
required PG slot fails. This does not infer supply values or replace the separate
normal-power validation receipt.

Finding verification adds the [1,6] ns counterexample (interior 3 ns -> Q 4 ns),
role-overlap four-check consumption, injected state/unknown-key refusal, multi-epoch
constant-candidate envelopes, explicit unattained boundary limits, and scaled
completion. Root owns bounded compile/runtime and the PathAnalysis integration
check. Existing source fixtures, AREA/routing mathematics and numerical tables
are outside this repair.

The signed periodic candidate formulas are:

| Branch | First intersecting epoch | Last intersecting epoch | Candidate coordinate |
|---|---|---|---|
| Data | `floor((a-cl)/P)+1` | `ceil((b-oe)/P)-1` | early `max(a,oe+kP)`; late `min(b,cl+kP)` |
| Gate | `ceil((a-ol)/P)` | `floor((b-ce)/P)+1` | early opening `max(oe+kP,a)`; late opening `ol+kP` |

A branch exists only when its first epoch is no greater than its last epoch and
the computed coordinates satisfy the original interval intersection inequalities.
Data opening limits are infima and closing limits are suprema; a point exactly
at opening or closing remains a gate-branch point. Gate candidates use an
attained input coordinate `max(a,ce+(k-1)P)` within the original input interval.
No candidate invents an input route point or an epsilon-offset arrival.

Epoch indices must convert exactly to signed Int and stay within the exact
binary64 integer domain. Every shifted opening/closing and coordinate is checked
for finite, ordered, representable arithmetic before publication. A nonrepresentable
phase fails explicitly. The formulas have constant work for both negative epochs
and intervals spanning many periods. A negative-time differential test shifts
input/window expectations by an exact integral number of periods and requires
the corresponding shifted arrival envelope, while retaining actual source samples.

Final API agreement is with the PathAnalysis implementation owner. `SampleRequest`
adds `branch`, `coordinateMeaning` and `selectedInputCoordinate`; `cycle` is signed
Int. `TransferRequest` stores `earlyCandidates` and `lateCandidates`, each at most
two. `complete` accepts exact-length `earlySamples`, `lateSamples`,
`earlyReceiptIndices` and `lateReceiptIndices`. Selected bounds preserve the
candidate and its receipt. All queried candidate receipts remain retained by
PathAnalysis. The helper owns no arena or global evidence mutation.

The bounded runtime request envelope is four arc-record scans plus 160 scalar
work units for intersection/phase arithmetic. Completion precharges 40 units
per candidate (at most four), excluding lookup accounting owned by the source
evaluator/caller. This is logical work admission, not measured FLOPs or wall time.
Candidate arrays reserve five logical slots before population; completion reserves
three result slots. Required check-role selection visits at most four kinds; the
fixed-size temporary result is bounded by four checks, and caller-retained check
evidence is admitted by PathAnalysis.

Local behavioral verification is owned by
[STASequentialExecutionTests](../../../../../Tests/TimingEngineTests/STASequentialExecutionTests.swift)
and the separately required-input
[STAActualSequentialExecutionTests](../../../../../Tests/TimingEngineTests/STAActualSequentialExecutionTests.swift).
The finding RED is retained by the root in `sequential-findings-red-4` (3 tests,
4 issues); post-fix GREEN and full PathAnalysis source execution remain distinct
verification obligations.

### Shared checked normal-power owner

The helper delegates normal-power source judgment to the public LibertyCodec
validator. It only joins exact instance/cell/corner/library conditions and projects
the checked receipt into its internal compatibility view. All declared PG values
are explicit and unique. No static input substitution qualifies power in this
profile; reset/data/state timing policies stay here. The mechanical normalized
Boolean loop is package-owned by LibertyCodec and reused through a thin delegate.
Existing FF/latch/state truth and numerical semantics remain unchanged.


## Certified Coupled Boundary Model

Certified FF/latch transfers follow the parent [PathAnalysis](../DESIGN.md)
independent interval contract. Each causal data/gate/clock branch retains its
full input-slew interval and source-owned range receipt. Arrival selection and
output-slew extrema are independent across every possible branch. Epoch/window
arithmetic is directed; an unproved integer epoch boundary is inconclusive rather
than selecting a favorable phase. Existing observed/point transfer behavior is
preserved when no range receipts are supplied.

## Strict Transform Admission

The parent Native state budget supplies the same optional caller transform ledger.
New plan arrays and symbol-compartment maps have concrete typed pre-growth leases;
shared original source binding arrays retain their existing owners instead of
being charged as copies. A plan or static-control result carries its immutable
anchors into the PathAnalysis owner. The mechanical Boolean evaluator's one
LogicBit buffer is admitted by its existing pre-allocation callback and released
after evaluation. Transfer candidate buffers are retained through completion.
Logical source-work charges already made to the original source accountant are
not duplicated by an additional ledger. Nil transform admission preserves legacy
behavior. No sequential or Boolean semantics are added by this accounting path.

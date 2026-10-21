# Distributed RC STA

## Purpose and Scope

Parent: [NativeExecution](../DESIGN.md). No children. Own the opt-in prescribed-
linear-ramp passive RC network response used by native data-path STA.

## Responsibilities and Boundaries

STARequest.distributedRC selects caller-owned finite time-grid, horizon, crossing
agreement, refinement, node and step ceilings. Nil retains equipotential scope.
The STAExecuting/STAExecutionPreparing requirements consume the same request.
The solver owns C dv/dt + Gv = b, exact source/sink attachment and measured wire
response; Liberty owns characterized cell delays, loads, slew and thresholds.
No drive resistance/current is inferred from NLDM. No CCS, dynamic aggressor waveforms or process qualification is claimed. Explicit primary clock composition belongs to [ClockPropagation](../ClockPropagation/DESIGN.md).

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Scenario composition | Native data paths | Explicit opt-in |
| [PathAnalysis](../PathAnalysis/DESIGN.md) | used by | Route arrivals and slew | Sink-specific responses feed receiver LUT/check | Separate cell/wire derates |
| [ParasiticReduction](../../../TimingCore/ParasiticReduction/DESIGN.md) | depends on | Preserved v3 SPEF source inventory | Exact finite R endpoints and CAP operator | Lumped evidence is not distributed evidence |
| [LibertyCodec](../../../TimingCore/LibertyCodec/DESIGN.md) | depends on | Owned source thresholds and selected corner | Driver output and receiver input thresholds | Pin-level overrides explicitly refused |
| [PreparedExecution](../../PreparedExecution/DESIGN.md) | coordinates with | Immutable source/config identity | Same source owner through execution | No reread or caller verdict |

## Architecture

```text
exact SPEF R/C + canonical pin bindings + selected Liberty source
 -> bounded nodal G/C (source row eliminated)
 -> characterized cell output slew scaled into prescribed linear source ramp
 -> backward-Euler solve, halve maximum step, compare sink threshold crossings
 -> sink arrival/slew -> next cell LUT or endpoint setup/hold/control check
 -> same source-bound per-corner wire observations + report
```

## Contracts and Invariants

Every distributed network binds one canonical driver and every receiver to explicit
SPEF CONN endpoints using the preserved delimiter; names are never guessed. Finite
positive R records form the actual operator, including parallel/looped topology.
Exact zero RES records impose ideal same-owner voltage equality. A bounded quotient
maps every original endpoint to a nodal class without changing source records or
terminal identity. Ground and receiver pin capacitances sum on classes; differential
CAP and positive RES whose endpoints share a class have zero incidence and remain
in the preserved source inventory. Multiple canonical drivers still fail, even if
shorted. All source endpoints count against node/work/state admission before quotient.
Driver-class receivers use exact analytical prescribed-source crossings, including
an all-ideal connected network, and retain distinct source/sink identities and an
explicit analytical observation method. Their evidence claims no grid or cycle solve.
Every other class must remain resistor-connected to the source. Empty RES without
explicit equality, zero grounded load on non-source classes, disconnected nodes, and cross-
net CAP are refused. Same-net two-terminal CAP remains differential in C.
Canonical net capacitance has no node attachment and is refused when nonzero on a
distributed network. Receiver pin capacitance is attached to its actual endpoint;
source pin capacitance is not invented. Driver cell load is the grounded total plus
actual receiver loads; internal differential CAP is not added as common-mode load.

Rising and falling source ramps have the actual selected driver output threshold
at time zero and the actual selected source slew between its lower/upper thresholds.
Each receiver uses its selected input threshold and slew thresholds; external ports
use the selected library boundary convention. Pin-level overrides/unsupported slew
derates fail explicitly. Falling solves normalized rising progress with complemented
voltage thresholds. Source output/receiver input thresholds remain distinct.

Backward Euler solves (G + C/dt) v_next = C v_prev/dt + b_next with exact
prescribed-source capacitive derivative terms. Dense Cholesky storage is admitted
against caller node and existing path-state ceilings before allocation. Factorization
and solves are charged to cumulative path work. Time samples stream into three
crossings per sink; complete histories are not retained. All requested sink crossings
must occur by the caller horizon. Two consecutive grids must agree in both arrival
and slew within caller absolute tolerance. This is observed numerical convergence,
not certified physical error. The caller owns these operational values; changing
them changes configuration identity and requires new evidence.

Incremental wire delay alone receives early/late wire derates. Cell delays retain
cell derates. Sink waveforms feed the next cell's actual input-slew lookup and
sequential checks. Reconvergent route records stay separate. Capture/launch clock nets carrying finite distributed R require the explicit [ClockPropagation](../ClockPropagation/DESIGN.md) source and topology contract. All requested exact corners execute independently; one failure publishes no
partial completed report. Native algorithm 3.6/configuration v6 prevents old cap-only
configuration evidence from being accepted as distributed evidence.

## State, Ownership, and Lifecycle

Every network and response belongs to the run-local scenario owner. Immutable
source inventory and selected Liberty source remain retained by PreparedSTAExecution.
No global cache, shared mutable state, unsafe pointers or target branch is added.

## Failure, Concurrency, and Constraints

Caller node and cumulative step ceilings, existing path work/state ceilings and
finite arithmetic bound execution. Grid refinement exhaustion, incomplete crossing,
singular/nonfinite solve, unrepresentable grid, missing endpoint and unsupported
semantics fail with typed TimingError or STAPathAnalysisError and no report. Task
cancellation is checked at grid steps and cumulative work checkpoints.

## Verification and Change Impact

STADistributedRCTests verifies one-pole and two-section analytical responses,
resistance and topology sensitivity at equal total C, source/receiver thresholds,
rise/fall and independent wire/cell derates, exact-corner separation, source/sink
refusal, horizon/convergence/budget/cancel failures and report reconstruction. Actual
Timing CLI proof reloads the report with exact same candidate/SPEF identities. Host
consumers own required-corner selection and stale candidate/evidence rejection;
engine opt-in tests alone do not close the system GP3 goal.

Ideal-short tests preserve zero RES/source IDs through codec round-trip, compare
summed class capacitances with an independent one-pole reference, retain separate
receivers on one class, exercise exact source-following rise/fall/periodic thresholds,
and reject conflicting drivers, cross-owner equality, disconnected classes and
node/work/state exhaustion. No epsilon resistance or terminal-name collapse is used.

## Required Coverage Admission

Each canonical physical net has explicit distributedRC, propagatedClock, idealClock, uncovered or
staticNoTransition coverage per mode/corner. Uncovered nets retain the legacy ideal
propagation only as partial model scope; completion is not complete routed coverage.
Every provided network needs exact RES topology. No cap-only connection is inferred.
STADistributedCoverageValidating consumes host-owned required net/corner lists and
the exact original STARequest. StrictSTADistributedCoverageValidator refuses missing,
ideal, static or uncovered required dynamic nets, missing actual wire observations,
missing corners, changed candidate/source bindings and changed actual configuration.
Payload decoding checks coverage/observation self-consistency; authoritative required
scope is never reconstructed from the report's own possibly omitted entries. Rehashed
omission of both coverage and observations still fails the external required scope.
This check is completeness/binding, not authenticity or qualification authority.

Periodic clock response preserves both actual source ramp phases and rise/fall slew.
It retains observed cycle-to-cycle convergence separately from grid agreement and
shares the same cumulative node/storage/step/work limits as the isolated data profile.
The source waveform is prescribed from characterized timing; no current/drive
resistance or settled initial periodic state is invented.


## Strict Transform Payload Ownership

The original scenario `NativeSTAStateBudget` supplies optional transform
accounting. Concrete nodal Double matrices/vectors, typed alias/neighbor maps and
sets, grid/factorization scratch, caches and observations are admitted before
construction or growth, independently of existing logical slots. Network and
response owners retain live payload; temporary solve buffers retain lexical
leases until their final use. Old and replacement buffers coexist in admission.
No path-state ceiling is converted through a guessed maximum stride.

Every existing numerical work batch also reaches that same cumulative transform
accountant and its cancellation/deadline checks. Nil-accountant behavior and
backward-Euler arithmetic, ordering, thresholds and convergence guards remain
unchanged. Tests extend `NativeStrictNumerical` coverage with actual RC response,
capacity/cancellation refusal and final-owner cleanup. The selected Native
qualification and finding-limited recheck passed within the
[PreparedExecution scope](../../PreparedExecution/DESIGN.md#strict-native-qualification-scope);
this component grants no additional physical authority.

### Concrete Buffer Lifetimes

| Owner | Payload | Release boundary |
|---|---|---|
| Immutable network anchor | G/C, source vectors, exact alias/index tables and generated pin-name bytes | Last network/scenario or published result anchor |
| Scenario snapshot | Network table, response tables and observation array | Last snapshot/result anchor; replacement admits old and new simultaneously |
| Per-network construction | Driver/sink tables, quotient and adjacency, sorted node lists, BFS | End of that network construction |
| Per-solve workspace | Writable operator, factors, voltage pair, thresholds, crossings and periodic events | Last lexical use, including exceptional exit |

Controlled construction reserves concrete element capacities before populating
arrays, dictionaries and sets. Source incidence counts bound the initial table
capacities; concrete typed hash-table sizing belongs to TimingTransformCapacity.
Nested adjacency arrays use an independently counted degree per class. Their
payloads are admitted before the corresponding array is created. Numerical
vectors use two independent writable buffers in the controlled path; swapping
these buffers preserves each step's arithmetic and avoids retaining historical
COW allocations. The legacy nil path retains its original assignment operations.
Shortened-step factors and their writable matrices coexist with the full-step
factor only until that step finishes.

Caches and observations publish a fresh immutable backing after admission. A
copied scenario keeps the prior lease and prior backing; mutation never replaces
a lease shared with that copy. Network anchors cover only retained payload, not
construction scratch. The result composition retains the distributed owner's
`transformRetention`; extracting a bare observation array does not independently
transfer accounting ownership. Source Strings borrowed from the prepared inputs
continue to require the enclosing prepared-source owner. These are logical
payload bounds, not allocator buckets, Foundation workspace or process RSS.


### Source-Name Failure Ownership

The controlled DistributedRC boundary prepays its concrete terminal diagnostic
metadata through the same state-budget transform accountant. Before constructing
an unsupported-semantic message from net, endpoint or receiver names, it admits
the exact UTF-8 sum of the unchanged literal fragments and source fields, then
constructs the original TimingError lazily. The thrown controlled failure retains
that cause, the admitted text and original parasitic source owner across copies;
the final error copy releases the associated live admission. Resource/work/cancel
refusals propagate unchanged, and unwind returns any already acquired leases.
Nil-accountant construction and the original semantic text remain unchanged.
The controlled source-threshold refusal uses the canonical existing
TimingCharacterizationError.errorDescription through the source-owned scoped
formatter in [LibertyCodec](../../../TimingCore/LibertyCodec/DESIGN.md). Its
intermediate description and numeric text are admitted before formatting. The
controlled semantic text deliberately replaces Optional/enum reflection while
retaining the same unsupported reason and source facts; the nil-accountant path
keeps its original String(describing:) bytes. No threshold acceptance changes.

The source-rich CAP-only regression in NativeStrictDistributedPayloadTests uses
an actual parsed schema-three SPEF with a long canonical net name. It checks the
original legacy refusal, pre-construction live/work/cancellation refusal, zero
scratch capacity, retained cause identity and last-error-copy refund. These cases
qualify failure ownership rather than a new RC topology or numerical profile.

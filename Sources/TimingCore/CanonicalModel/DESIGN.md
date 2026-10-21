# CanonicalModel

## Purpose and Scope
Own explicit physical timing connectivity and canonical admission. Parent: [TimingCore](../DESIGN.md). No children.

## Responsibilities and Boundaries
Own TimingDesign values/codec and cross-input canonical validation. Cell functions,
Liberty grammar, timing propagation and release authority belong to their owners.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingCore](../DESIGN.md) | parent | Canonical values | Value/codec boundary | Host only |
| [NativeExecution](../../STAEngine/NativeExecution/DESIGN.md) | used by | Validated port/net and constant facts | Actual STA | No implicit driver substitution |

## Architecture
```text
TimingDesign JSON -> explicit schema import -> port-to-net / constant facts
  -> canonical design/constraint/library validation -> Native STA
```

## Contracts and Invariants
TimingDesign v2 separates port identity from physical net identity (`netName`).
An absent port net retains the legacy same-name connection. Nets may carry binary
zero/one drivers. Constants cannot also have input or cell-output drivers. Multiple
input aliases to one physical net and conflicting clocks are invalid; output aliases
remain independent constraint endpoints. Explicit port nets must exist. Each cell
pin resolves with its declared direction; connected drivers are unique.
Version 1 imports only when new connection/constant fields are absent. Imported
values use v2 and encode v2; unknown versions or v1 carrying new semantics fail.
The Verilog timing parser retains its documented structural subset; Runtime's
actual-cell Verilog codec remains the independent netlist/proof owner.

## State, Ownership, and Lifecycle
Immutable copies during native preparation; validation workspace is invocation-local.
No shared mutable state or pointer escapes are added.

## Failure, Concurrency, and Constraints
Malformed schema, missing connections, driver conflicts and contradictory clock
sources fail before STA. Input and element ceilings belong to STA preparation.

## Verification and Change Impact
[STAConnectivityTests](../../../Tests/TimingEngineTests/STAConnectivityTests.swift)
owns schema import, alias/driver/clock conflicts and round-trip behavior. Native STA,
Runtime and the scalar-reference profile must recheck any connectivity change.

Signal-integrity canonical admission validates design identities/connectivity,
mode constraints and the exact SPEF owner-net join without inventing a timing
library or claiming cell functional validation. External root aggressors must be
design-known but need not declare a D_NET. Empty/unknown scopes fail. The SI module
owns PDK process validation, effective configuration and numerical observations.

Controlled structural text intake uses the same Verilog grammar and source token
ordering, with concrete token/port/instance/net/hash-table capacities admitted
before construction. Each concatenated connection net reserves only its actual
source-token UTF-8 total, not a shared statement bound for every net. Complete
result handles retain source text/collection leases and source-derived rich
failures retain the same owner. Legacy parsing remains the nil-control branch.
Controlled JSON uses the host audited schema decoder; no second JSON parser or
source authority is introduced. Selected Native strict qualification is recorded
in [PreparedExecution](../../STAEngine/PreparedExecution/DESIGN.md#strict-native-qualification-scope).

## Controlled Canonical Validation

The existing nonthrowing validator and additive controlled overloads execute one
private rule body. A private `rethrows` construction callback is the only fallible
seam: legacy supplies a genuinely nonthrowing nil-receipt callback; controlled
validation checks concrete type/count/UTF-8 events against the same accountant.
No catch, trap, alternate rule implementation or post-hoc usage transfer bridges
these APIs. Findings, their order, codes, summaries and entity identities remain
those of the original rule body.

```text
original values -> same rule body -> construction event before allocation/work
                                    -> typed scratch receipt (lexical lifetime)
                                    -> current findings backing + retained text
                                    -> TimingTransformValue report owner
```

Array projections/concatenations, typed sets and dictionaries, endpoint expansion,
selector flattening and deletion-only name trimming admit their actual source
counts before construction. Checked addition/multiplication belongs to the
fallible callback; the semantic body never formats an arithmetic refusal or
performs speculative allocation. Every loop and source-text inspection reaches
that same callback. Returned private payloads carry their scratch receipt through
their last consumer; copies do not create a second quota or reset work.

Primary-clock waveform validation charges its actual waveform elements.
Generated clocks carry only source/master identities and scalar ratios; their
validation does not invent a waveform traversal. The existing valid-entry test
covers both primary-only and generated-clock inputs against the legacy rules.

The text anchor stores its Mutex and metadata lease in one noncopyable inline
state. Admission uses that actual state's stride as a byte count, rather than
a tuple containing a noncopyable Mutex or the class reference's pointer stride.
The same Mutex owns every text write, and the anchor retains its metadata lease
until the report or failure owner releases its last reference.

Findings grow in an unpublished invocation-private array. The new backing is
admitted while the old receipt remains alive, then the old receipt is released.
Only the current backing receipt transfers at report publication. Source-derived
joined diagnostic text is admitted from literal and field UTF-8 extents before
construction and remains retained with the whole report. Controlled failure uses
the shared prepaid failure owner without callbacks after failure. Borrowed input
values and their original anchors remain caller-owned; detached report values
require retaining the complete transform handle through all copies.

Logical payload excludes Foundation-private workspace and allocator buckets and
is not an RSS ceiling. `NativeStrictCanonicalValidatorTests` covers actual valid
and malformed design/constraint/library/parasitic findings against legacy,
resource/callback refusal and result/failure copy lifetimes. Combined focused
qualification and the scoped transform review passed within that finite scope.

Derived diagnostic Strings use one private pre-admitted text anchor. Both its
payload receipt and holder/registration metadata are admitted before String
construction. The private produced-text event installs the actual String into
that already retained anchor with no cancellation/work/storage callback; a later
failure therefore retains actual backing and its receipt, not an unallocated
text estimate. Scratch payload wrappers have separately admitted concrete fields.

| Logical state | Native / WASM / Embedded source storage | Mutation / release |
|---|---|---|
| Produced-text anchor | Identical `Mutex<String?>`; no target conditional | Private synchronous completion under the mutex; enclosing retained parse owner releases |
| Construction callback context | Invocation-confined private context, never published or Sendable | One synchronous caller; only immutable anchors escape |

TimingCore remains a host/available-Foundation target; these identical source
contracts grant no new WASM/Embedded runtime capability. Target qualification is
limited to the actual combined build/runtime evidence.

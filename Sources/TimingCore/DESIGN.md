# TimingCore

## Purpose and Scope

Own canonical timing values, parsers and characterized load/slew evaluation.
Parent: [TimingEngine](../../DESIGN.md). Children:
[LibertyCodec](LibertyCodec/DESIGN.md), [ParasiticReduction](ParasiticReduction/DESIGN.md),
[CanonicalModel](CanonicalModel/DESIGN.md), [PathConstraints](PathConstraints/DESIGN.md),
and [NumericBounds](NumericBounds/DESIGN.md).

## Responsibilities and Boundaries

[LibertyCodec](LibertyCodec/DESIGN.md) owns the single Liberty grammar and source admission. The strict
characterization profile accepts selected cells from Liberty text only, separating
capacitance-only sink cells from propagation cells. Evaluation is permitted only
for the explicit propagation-cell subset. CTS owns
source integrity, corner selection, sink connectivity, RC and arrival propagation.

Owned Liberty functional projection is also defined by LibertyCodec. It preserves
original function/sequential facts for the host logic-library compiler, without
deriving them from timing models or granting mapping eligibility.
Source-defined sequential model/binding and positioned numeric source identity
are owned by the same [LibertyCodec contract](LibertyCodec/DESIGN.md#source-defined-sequential-models).
Legacy single-pin views are optional; downstream execution must distinguish the
explicit source/legacy definition before selecting a sequential algorithm.
SPEFParser owns standard SPEF name expansion and node-to-net ownership before
publishing TimingParasitics. It does not interpret exporter-private identity
annotations or depend on extraction implementations. Canonical JSON and the
ordinary STA parser contract do not prove source presence.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingEngine](../../DESIGN.md) | parent | Domain timing ownership | Canonical values | No qualification claim |
| [LibertyCodec](LibertyCodec/DESIGN.md) | child | Shared grammar and owned source parsing | Actual source/facts and neutral accounting | No named process interpretation or artifact authority |
| [NumericBounds](NumericBounds/DESIGN.md) | child | Package-only outward interval arithmetic | Source ranges and STA certificates | Finite enclosures; no physical source authority |
| [STAEngine](../STAEngine/DESIGN.md) | used by | TimingLibraryParsing | Existing STA intake | Ordinary parsing is not strict characterization |
| [PhysicalDesignEngine](../../../PhysicalDesignEngine/DESIGN.md) | used by | TimingCharacterizationParsing | CTS numerical evaluation | Require exact selected source and checked queries |

## Architecture

```text
Liberty bytes -> LibertyGrammar -> LibertyParser
  -> ordinary parse -> TimingLibrary -> Native STA
  -> strict selected-cell admission -> CharacterizedTimingLibrary
       -> pinCapacitance / evaluate -> existing TimingLUT interpolation
```

## Contracts and Invariants

Liberty grammar, ordinary numerical semantics, CTS admission, and owned source
accounting are defined by [LibertyCodec](LibertyCodec/DESIGN.md).

SDCParser admits only the global input-transition profile
`set_input_transition <finite-positive-time> [all_inputs]` without flags. The
collection contains exactly the `all_inputs` command and no arguments; whitespace
inside it is permitted. Time uses the parser's finite positive defaultTimeUnit
(default ns), or existing explicit fs/ps/ns/us/ms/s suffixes, and must remain finite
and strictly positive after Double parsing and SI conversion. Zero, negative,
nonfinite and underflowed values are typed parse failures. Flags, named subsets,
collection options, extra arguments and other object forms are typed unsupported.
Each accepted command sets the existing defaultInputSlew; repeated commands use the
last accepted global value, retaining mode identity. The optional explicit source
fact and backward-compatible JSON contract are owned by
[PathConstraints](PathConstraints/DESIGN.md#contracts-and-invariants).
Native STA seeds both edges of every input and bidirectional port from this value;
internal nets use propagated library output transitions. The scalar reference
analyzer's existing reuse of the default at each stage is a separate model and only
single-stage agreement is claimed. SDC value admission does not change the Native
STA evaluator, so producer 2.0.0/schema v3 remain; the exact executable and constraint
artifact digests bind the changed admission implementation and inputs.

SPEF admission expands complete NAME_MAP references and mapped prefixes using
one explicit DELIMITER (default `:`). D_NET names retain exact canonical net
identities. CONN P/I/N entries associate complete expanded endpoint identities
with their enclosing D_NET; an internal endpoint with a numeric suffix is owned
by its exact declared net prefix. Exact net identities remain valid endpoints.
Resolution considers all declared networks and connections after the entire
source is read, allowing forward coupling references. Multiple contradictory
connection owners, competing exact-net/internal-node/connection interpretations,
unknown map references, duplicate networks, and unresolved scoped endpoints fail with
TimingError.spefOwnership(TimingSPEFError), preserving the native engines' blocked
input classification. No prefix guessing or exporter-specific pin decoding is used.
Escaped delimiter characters are part of an identity and cannot split a node.

TimingParasitics v2 retains source inventory: complete CAP endpoints/owners/values,
physical source identifiers, finite D_NET declared capacitance and resistance
inventory. Decimal parsing and SI conversion must retain every representable positive value. A nonzero decimal significand that Double parsing rounds to zero is refused; a zero significand remains zero regardless of exponent. SI conversion requires: a positive CAP, D_NET declaration, resistance entry or unit factor whose conversion overflows or becomes zero fails with its physical input line. Literal zero CAP/declarations/resistance remain valid. Ground CAP ownership is checked as strictly as two-terminal endpoints.
Same-net two-terminal CAP records are retained; they are not inter-net coupling.
Schema v1 JSON is rejected rather than reconstructed into invented endpoints.
An unscoped external root may be absent from partial D_NET coverage; canonical
logical validation owns checking that identity against the design.

[ParasiticReduction](ParasiticReduction/DESIGN.md) owns the separate explicit
cap-load approximation, derived load values and loss/mirror/declaration evidence.
No parser declaration is an effective terminal load. Source storage and canonical
JSON preserve every raw record, including same-net and mirrored listings.

## Runtime Flows

Parse once, resolve selected cells and source facts, normalize existing LUT values,
then evaluate repeatedly using immutable admitted data. Unknown cells/pins, missing
or ambiguous arcs and unsupported data produce typed characterization errors.

## State, Ownership, and Lifecycle

Invocation-local immutable parsed value state. Artifact storage additionally owns
per-operation host descriptors and scoped pointer borrows as described below. It
adds no shared mutable cache or target-specific isolation.

## Failure, Concurrency, and Constraints

Typed source/semantic/ambiguity/range failures propagate to the caller. Ordinary
parser size-dependent work has no whole-invocation byte accounting guarantee.
The owned Liberty contract and its explicit bounds belong to LibertyCodec. This host Foundation module
claims macOS behavior only; no WASM/Embedded capability is implied.

## Verification and Change Impact

[SPEFParserOwnershipTests](../../Tests/TimingEngineTests/SPEFParserOwnershipTests.swift)
checks literal scoped exporter tokens, name maps, forward pin ownership, custom
and escaped delimiters, exact root identities, conflicting/ambiguous/unknown
ownership, partial root/net coverage, and independent SI numeric values. Native STA
composition and genuine extraction export are verified by their integrating owner.

[LibertyCharacterizationTests](../../Tests/TimingEngineTests/LibertyCharacterizationTests.swift)
checks literal independent rise/fall values, unit scaling, inherited/overridden and
transposed indexes, missing source facts, unsupported/ambiguous semantics, malformed
axes/matrices, singleton axes and exact/outside range behavior.
Literal Sky130 rows also cover LF/CRLF continuations, diagnostic physical lines,
and rejection of a non-continuation backslash through both parser profiles.
TimingCore parser, Native STA and process/corner tests own composing regression behavior. CTS tests
must separately prove actual source binding, RC loads and per-edge propagation.

[SDCInputTransitionTests](../../Tests/TimingEngineTests/SDCInputTransitionTests.swift) owns global transition units, positive SI admission, options/subset refusal and mode/last-value behavior. NativeEngineTests.inputTransitionSeedsAndPropagatesSlew proves actual per-edge input/bidirectional initialization and two-stage internal propagation with independent LUT numbers.

[CanonicalModel](CanonicalModel/DESIGN.md) owns TimingDesign v2 explicit port/net and binary constant admission.

Native source-bound sequential checks are owned by [LibertyCodec](LibertyCodec/DESIGN.md#source-bound-sequential-timing-checks); ordinary propagation LUT evaluation remains unchanged.

Distributed-source schema v3 extends preserved SPEF inventory with exact resistor
endpoints, connection declarations and pin delimiter. The
[ParasiticReduction contract](ParasiticReduction/DESIGN.md#distributed-source-preservation)
owns its admission and compatibility; legacy v2 retains only its explicit cap-load capability and must be reparsed for distributed analysis.

[PathConstraints](PathConstraints/DESIGN.md) owns explicit primary source waveform/transition/propagated facts. [LibertyCodec](LibertyCodec/DESIGN.md) retains clock-to-Q edge source presence. [STA ClockPropagation](../STAEngine/NativeExecution/ClockPropagation/DESIGN.md) consumes those facts without introducing clock execution policy into TimingCore.

[LibertyCodec](LibertyCodec/DESIGN.md) owns caller-accounted strict characterization from scoped source bytes and actual clock-to-Q source edge presence. Existing ordinary lookup remains unchanged.

## Contained Immutable Artifact Storage

TimingCore owns `FileSystemTimingArtifactStore`; the native analysis engine does
not own output filesystem policy. The CLI's optional contained `--out` and the
public store constructor accept existing or not-yet-created output directories.
An existing workspace may use a filesystem alias. The original public roundtrip
also permits creation of one missing workspace directory below an existing parent;
no additional missing-workspace-parent capability is claimed.

The constructor resolves the nearest existing ancestor through the platform's
canonical path operation and appends missing directory components. Workspace and
output are normalized by the same rule before root-relative admission. Caller
pre-normalization is not required. Content identity, descriptor, root ID and
relative availability schema remain unchanged.

```text
admitted workspace/output URLs -> immutable canonical relative components
store(Data) -> scoped no-follow workspace descriptor
  -> no-follow output/run directory traversal and bounded creation
  -> exclusive temporary regular file -> complete bytes
  -> atomic no-replace publication -> checked cleanup/close -> exact binding
```

Each store call owns its descriptors; store copies share no mutable descriptor or
cache. All directory traversal is descriptor-relative and no-follow before any
creation or write. An output/run/final symlink introduced after construction is a
failure, without following it to create an outside directory or artifact. The
operation anchors the opened workspace capability; it does not claim protection
against an actor renaming the capability's own underlying directory namespace.
The existing published CF FileSystem owner provides read/discovery only and has no
public writing or root-descriptor API. Timing uses its existing reader unchanged
and keeps only the necessary private host write operations in this store.

Publication cannot replace an existing artifact. The same exact regular-file
bytes are idempotent; different bytes or a nonregular/symlink final entry fail.
An exclusive private temporary file is removed on failure/cancellation and after
publication. Descriptor and cleanup failures remain observable, including a
primary failure followed by a cleanup failure. A successful no-replace publication
is the commit point; cancellation is checked before mutation, during bounded
writes/comparison, and immediately before this point. Cancellation after the
commit point does not relabel an already published artifact as uncommitted.

Directory work is linear in admitted path components and byte work in input size.
Only scoped descriptors and a fixed-size comparison buffer are added; the input
Data is borrowed during writes and is not rematerialized. This public store has
no new invocation-wide resource-budget claim or platform scope beyond the
existing host implementation.

[TimingArtifactStoreTests](../../Tests/TimingEngineTests/TimingArtifactStoreTests.swift)
owns missing alias/nested output and established missing-workspace compatibility,
escape admission, post-init output/run/final symlink drift without outside effects,
immutable replay/conflict and concurrent publication, pre-cancellation cleanup,
and public-reader roundtrip. Original immutable and output-symlink tests remain.
The actual public CLI missing-output failure and actual public post-init drift
receipt are the pre-fix counterexamples. Only this artifact path and its API/CLI
save/reload consumer require requalification; no timing numerical model changes.

Child [SourceTransforms](SourceTransforms/DESIGN.md) owns additive controlled artifact intake and paired byte retention. Its capability does not remove Native strict-transform refusal before all transform owners are wired.

### Characterized Matching During Controlled Native Execution

`CharacterizedTimingLibrary` resolves checks, propagation/control arcs, source
tables and pulse laws by ordered count/first scans over retained source arrays.
No matching array is materialized. Fixed two-coordinate/rise-fall validation
uses ordered scalar calls, and the singleton zero axis uses a direct count/value
condition. Each scan spends the existing source
accountant before examining its next element; missing/duplicate classifications,
source identities, lookup operands and point/range arithmetic remain unchanged.
`LibertySourceSampleTests`, `CharacterizedRangeEvaluationTests` and
`LibertyPulseWidthTests` own the affected source evaluation behavior. The Native
strict transform tests compose those same owners with the cumulative payload
ledger; this change grants no new characterization or source-family authority.

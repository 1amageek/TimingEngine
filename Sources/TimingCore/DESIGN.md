# TimingCore

## Purpose and Scope

Own canonical timing values, parsers and characterized load/slew evaluation.
Parent: [TimingEngine](../../DESIGN.md). Children:
[LibertyCodec](LibertyCodec/DESIGN.md) and [ParasiticReduction](ParasiticReduction/DESIGN.md).

## Responsibilities and Boundaries

[LibertyCodec](LibertyCodec/DESIGN.md) owns the single Liberty grammar and source admission. The strict
characterization profile accepts selected cells from Liberty text only, separating
capacitance-only sink cells from propagation cells. Evaluation is permitted only
for the explicit propagation-cell subset. CTS owns
source integrity, corner selection, sink connectivity, RC and arrival propagation.
SPEFParser owns standard SPEF name expansion and node-to-net ownership before
publishing TimingParasitics. It does not interpret exporter-private identity
annotations or depend on extraction implementations. Canonical JSON and the
ordinary STA parser contract do not prove source presence.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingEngine](../../DESIGN.md) | parent | Domain timing ownership | Canonical values | No qualification claim |
| [LibertyCodec](LibertyCodec/DESIGN.md) | child | Shared grammar and owned source parsing | Actual source/facts and neutral accounting | No named process interpretation or artifact authority |
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
last accepted global value, retaining mode identity. No IR/schema fields are added.
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

Invocation-local immutable value state. No shared mutable cache, pointer or
platform-specific isolation is added.

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

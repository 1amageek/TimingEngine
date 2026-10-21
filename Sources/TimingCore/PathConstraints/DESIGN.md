# PathConstraints

## Purpose and Scope
Own SDC constraint values and the admitted grammar. Parent: [TimingCore](../DESIGN.md).
No children. TimingConstraintSet schema v2 explicitly imports v1 only without path
exceptions; old string selectors cannot be promoted to typed exception evidence.

## Responsibilities and Boundaries
Parse clocks, I/O delays and typed path selectors. Own numeric, scope and option
validation. Native execution owns resolution against the design and path evaluation.
No Tcl interpreter, source acquisition or functional proof is owned here.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingCore](../DESIGN.md) | parent | Canonical timing values | Host codec owner | No portable kernel dependency |
| [PathAnalysis](../../STAEngine/NativeExecution/PathAnalysis/DESIGN.md) | used by | Typed exception facts | Exact route checks | No ignored option implies support |
| [CanonicalModel](../CanonicalModel/DESIGN.md) | coordinates with | Cross-input validation | Numeric admission | Selector resolution belongs to execution |

## Architecture
```text
SDC bytes -> strict options/collections -> typed from / ordered through / to
  + setup/hold scope + start/end reference -> validated schema-v2 constraints
```

## Contracts and Invariants

`TimingConstraintSet.inputTransition` is an optional explicit source fact. Its
`InputTransition.allInputsBothEdges(slew:)` case owns exactly the currently admitted
global `[all_inputs]`, both-edge, unqualified min/max transition profile and its
positive SI value. Only a successfully parsed strict `set_input_transition` command
sets this fact; repeated commands replace it together with `defaultInputSlew`.
Named subsets, edge/min/max flags and collection options remain typed unsupported,
so their scope is never widened. API callers can explicitly supply the same typed
declaration. An absent fact stays nil, including decoding old schema-v1/v2 JSON;
the schema version and ordinary default slew behavior remain unchanged. Certified
consumers must reject nil, nonpositive/nonfinite values and disagreement with the
executed default slew. A default numeric value alone grants no source authority.

Support false path, multicycle, max delay and min delay with from/to port, pin,
clock or instance selectors; ordered through groups accept pins, nets or instances.
Each group is an OR set; successive groups are ordered AND stages. Glob * and ?
match complete names; square brackets in bus names are literal. Empty/unmatched
selectors, malformed numeric values and unsupported options fail explicitly.
Bare names resolve uniquely within the role's legal object kinds. Typed collections
preserve object kinds and alias identity. Internal from/to pins that cut a path,
transition-specific flags, reset_path/probe and Tcl evaluation are outside this profile.

False path defaults to both checks and accepts setup/hold scope. Multicycle defaults
to both with an end-clock setup multiplier and zero hold multiplier; explicit hold
uses the start clock by default. Start/end is retained independently of scope.
Hold multiplier zero is valid; setup multiplier is positive. Max/min delays are
finite nonnegative. Conflicting scope/reference flags fail. Unqualified I/O delay
applies to both min and max; explicit flags select one. Negative I/O delays are legal.
Repeated I/O values replace the same port/clock/min-max role, matching SDC overwrite
semantics; unsupported edge/add-delay flags fail rather than collapse to one value.

Semantics reference: [OpenSTA command reference](https://opensta.readthedocs.io/en/latest/Commands/)
and its upstream multicycle edge definitions. This native profile does not claim
full SDC or OpenSTA qualification.

## State, Ownership, and Lifecycle
Parsing uses invocation-local buffers. Published constraints are Sendable values;
prepared execution retains immutable copies. No shared state or unsafe views.

## Failure, Concurrency, and Constraints
Source-intake ceilings bound parsing. Invalid syntax uses source-line parse errors;
unsupported options use typed unsupported semantics. No default multiplier fallback.

## Verification and Change Impact
STAPathExceptionTests owns parser numeric/selector/scope/refusal and schema round-trip
regressions. Native PathAnalysis, prepared configuration, database codec and Runtime
receipt replay must be rechecked when the admitted facts change.
`LibertyCodecTests/SDCExplicitSourceTransitionTests.swift` owns absent-versus-explicit
transition source facts, last assignment, scope refusal, API declaration and legacy
JSON compatibility. STA owns conservative execution refusal and source-slope joins.

## Explicit Propagated Primary Source Facts

Clock retains optional sourceRiseTransition/sourceFallTransition and isPropagated. Legacy JSON defaults only isPropagated=false; missing transition facts remain nil. set_clock_transition accepts a positive common value or exactly one -rise/-fall flag and exact get_clocks targets. set_propagated_clock accepts exact primary get_clocks targets. Unknown/ambiguous targets and unsupported options fail. create_clock waveform parsing validates every token rather than dropping malformed values. Propagated clocks require explicit two-edge phase and both source transitions; ordinary empty waveform retains its prior ideal convention. Generated clocks and latency commands remain unsupported for propagated execution.

set_clock_uncertainty admits one finite nonnegative scalar and exact primary get_clocks targets. Unsupported per-edge/from/to profiles fail explicitly; unknown targets are never ignored. Propagated source ports must be actual input ports.

## Controlled SDC Construction

The additive `SDCParser.parse(_:modeID:resources:)` consumes the same admitted
UTF-8 grammar and returns the existing `TimingTransformValue` whole-owner handle.
The ordinary overload selects no accountant and retains its legacy source errors,
numeric conversions, command ordering and overwrite behavior. No Tcl evaluation,
new decoder or source-profile restriction is introduced.

```text
caller Data + one accountant
 -> admitted UTF-8 source and borrowed line ranges
 -> counted token/collection String payloads and typed temporary arrays/sets
 -> private constraint arrays with admitted capacity replacements
 -> whole constraint value + retained storage anchor
```

Tokenization identifies the existing quote/bracket/brace boundaries before
materializing each token; UTF-8 bytes and slots are admitted before creation.
Deletion-only Foundation transforms admit their source byte extent. Unicode case
mapping uses the source-proved fixed-toolchain sizing in SourceTransforms, with
input, scalar scratch and mapped output coexistence. Typed map/filter/set helpers
admit concrete element/hash capacity and visit work before population.

The invocation does not copy/publish `TimingConstraintSet` until construction
finishes. Its array admissions track each current private backing separately;
growth admits old and replacement capacities before copying, then drops the old
receipt. Delay removal and clock-field updates operate on this unpublished unique
backing. Final publication transfers only current array receipts to parse storage.
All token/derived String owners required by those values are retained by that same
storage. Temporary line/selector/numeric workspace is released at publication;
failed construction drops its private arrays without refunding cumulative work.

Source diagnostics use the shared lazy diagnostic seam: literal and actual field
UTF-8 bytes are admitted before interpolation/concatenation, and the outer typed
failure retains the original error and parse owner without post-failure callbacks.
Resource/cancellation causes remain inspectable and are never mistaken for source
syntax. The caller must retain the complete transform handle (or failure) while
using copies/extracted values; bare `TimingConstraintSet` copies do not acquire a
new accounting anchor. Bounds describe logical managed payload, excluding private
Foundation workspace and allocator buckets, and do not claim a hard RSS ceiling.

`NativeStrictSDCParserTests` owns controlled/legacy value and diagnostic parity,
Unicode/collection and overwrite behavior, pre-growth refusal, callback cancel,
copy/final-anchor release and retained failure lifetime. The selected focused
Native build/runtime and scoped review passed within the
[PreparedExecution scope](../../STAEngine/PreparedExecution/DESIGN.md#strict-native-qualification-scope).

Generated clock ratio options distinguish absence from invalid source text.
Absent `-divide_by` and `-multiply_by` each default to one. Present options require
an actual following integer token; missing/non-integer values produce typed
source-line parse failure. Parsed nonpositive integers retain the existing
positive-ratio refusal. Valid integer spellings and resulting ratios are unchanged.
This closes the former present-invalid-to-one implementation fallback rather than
adding a generated-clock execution capability.

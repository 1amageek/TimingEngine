# Liberty Codec

## Purpose and Scope

Own the single Liberty grammar, ordinary library conversion, strict CTS source
characterization, and caller-accounted source intake. Parent:
[TimingCore](../DESIGN.md). No children. Ordinary API semantics remain unchanged.
The owned source API requires PN5.2 behavioral verification before domain use.

## Responsibilities and Boundaries

`LibertyParser` conforms to the ordinary parsing/characterization protocols and
the neutral `LibertySourceParsing` protocol. The owned entry accepts a scoped
`Span<UInt8>`, explicit `LibertySourceParseLimits`, and trusted
`LibertySourceResourceAccounting`. It produces `OwnedLibertySource`: one immutable
library plus original cell/pin and raw operating-condition observations, retaining
all live payload receipts. It does not establish artifact identity, named process
or nominal-corner meaning, qualified PVT, engine execution, or PDK admission.
Caller exact source capture and optional PDK bridges remain outside this codec.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingCore](../DESIGN.md) | parent | Timing IR and lookup | Codec owner | Ordinary and CTS numerical semantics remain distinct |
| [ProcessCorners](../../STAEngine/ProcessCorners/DESIGN.md) | used by | Exact manifest/source selection | Future owned intake | Raw numeric process is not a named PDK process |
| [PDK admission](../../../../PDKKit/Sources/PDKProfileAdmission/Admission/DESIGN.md) | coordinates with | Source facts and external accounting bridge | Future optional adapter | No direct dependency or caller-supplied success authority |

## Architecture

```text
Data ordinary entry --------------------------+
Span owned entry -> UTF-8/capability admission +-> one lexer/group grammar
      resources + explicit limits             -> one library/table conversion
                                               -> ordinary library / CTS value
                                               -> immutable owned library + facts
```

## Contracts and Invariants

- `LibertySourceParsing.parseSource(_:limits:resources:)` returns an internally
  constructed non-Codable owner. No public unchecked owner constructor exists.
- Accounting is caller-neutral: `check()`, `chargeWork(_:)`, and
  `reserveStorage(kind:byteCount:)` are protocol requirements. Shared state in an
  external accountant must be synchronized. Errors preserve the original typed
  external cause in `LibertySourceError.resource(any Error)`; cancellation,
  deadline, arithmetic overflow, invalid capacity, syntax, and unsupported source
  semantics remain explicit. The codec never closes an external accountant.
- `LibertySourceStorageReservation` is an externally constructible immutable
  receipt with kind, byte count, and a Sendable release callback. Copies share one
  exactly-once release owner. A receipt grants no source or result authority.
- Managed capacity means concrete element stride times admitted logical capacity,
  plus UTF-8 payload bytes and actual private owner fields. Runtime/allocator
  headers, native container bucket overhead, alignment padding outside stride,
  process RSS, and Swift allocator rounding are excluded. Token count is work;
  it never substitutes for a byte reservation. Checked multiplication/addition
  precedes every capacity, growth, copy, and materialization.
- Variable collections grow geometrically under a new reservation before
  allocation. Shared snapshot writes reserve and clone even when spare capacity
  exists. Private owner identities never escape separately from their backing.
  Immutable publication retains actual backing, not receipts without payloads.
- Lexer and parser charge/check before byte/token/node operations; transforms
  charge/check before loops, comparisons, scans, numeric conversion, and copies.
  Temporary owners release when parsing finishes or fails. Live source, facts,
  library payload, and retained supporting backing release at the last owner copy.
- Group parsing uses an explicit frame stack. The caller provides a positive
  `maximumNestingDepth`; no production quota defaults are invented. Admission
  precedes stack growth and crossing the configured bound fails explicitly.
- Owned intake strictly validates UTF-8 before copying. Its supported lexical
  capability is ASCII: valid non-ASCII input is explicitly unsupported because
  the existing byte lexer cannot supply cooperative Unicode meaning. Ordinary
  source behavior is preserved. Backslash-LF/CRLF and physical diagnostics use
  the same lexer and conversion in both paths.
- Owned intake accepts exactly one Liberty library and no canonical JSON
  fallback. Active dependency/section constructs cannot be ignored as leaf
  coverage; unsupported include/section constructs are refused. Raw optional
  numeric process/voltage/temperature and original names are observations, never
  synthesized from a manifest, requested corner, path, or policy.
- Ordinary STA LUT defaults, normalization, extrapolation, and strict CTS rules
  retain their existing contracts. Owned source parsing does not grant CTS
  characterization. Source facts preserve declaration order and origins.
- Extracting raw `TimingLibrary`, arrays, or String fields transfers backing
  lifetime responsibility to the caller: retain `OwnedLibertySource` while using
  those borrowed/shared values. Mutation of extracted public timing IR is
  caller-owned work, outside the immutable parse owner contract.

### Existing Ordinary and CTS Semantics

The shared Liberty lexer consumes backslash-LF and backslash-CRLF line
continuations before numeric admission. Outside quoted strings a continuation
separates tokens; inside a quoted string it contributes no character. Physical
line numbers still advance, and a backslash not followed by a newline is not
silently discarded from an unquoted numeric value. This preserves actual
multi-row Sky130 Liberty tables without weakening finite numeric validation.

Strict admission requires positive finite time and explicit capacitance units,
nonnegative finite selected input-pin capacitance from the pin or an explicit
library default_input_pin_cap, unique cell/pin names, and all eight input/output/slew
rise/fall threshold percentages strictly between 0 and 100 with each lower slew
threshold below its upper threshold. Liberty R-2020.09 defines omitted time_unit as
1ns, input/output thresholds as 50%, lower slew thresholds as 20%, upper as 80%, and
slew_derate_from_library as 1; only these normative defaults are applied, with the
attribute names retained in standardDefaultAttributes. Capacitance has no invented
fallback. Pin-level threshold overrides are explicitly unsupported in this profile.
Applicable combinational propagation arcs require complete rise/fall delay and
transition tables.
Unconditional combinational arcs require an explicit supported timing sense and
exact related input pin. Conditional or unsupported propagation semantics fail.
Constraint groups remain owned by the ordinary parser and do not become CTS arcs.

Every strict propagation table resolves one unique lu_table_template. Exactly two
axes must represent input_net_transition and total_output_net_capacitance in either
order. Explicit table indexes override template indexes; otherwise the template
supplies them. All indexes and values are finite, nonnegative, dimensionally scaled,
and indexes strictly ascend. Reversed variable order is transposed into the existing
slew-row/load-column representation. Missing axes, scalar/1D/3D or other variables
are unsupported in this profile; no axis or table is synthesized. The published
[Liberty R-2020.09 reference](https://zao111222333.github.io/liberty-db/2020.09/reference_manual.pdf)
defines the template variables and index inheritance.

The immutable characterized value is constructed only by source admission. It
retains pin-versus-library-default capacitance origins and exposes actual pin
capacitance, arc sense and rise/fall evaluation without allowing
mutation or JSON reconstruction to bypass admission. Evaluation rejects nonfinite,
negative and out-of-range slew/load against all four tables, including singleton
axes, and returns delay plus output slew in seconds. Exact boundary queries pass.
Evaluation never extrapolates. Source clock-pin metadata is returned separately
for the caller to enforce sink identity. An explicit slew_derate_from_library other
than 1 is unsupported; characterization never grants signoff qualification.
Existing ordinary STA lookup keeps its separate
extrapolating semantics; it cannot produce a characterized value.

## Runtime Flows

check -> validate bytes/capability -> reserve source -> lex -> iterative groups
-> coverage admission -> accounted existing conversion -> source facts -> check
-> immutable owner. Failure releases private scratch/live storage and publishes
no owned success. No legacy decoder or ordinary parse retry is selected.

## State, Ownership, and Lifecycle

All construction state is invocation-local. Any shared private retention storage
uses one Mutex in every target. Immutable copied owners share receipts and actual
payloads. Resource callbacks run outside a retention lock. No detached tasks,
unsafe pointer escape, unchecked Sendable, or platform-specific synchronization
is introduced. Byte buffer borrows remain within synchronous scoped closures.

| State | Storage / isolation | Read / mutation | Release | Verified platform scope |
|---|---|---|---|---|
| Retained payload slots | `Mutex<State>` on all compilation paths | Short `withLock` slot operations; resource callbacks outside lock | Swap temporary state, then release outside lock; live state at final owner | Native macOS; no WASM/Embedded capability claim |
| Buffer/map/text builders | Invocation-local values + immutable COW identity | Same-capacity reservation before shared writes | Each last builder snapshot drops its receipt | Native macOS |
| Published source / receipt | Immutable Sendable owner | Scoped borrow, no mutation entry | Exactly-once callback after final copy | Native macOS |


## Failure, Concurrency, and Constraints

The parser is synchronous and I/O-free. The caller's accountant supplies deadline
and cancellation sampling. Resource errors propagate without localized variable
diagnostic copies; owned syntax/unsupported errors use static context and original
physical positions. Failed parse payload is released before returning failure.

## Verification and Change Impact

Dedicated `LibertyCodecTests` owns actual ordinary/owned grammar differential,
source facts and raw PVT, LF/CRLF, table dimensions/numbers, JSON/dependency/section
refusal, malformed UTF-8/non-ASCII capability, long token, overflow, pre-allocation
refusal, cancellation/deadline, copied owner release, and same-capacity COW proof.
Parent ordinary characterization regressions cover shared-algorithm behavior.
New domain/host integration remains unimplemented until this lower proof passes;
neither source shape nor successful compilation establishes profile consumption.

### TimingLUT Validation Seam

The codec materializes retained axes, rows, and optional transposed matrices only after
reserving their concrete logical capacities. The shared `TimingLUT` constructor checks
shape, ordered axes, and finite elements with nested iteration; it does not flatten the
matrix. Its internal cooperative callback runs before each validation step. The public
ordinary initializer delegates the same checks without a resource callback, preserving
numerical and error-order semantics. Lookup and CTS algorithms are unchanged. Tests
compare ordinary and owned axes/matrices and exercise refusal during validation.

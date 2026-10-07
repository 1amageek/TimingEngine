# TimingCore

## Purpose and Scope

Own canonical timing values, parsers and characterized load/slew evaluation.
Parent: [TimingEngine](../../DESIGN.md). No child design units.

## Responsibilities and Boundaries

LibertyParser owns the single Liberty grammar and source admission. The strict
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

An unscoped root/net identity can name an external network without a D_NET in
partial parasitic coverage. The canonical validator owns checking such identities
against the logical design; the parser does not synthesize absent networks.
Coupled CAP entries publish two distinct net identities and retain capacitance in
farads. Ground/total capacitance remain farads and resistance remains ohms. The
existing lumped CAP/RES scalar aggregation does not establish a resistor graph.
The net-level timing model does not represent intra-net two-terminal capacitors;
such entries fail explicitly. Aggregates and unit conversions must remain finite.
Parser state is invocation-local and has no platform-dependent synchronization.

```text
SPEF bytes -> NAME_MAP / D_NET / CONN admission
           -> complete endpoint ownership resolution
           -> SI-unit network totals + net-level coupling
           -> Native STA / SI canonical validation
```

## Runtime Flows

Parse once, resolve selected cells and source facts, normalize existing LUT values,
then evaluate repeatedly using immutable admitted data. Unknown cells/pins, missing
or ambiguous arcs and unsupported data produce typed characterization errors.

## State, Ownership, and Lifecycle

Invocation-local immutable value state. No shared mutable cache, pointer or
platform-specific isolation is added.

## Failure, Concurrency, and Constraints

Typed source/semantic/ambiguity/range failures propagate to the caller. Work is
bounded by source size and selected cell/table sizes. This host Foundation module
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

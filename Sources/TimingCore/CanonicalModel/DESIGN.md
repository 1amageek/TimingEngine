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

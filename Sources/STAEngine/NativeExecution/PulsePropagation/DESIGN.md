# PulsePropagation

## Purpose and Scope

Own bounded primary control-pulse propagation. Parent:
[NativeExecution](../DESIGN.md). No children. Reuse the prescribed periodic RC
operator and existing source-qualified unary buffer/inverter profile.

## Responsibilities and Boundaries

Consume exact explicit primary pulse sources, the candidate graph and selected
corner. Produce actual receiver edge arrivals/slews and source lookup receipts.
No general logic waveform simulation, inferred frequency, receiver override or
directional asynchronous Q timing is supplied.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PreparedExecution](../../PreparedExecution/DESIGN.md) | depends on | Exact explicit pulse operating inputs | Source admission | Preserve original source accountant |
| [DistributedRC](../DistributedRC/DESIGN.md) | depends on | Periodic prescribed-ramp response | Physical receiver transfer | Same cumulative numerical steps and work |
| [ClockPropagation](../ClockPropagation/DESIGN.md) | coordinates with | Source unary buffer/inverter polarity | Existing characterized profile | A control pulse is not a clock receiver |
| [PathAnalysis](../PathAnalysis/DESIGN.md) | used by | Actual received edges and shared source receipt arena | Check composition | Dynamic Q scope remains separate |

## Architecture

```text
explicit primary pulse -> exact source buffer/inverter path
    -> actual per-segment periodic RC + checked cell lookup
    -> exact control receiver rise/fall events
    -> source pulse laws and recovery/removal checks
```

## Contracts and Invariants

Each required dynamic control pulse resolves to exactly one declared primary
source. Every receiver is connected through exact candidate nets and admitted
unary source functions. Loops, gated/multi-input transformations, missing source
conditions or unsupported signal paths fail. Binary constants are handled by
PathAnalysis's static source/state contract and generate no waveform.

Both periodic contexts retain the original source edge, phase and period through
inversion and physical segments. Actual cell queries enter the same source arena
at evaluation; physical net/receiver response remains in the RC owner's evidence.
No nominal period substitutes receiver high/low width. Source pulse fields bind
the effective configuration; exact source/candidate/corner identity stays outside
the value's public declaration and is enforced by preparation/replay.

## State, Ownership, and Lifecycle

One invocation owns immutable source definitions and local wave/receiver caches.
Every variable collection is admitted before growth against shared logical
state/work limits. No shared mutable global or target-dependent isolation exists.

## Failure, Concurrency, and Constraints

Cancellation, the retained source deadline and resource accounting remain active.
Periodic RC uses the existing request-wide step budget. Missing or conflicting
inputs and numerical failure publish no partial completed strict report.

## Verification and Change Impact

Focused tests cover direct and buffered/inverted actual RC pulse widths, both
source edges, one-axis laws, static asserted/inactive controls, no-source-law
applicability, unknown input refusal, exhausted budgets and replay tampering.
Digest-checked actual Sky130 dlxtp/dfxtp/dfrtp laws verify source retention and
lookup rather than a synthetic scalar replacement. Upper owns API/CLI candidate
adoption; qualification and post-route completion remain independent.


## Certified Coupled Boundary Model

Certified mode follows the [PathAnalysis](../PathAnalysis/DESIGN.md) interval
contract through source buffers/inverters and full coupled control wires. Periodic
ramps must have proved nonoverlapping full-rail histories. Pulse checks pair the
latest opening with earliest closing and subtract the largest original pulse
law over the complete opening-slew interval. Range receipts remain companion
owned-source evidence, and exact prepared replay checks them.

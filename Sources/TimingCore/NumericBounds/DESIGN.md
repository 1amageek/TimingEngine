# NumericBounds

## Purpose and Scope

Package-only finite interval arithmetic for source table enclosures and STA certificates.
Parent: [TimingCore](../DESIGN.md). No children.

## Responsibilities and Boundaries

Own outward arithmetic on IEEE 754 Double endpoints. No physical waveform, source
qualification, matrix algorithm, or public generic numerical API is owned here.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingCore](../DESIGN.md) | parent | Immutable numerical values | Source evaluation support | No source authority |
| [LibertyCodec](../LibertyCodec/DESIGN.md) | used by | Checked range evaluation | Outward bilinear vertices | Source owner validates domains |
| [ConservativeCoupling](../../STAEngine/NativeExecution/ConservativeCoupling/DESIGN.md) | used by | Finite outward bounds | Certificate arithmetic | Consumer owns matrix proof |

## Architecture

```text
source evaluator / STA certificate -> TimingNumericInterval -> directed Double endpoints
```

## Contracts and Invariants

Each interval contains every exact real result of the requested operation on its
input endpoints. Each primitive rounds the IEEE nearest result outward with
nextDown/nextUp; exact zero and neutral operand identities preserve exact bounds.
Subnormal underflow is enclosed. Nonfinite inputs, nonfinite outward endpoints,
NaN and division by an interval containing zero fail explicitly. No saturation or
silent approximation is accepted. Immutable values are invocation-local and add
no shared state, concurrency, platform adapter, or lifetime contract.

## Verification and Change Impact

`LibertyCodecTests/TimingNumericIntervalTests.swift` owns cancellation, zero,
subnormal, signed arithmetic, division, overflow and invalid input witnesses.
Source-range tests own interpolation composition; STA owns matrix certificates.
Native execution evidence grants no WASM or Embedded runtime claim.

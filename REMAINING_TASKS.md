# TimingEngine Remaining Tasks

Updated: 2026-07-26

The declared native STA/SI subset, external OpenSTA execution, retained raw
correlation, and evidence assessment are implemented. The retained Sky130A
profile covers SS/TT/FF with exact Liberty, SDC, SPEF, PDK, raw native output,
raw OpenSTA output, deterministic correlation, and tamper verification.
Remaining work expands signoff breadth without moving trust decisions into
TimingEngine.

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
| TIM-2 | P2 | TimingEngine | Add advanced statistical variation analysis. | The request and result contracts define the supported variation model; the implementation has numerical reference cases, typed unsupported limits, and retained corpus evidence. |
| TIM-3 | P2 | TimingEngine | Add waveform-resolved crosstalk and noise analysis. | Waveform semantics, coupling inputs, units, thresholds, artifacts, and independent correlation are implemented and tested without reusing the current ratio-only result as a false substitute. |

## External prerequisites

An independent OpenSTA executable, exact process assets, broader cell-family
coverage, and foundry acceptance are external inputs. The retained Sky130A
three-corner profile proves only its declared scope.

## Evidence reviewed

- `README.md`
- `DESIGN.md`
- `INTERFACES.md`
- `IMPLEMENTATION_PLAN.md`
- `MILESTONES.md`
- `GOAL_STATUS.md`, especially `Remaining limitations`
- `Sources` incomplete-implementation marker scan

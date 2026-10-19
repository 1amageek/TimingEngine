# ScalarReference

## Purpose and Scope
Own the independent scalar timing correlation profile. Parent: [TimingEngine module](../DESIGN.md). No children.

## Responsibilities and Boundaries
Evaluate retained ordinary same-name connectivity for model correlation. Native
STA owns aliases, constants, propagated slew and static endpoint observations.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Module](../DESIGN.md) | parent | Correlation composition | Scalar oracle | Not functional proof |
| [CanonicalModel](../../TimingCore/CanonicalModel/DESIGN.md) | depends on | TimingDesign values | Existing value consumer | Refuse added semantics |

## Architecture
```text
ordinary design/library/constraints -> scalar traversal -> correlation metrics
explicit alias/constant -> typed unsupported
```

## Contracts and Invariants
New connectivity fields cannot be silently ignored. The scalar profile refuses
aliases, constant drivers and path exceptions before traversal. Ordinary interpolation and legacy
same-name connectivity retain their behavior. Explicit minimum input/output delays
are evaluated for the ordinary scalar profile; exception/alias/constant scope stays refused.

The scalar oracle consumes only the source model's exact simple edge-flip-flop
compatibility projection or an explicit legacy scalar declaration. A source-defined
latch, compound state update or unrepresented control is rejected before traversal;
missing singular pins never turn a stateful cell into a combinational cell. Source
qualification and full sequential execution remain TimingCore/NativeExecution-owned.
This boundary preserves the scalar correlation profile rather than granting strict
source evidence to a legacy model or decoded declaration.

## Verification and Change Impact
STAConnectivityTests owns refusal of new connectivity; corpus and native package
regressions own unchanged ordinary correlation. Any future scope expansion needs
independent expected numbers rather than copied native observations.

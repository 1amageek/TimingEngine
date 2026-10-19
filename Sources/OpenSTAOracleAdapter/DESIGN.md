# OpenSTAOracleAdapter

## Purpose and Scope
Own the existing optional executable oracle adapter. Parent: [TimingEngine](../../DESIGN.md).
No children. This target is not a native STA or qualification authority.

## Responsibilities and Boundaries
Verify/snapshot the executable and inputs, execute only snapshots, retain raw streams,
and emit canonical result/refusal. SignoffToolSupport owns process control and cleanup.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [TimingEngine](../../DESIGN.md) | parent | Immutable oracle evidence | CLI owner | No qualification |
| [SignoffToolSupport](../../../SignoffToolSupport/DESIGN.md) | depends on | TimedProcessRunner / failure / control / cleanup | Process lifecycle | Caller supplies output and cleanup budgets |

## Architecture
```text
explicit CLI budgets -> version probe -> immutable executable/input workspace
    -> TimedProcessRunner -> exact raw streams + typed cause -> canonical envelope
```

## Contracts and Invariants
Require explicit maximum-output-bytes and cleanup-timeout options. Version probing
uses the same output and cleanup budgets; analysis timeout retains existing meaning.
ExecutionFailed retains exact bytes and independent cleanup ownership. No completed
result is emitted with pending cleanup. Raw stream artifacts are written from Data;
lossy UTF-8 conversion is only a parsing/display boundary. Caller control is the
lower Mutex-backed TimedProcessControl API; no unsynchronized flags are introduced.

## State, Ownership, and Lifecycle
The async invocation owns process cleanup and immutable workspace. Normal and failure
paths join lower execution. Pending cleanup remains a typed failure with its native
handle, never an empty string or fabricated successful close.

## Failure, Concurrency, and Constraints
Explicit budgets cap output and process cleanup. First failure cause is retained
when cleanup also fails. Version mismatch and snapshot drift remain explicit failures.
Async main retains the first typed failure and native handle, joins caller-budget
close, and reports nonterminal cleanup-pending diagnostics if still unresolved. It
remains in shutdown until terminal confirmation, starts no further oracle work and
never resets the execution deadline. OS cleanup-pending cannot promise bounded CLI
termination. A descriptor alone never replaces native cleanup ownership.

## Verification and Change Impact
TimingCLIProcessTests verifies actual executable success/refusal, stream retention,
version/snapshot mutation and process limits. TimedOracleConsumerTests verifies the
lower typed cleanup handoff. CLI option callers and host process settings must migrate
together; no guessed compatibility budgets are added.

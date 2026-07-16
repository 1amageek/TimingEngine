# TimingEngine Implementation Instructions

## Goal

Implement canonical timing data, MMMC static timing analysis, signal-integrity analysis and reproducible raw evidence.

## Required boundaries

- Keep public interfaces protocol-first and implementations directly conforming.
- Use one primary type per Swift file.
- Keep code, comments and documentation comments in English.
- Use typed errors and never use `try?`.
- Do not add `@unchecked Sendable`, `DispatchQueue` or `EventLoopFuture`.
- Use asynchronous readers for artifact I/O.
- Treat unavailable semantics as blocked.
- Keep production qualification in ToolQualification.
- Keep flow approval, policy and resume in DesignFlowKernel.
- Do not import Xcircuite or circuit-studio.
- Require workspace-relative artifacts for retained external correlation.

## Before implementation

Read README.md, DESIGN.md, INTERFACES.md and IMPLEMENTATION_PLAN.md completely.

## Definition of done

Build, timeout-bounded tests, fixtures, structured diagnostics, CLI reproducibility, raw artifact reconstruction and documented trust ownership are required.

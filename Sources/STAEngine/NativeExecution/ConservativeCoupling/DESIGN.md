# Conservative Coupled RC

## Purpose and Scope

Parent: [NativeExecution](../DESIGN.md). Child: [SourceFamilies](SourceFamilies/DESIGN.md). Own certified, conservative
wire delay and slew intervals for the normalized prescribed-voltage-ramp, passive
linear R/C model, over every admitted source switching history. Active clock nets
are ordinary coupled sources. This is a model guarantee, not transistor-drive,
CCS, foundry, or physical qualification. The internal interface below is retained
by the sparse implementation sprint defined here; a sparse execution is complete
only after its stated behavioral and actual-scale evidence is obtained.

## Responsibilities and Boundaries

The component owns exact primitive assembly, coupled-component closure, bounded
history error envelopes, numerical certificates, event crossing certificates, and
their resource accounting. Preparation owns the complete preserved source
inventory, canonical driver/receiver bindings, selected characterization source,
and source slew authority. Path and clock propagation own interval composition,
Liberty table range evaluation, derates, and endpoint checks. Reporting owns
serialization and required-net/corner coverage validation.

Every admitted dynamic source is a continuous normalized voltage in [0, 1]. Its
operating history consists of nonoverlapping full-rail linear transitions and
plateaus; every rising/falling transition uses the corresponding admitted slew
interval. A requested event is one such complete transition. No independent
phase, quiet aggressor, simultaneous-switch, or settled initial-node assumption
is made. Logical/SDC correlations may restrict this history set; independently
allowing every source history is a conservative relaxation.

Initial state means the stable bounded-input solution over the entire operating
history. This is a request-declared model premise retained by host preparation.
Arbitrary precharged capacitor energy outside this history contract is not covered.
Preparation does not infer this premise from SDC or numerical cycle agreement.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Prepared scenario, cumulative accounting | Run-local composition | No certificate inferred from a completed report |
| [DistributedRC](../DistributedRC/DESIGN.md) | coordinates with | Exact source inventory, thresholds, receiver bindings | Existing observed-convergence mode | Grid/cycle agreement is not a conservative certificate |
| [ClockPropagation](../ClockPropagation/DESIGN.md) | used by | Explicit primary clock and buffer/inverter sources | Clock event intervals | Active clock coupling is retained |
| [PathAnalysis](../PathAnalysis/DESIGN.md) | used by | Receiver arrival/slew and table evaluation | Downstream interval propagation | A point lookup at maximum slew does not bound a nonmonotone LUT |
| [PreparedExecution](../../PreparedExecution/DESIGN.md) | depends on | Immutable selected-source and configuration identity | Source authority | No reread or caller-supplied certification verdict |
| [ParasiticReduction](../../../TimingCore/ParasiticReduction/DESIGN.md) | depends on | Preserved primitive records and identities | Exact R/C input | Lumped totals cannot replace primitive topology |
| [LibertyCodec](../../../TimingCore/LibertyCodec/DESIGN.md) | depends on | Thresholds and characterized transition domains | Source slope authority | Unsupported extrapolation or overrides fail |

## Architecture

```text
complete primitive inventory + canonical source/receiver bindings
  -> exact zero-R quotient and cross-net-C connected components
  -> G, C, Gs, Cs and DC driver incidence P
  -> sparse exact zero-C-row Schur elimination and CAP-only block partition
  -> block-local verified coordinates + sparse comparison certificates
  -> global voltage error E and derivative bounds
  -> requested full-rail ramp + unique threshold crossing certificate
  -> wire delay/slew intervals + source-bound evidence
  -> parent-owned downstream LUT range propagation and coverage validation
```

### Sparse Implementation Sprint Contract

This sprint changes the numerical storage and execution cost of the same admitted
model, internal prepare/bounds interface, and mathematical certificate. It owns
CSR operator construction, exact algebraic fill, small-block verified mass solves,
bounded sparse candidate iteration, and sparse residual verification. Primitive
meaning, source authority, operating-history premise, crossing semantics, public
source ABI, and required net/corner coverage remain the contracts below.

The all-corner actual-primary census is retained at
[actual-primary-allcorner-summary.json](../../../../../.verification/runs/s3-stageIII-20261013-2e1f3af7/native-production-goal-20261014/sta-actual-resource-census/actual-primary-allcorner-summary.json).
All three corners have 5,627 unknowns, 5,596 dynamic rows, 31 singleton zero-C
components and seven prescribed sources. The 4,580 positive-C-only blocks have
maximum size 14, sum of squared sizes 12,360, and sum of cubed sizes 70,888.
The structural upper bounds are 27,118 directed Schur fill slots, 52,060 reduced-G
slots and 79,815 block-C-inverse-G slots; the largest zero-C dynamic boundary is
100. These are exact-topology resource facts, not a stability/crossing certificate.

| Owner | Implementation responsibility | Completion evidence |
|---|---|---|
| Kernel | Canonical graph reduction, candidate dispatch, shared-budget/precomputation integration, F/w/p and crossing composition | Primitive/dense-reference fixtures and exact graph/certificate bindings |
| Sparse numerics and basis helpers | Validated CSR, outward matvec, bounded candidate solve, residual enclosure, local-basis transformation | Matrix/basis analytic and dense-reference success, refusal, work/storage/cancel tests |
| Parent integration | Unchanged request/source identities, cumulative accounting, all-corner execution | Focused integration and actual-scale success or explicit failed certificate |

Acceptance requires preservation of every coupling element and all configured
ceilings, finite bounded work through the actual graph, and either all required
voltage/crossing certificates or a typed inconclusive result identifying the failed
condition. Structural feasibility does not promise actual stability, unique
crossings, or a completed actual-design STA result. Budget/refinement failure
cannot be repaired by dropping C, grounding coupling, imposing phase correlation,
or building a global dense/modal operator beyond the admitted sparse profile.

The execution order is CSR/helper contract, sparse graph and block assembly,
verified sparse certificates, focused differential verification, then one integrated
actual-corner run under measured resource limits. The current estimate is 45-70
minutes for kernel implementation, followed by parent-owned verification; the
critical path is sparse assembly -> block/Schur checks -> certificate execution.
This estimate is an operational plan, not an acceptance condition.

### Local CAP-Block Coordinate Sprint Contract

The identity-coordinate comparison is now concretely disproved for the unchanged
actual-primary nominal input. The retained
[diagnostic execution](../../../../../.verification/runs/s3-stageIII-20261013-2e1f3af7/native-production-goal-20261014/sta-sparse-weight-diagnostic2/execution.log)
has 5,596 rows and 79,815 entries and verifies a nonzero z >= 0 with F z >= 0;
comparisonNonHurwitzProved is true. This proves failure of this comparison F,
not instability of the passive physical operator and not failure of the requested
timing specification. Improving the ordinary weight solve cannot make this F
Hurwitz. No positive timing result is inferred from its rejection.

This limited sprint adds only block-diagonal coordinates on the existing CAP-only
partition. The broader
[actual census](../../../../../.verification/runs/s3-stageIII-20261013-2e1f3af7/native-production-goal-20261014/sta-actual-resource-census/attempt8-allsubjects-allcorners-summary.json)
also includes derived designs with 6,334 unknowns, 6,299 dynamic rows, 35 zero-C
rows, eight sources, maximum CAP block 18 and a 95,031-entry identity-A structural
bound. These facts size the admitted local work; transformed off-block fill is
counted separately. Multiple nodes of one net and several nets can occupy one CAP
block, so independent two-wire common/differential modes are not assumed.

The comparison portion, introduced by native algorithm 3.12,
selects its finite sparse batch from the current primitive
profile, without using a historical certificate to skip a candidate. When every
CAP block is a singleton, it uses identity only: exact diagonal C and anchored
reduced G already give a Metzler Hurwitz physical operator. With a nontrivial CAP
block, the order below is fixed and truncated by maximumCertificateAttempts:

| Candidate | Per-block Q proposal | Numerical authority |
|---|---|---|
| 1 | C whitening followed by local generalized (Gbb, Cb) Jacobi modes | Verified M block and the unchanged comparison/crossing tests; approximate eigenvalue accuracy grants nothing |
| 2 | C whitening, without Jacobi rotation | Same tests |
| 3 | Identity | Existing exact physical coordinates and the same tests |

For each block, an ordinary midpoint Cholesky proposal Cb approximately Lb LbT
gives Qb = sb inverse(transpose(Lb)), optionally multiplied by the local Jacobi
rotation. The strictly positive finite scalar sb is the square root of the maximum
midpoint diagonal capacitance in that block. It makes Qb dimensionless and avoids
unit-magnitude amplification. Scalar multiplication changes only the coordinates;
all candidate entries are collapsed to finite exact Double points and independently
verified. The local-modal candidate uses at most maximumBasisSweeps. Existing small-block basis
generation and verified solves are reused; no new eigensolver authority is added.

Let Q be block diagonal with these Qb. For every actual reduced-G block edge b,d,
form and retain all possible transformed entries:

```text
Mb = transpose(Qb) Cb Qb
Kbd = transpose(Qb) Gbd Qd
Atilde_bd = -inverse(Mb) Kbd
Jtilde_b = -inverse(Mb) transpose(Qb) Lb
Tnew = W Q
```

Each Mb must be verified positive definite; each solve uses the existing outward
small-block verifier. This proves invertible coordinates without trusting an
approximate eigenvector. Every off-block Cartesian fill contribution and WQ
reconstruction slot is counted and admitted before allocation, including temporary
products. CSR entries are never pruned by value. The source forcing, physical
reconstruction, voltage and derivative bounds use Jtilde and Tnew consistently;
using physical-node thresholds directly on a modal coordinate is invalid.

Resistance remains in ohms, capacitance in farads, source/query times in seconds.
Mb/Kbd retain capacitance/conductance units, Atilde has inverse-second units, and
Jtilde and Q are dimensionless. Source slopes and bounded operating histories
are unchanged. All candidate preparation, failed solves, local sweeps, storage,
fill, source certificates and cancellation checks consume the original cumulative
owners and ceilings; temporary release does not refund slots. No global dense
matrix, global modal basis, quiet source, dropped coupling or enlarged input
assumption is introduced. After the first candidate passing all required prepared
operator/source certificates, preparation stops. Query proof failure remains typed
inconclusive without another basis search. Exhausting the finite batch is also
typed inconclusive unless the residual slot below is configured. Failed comparison
conditions remain retained; they do not imply physical instability.

The residual alternative uses native algorithm 3.13.1 and its parent-owned exact
configuration/hash admission. This patch binds the externally queried receiver
projection and bounded residual-checker checkpoint policy below. A fresh reader
does not admit prior 3.13 residual evidence as a 3.13.1 result; historical execution
can only be inspected under its original identity, without relabeling. Request schema 4, configuration schema 10 and the
normalized prescribed-ramp mathematical model v1 remain unchanged: the admitted
history family and completed Bounds/unique-event guarantees are identical. Internal
Prepared selection identifies the proof method; no public receipt field is added.
A successful
local candidate on the actual design is unverified until execution; neither
passivity nor small block size guarantees a Hurwitz scalar comparison or unique
crossing.

### Proposed Internal Interface

The numerical implementation provides one protocol and one implementation
namespace. Nested records are local inputs/results, not new public products,
source-authority services, or independently serializable artifact schemas.

```swift
internal protocol NativeSTAConservativeCouplingSolving: Sendable {
    func prepare(
        parasitics: TimingParasitics,
        sources: [NativeSTAConservativeCoupling.Source],
        receiverLoads: [TimingParasitics.Endpoint: Double],
        thresholds: TimingCharacterizationThresholds,
        options: STAConservativeCoupledRCOptions,
        limits: STAExecutionLimits,
        stateBudget: NativeSTAStateBudget,
        sourceResources: (any LibertySourceResourceAccounting)?,
        work: inout UInt64
    ) throws -> NativeSTAConservativeCoupling.Prepared

    func bounds(
        prepared: NativeSTAConservativeCoupling.Prepared,
        source: TimingParasitics.Endpoint,
        sink: TimingParasitics.Endpoint,
        edge: TimingEdge,
        sourceSlew: ClosedRange<Double>,
        work: inout UInt64
    ) throws -> NativeSTAConservativeCoupling.Bounds
}

internal struct NativeSTAConservativeCoupling:
    NativeSTAConservativeCouplingSolving {
    internal enum Source: Sendable {
        case constant(endpoint: TimingParasitics.Endpoint, voltage: Double)
        case dynamic(
            endpoint: TimingParasitics.Endpoint,
            sourceIsPort: Bool,
            riseSlew: ClosedRange<Double>,
            fallSlew: ClosedRange<Double>
        )
    }

    internal enum Prepared: Sendable {
        case comparison(ComparisonPrepared)
        case residual(ResidualPrepared)
    }

    internal struct Bounds: Sendable {
        let delay: ClosedRange<Double>
        let slew: ClosedRange<Double>
        let voltageErrorUpperBound: Double
        let minimumCrossingDerivative: Double
        let maximumAbsoluteDerivative: Double
        let admittedSourceSlew: ClosedRange<Double>
    }
}
```

The existing prepare/bounds protocol remains the only host entry point.
ComparisonPrepared retains the existing comparison payload. ResidualPrepared owns
only the common parasitics, sources, receiverLoads, endpointRows, endpointSource,
sourceIndices, sourceSlopes, dcIncidence, thresholds, options and numerics, together
with NativeSTAConservativeResidualResponse.Facts. It has no invented A/J/F/w or
comparison radii. Host consumers continue to retain opaque Prepared. No facade or
independently serialized method receipt is introduced.

Prepared retains the exact primitive SourceIDs, connection/receiver identities,
source port/cell roles, source slew intervals and selected threshold convention. Its certificate material
includes component dimension, zero-row elimination mapping, the selected
comparison or residual facts, accounting owners, and explicit configured ceilings
and admission checks.
NativeSTAStateBudget does not expose its used-slot total; Prepared does not retain
or report an actual cumulative slot total. The parent joins these facts to existing exact
candidate, parasitic, Liberty, mode, corner, and configuration identities.
An identity string is not accepted as substitute source authority.

The supplied parasitics is the complete prepared inventory, not a caller-selected
subset of a coupling component. Preparation validates sources against canonical
drivers before this interface is called. Numerical admission checks exact endpoint
presence, ownership, uniqueness, finite values, and source-slew containment again.
The caller does not supply P, an assembled matrix, or a certificate verdict.

The former global-energy draft is withdrawn. Its global Cauchy norm derivative
bound loses zero cross-source influence even for two uncoupled identical RC nets.
The measured per-net small-gain proposal also fails on the actual primary graph.
Neither proposal defines a successful dispatch, Prepared variant, or source API.
The source/output-local residual contract below replaces that investigation. A
complete implementation must prove all numerical bounds and explicitly refuse any
response whose event certificate is not established; actual positive timing is a
separate completion-evidence requirement, not an assumption of this algorithm.

The helper/kernel boundary is internal to STAEngine. TimingCore continues to own
TimingNumericInterval; the sparse helper reuses NativeSTAConservativeNumerics for
the existing shared work/storage/source-resource owner. Its proposed signatures
are fixed before implementation:

| Internal boundary | Immutable result / owned guarantee | Implementation owner |
|---|---|---|
| Graph.reduce | Reduced(dynamicRows, CSR Gr, CSR Cr, N.Matrix L, CSR W, CSR P, sorted partition capBlocks); verifies each physical Cr block SPD once | Kernel owner: graph/reduction and primitive tests |
| NativeSTAConservativeSparseBasis.transform(reduced, candidate, maxSweeps, work) | Operators(dynamicRows, a, j, T, P); owns every Qb/Mb, QtGQ, QtL, WQ, off-block fill and its admission/charging | Numerics owner: basis helper and matrix regressions |
| Kernel candidate composition | Dispatches the fixed candidate batch, retains source precomputations, and verifies F/w/p/crossing using the same cumulative work and storage owners | Kernel owner |

These are internal file responsibilities within this component. Reduced is shared
immutably; transform neither resets accounting nor repeats physical Cr-block SPD
proof. Each candidate's transformed Mb still requires its own verified SPD/solve.

```swift
internal struct NativeSTAConservativeSparseNumerics {
    typealias I = TimingNumericInterval
    typealias N = NativeSTAConservativeNumerics
    let numerical: NativeSTAConservativeNumerics
    struct CSR: Sendable {
        let rows: Int
        let columns: Int
        let rowOffsets: [Int]
        let columnIndices: [Int]
        let values: [I]
    }
    func fromRows(_ rows: [[Int: I]], columns: Int,
                  work: inout UInt64) throws -> CSR
    func product(_ a: CSR, _ x: N.Matrix,
                 work: inout UInt64) throws -> N.Matrix
    func negated(_ a: CSR, work: inout UInt64) throws -> CSR
    func magnitude(_ a: CSR, work: inout UInt64) throws -> CSR
    func approximateSolve(_ a: CSR, rhs: N.Matrix, maxIterations: Int,
                          work: inout UInt64) throws -> N.Matrix
    func verifiedSolve(_ a: CSR, rhs: N.Matrix, comparisonF: CSR,
                       weight: N.Matrix, maxIterations: Int,
                       work: inout UInt64) throws -> N.Matrix
}
```

CSR construction validates dimensions, checked counts, offsets, finite intervals,
and sorted unique column indices in each row. Structural zeros may be omitted
only when exact primitive/algebraic provenance proves absence, never by a magnitude
tolerance. Duplicate primitive contributions are combined outward before CSR
publication. Kernel-owned assembly reserves mutable tables and fill before growth.

approximateSolve is an ordinary untrusted floating-point proposal, initially using
Jacobi-preconditioned BiCGStab. A bounded Gauss-Seidel proposal is permitted under
the same contract. Its norm-based stopping rule grants no numerical authority.
The whitening weight-only dispatch has a fixed portfolio of at most two proposals,
after the principal non-Hurwitz precheck: first BiCGStab, then zero-initialized
deterministic cyclic Gauss-Seidel for positive-diagonal Z-matrix B = -F. Each
proposal passes the same positive-w, outward F w < 0 and positive-alpha gate.
Only NativeSTAConservativeCandidateNotCertified from the first proposal/gate
advances to GS. The first certified proposal is accepted. Fatal numerical errors,
capacity, cancellation and source-owner failures propagate without catch or retry.
Both attempts consume the same cumulative owners, limits and finite iteration
caps without reset. Local-modal, identity, source and residual solve proposals
retain their existing paths. This preserves the valid whitening fixture that
BiCGStab certifies but finite-budget GS alone does not; its checks are not weakened
and its fixture is not changed to bypass the failure. GS preserves nonnegative
iterates and converges if B is a nonsingular M-matrix, but finite-budget convergence
is not assumed. A finite iteration-limit proposal remains untrusted.
maxIterations is a positive internal operational cap at most the checked product
of dynamic dimension and maximumBasisSweeps, also bounded by remaining request
work and charged per-iteration cost. This explicit rule defines that option's
sparse execution use without changing its serialized field. Every matvec, vector pass, workspace,
restart, cancellation check and failed attempt consumes the same cumulative budget.
Breakdown, nonfinite values and invalid pivots fail explicitly. At its iteration
cap the helper may return its finite current proposal; the subsequent outward
certificate either accepts it or returns typed inconclusive. Exhaustion never
grants authority to an uncertified value.

Within approximateSolve only, candidate setup and vector/matvec operations batch
their checkpoints. A complete finite CSR setup or matvec pre-admits the same
checked nnz + rowCount work units before computing; each finite vector or dot
pass pre-admits its unchanged element-count charge. The charging tick also checks
cancellation and the original source resource owner immediately before the
operation. A zero-work tick immediately after it checks the same boundaries
without increasing the work total. Existing row/entry admission and maximumNodes
bound the uninterruptible operation; no unbounded group of operations is batched.
Insufficient remaining capacity rejects before that whole operation, rather than
after partial computation. Successful work totals, Double operation/evaluation
order, recurrence, stopping rules, scratch ownership and returned candidate bits
remain unchanged. No mutable global checkpoint state or accounting-owner reset is
introduced. All outward arithmetic and certificate paths keep their existing
checks. The independent residual-checker batching exception is defined below and
does not broaden this approximateSolve change. One nonzero
RHS with setup and exactly one full iteration charges 3 * nnz + 13 * rowCount;
an early-s-residual iteration charges 2 * nnz + 10 * rowCount, including final
copy. These count fixtures and exact candidate-equivalence fixtures verify this
limited performance change independently of mathematical certification.

verifiedSolve solves a signed stable-generator system A x = b. Its comparison F
must be verified Metzler, majorize this same A on the diagonal and absolute
off-diagonal entries, and satisfy w > 0 and F w < 0. For an untrusted candidate
xc, form the outward residual q = b - A xc and verify v >= 0, -F v >= |q|.
Then |inverse(A)| <= inverse(-F) proves x in xc + [-v, v]. A verified w-scaled
residual correction is sufficient; an approximate inverse is not constructed.
For w/p proposals the kernel calls approximateSolve on -F and separately verifies
the defining inequalities; it does not pass -F as the generator with comparison F.

## Contracts and Invariants

### Exact Primitive Operator

Positive resistance defines the actual resistive graph; zero resistance imposes
exact voltage equality. Quotienting preserves every original endpoint and source
record identity. Cross-owner zero resistance and multiple canonical drivers fail,
including multiple drivers on the same ideal class. Each admitted resistive
component has exactly one canonical driver and every unknown node is resistively
connected to it. Capacitive edges may join otherwise distinct resistive components.
The solver includes the entire transitive cross-net coupling component.

Every primitive CAP is stamped exactly once according to its preserved physical
record identity. Distinct records with equal endpoint/value fields remain distinct;
equal values are not evidence of duplicate physical elements. Conflicting repeated
identities fail. The canonical EquipotentialTimingParasiticReducer's explicit
mirroredSourceGroups contract identifies paired declarations of one physical
cross-net element; only one deterministic representative is stamped for each such
group, while all original SourceIDs remain retained. Its lumped loads are not used
as the coupled operator. Ground, same-net differential, cross-net differential, unknown-to-
source, and source-to-source capacitances retain their physical incidence. Elements
within one ideal class have zero incidence but remain in evidence. Receiver pin
loads attach to exact endpoints; no driver pin load or unattached canonical load is
invented. Unsupported ambiguous duplicate-declaration semantics fail at intake.

After source elimination the exact real operator represented by the admitted
finite input values satisfies

```text
C v' + G v = -Cs u' - Gs u
G P = -Gs
P[i,j] = 1 exactly when unknown i belongs to source j's resistive component
```

G is symmetric positive definite; C is symmetric positive semidefinite. These
properties and the DC identity are verified, not inferred from successful ordinary
floating-point factorization. G's positive-definite proof is structural: every
positive conductance contributes a nonnegative squared voltage difference and
each unknown resistive component reaches an ideal source, so their sum can vanish
only for the zero unknown vector. This proof does not require a global dense
factorization. The model treats admitted Double primitive values as
exact binary values; directed arithmetic encloses subsequent construction and
solves. Original source records remain bound separately. Resistance is in ohms,
capacitance in farads, and source slew and response times in SI seconds; no implicit
Liberty time-unit scaling occurs inside the numerical kernel.

### Supported Capacitance Profile

An actual zero C row is identified from zero physical incidence after quotient,
not from a small numerical diagonal. Such rows also have zero Cs and zero L row,
where L = CP + Cs. Partitioning dynamic rows d and zero rows a gives

```text
Ga = Gaa
Gr = Gdd - Gda inverse(Gaa) Gad
Cr = Cdd
Lr = Ld
ea = -inverse(Gaa) Gad ed
```

All inverses denote verified linear solves. This exact Schur elimination preserves
the error e = v - P u. If no dynamic rows remain, e is exactly zero and responses
use analytical source thresholds. Otherwise Cr must be verified positive definite.
Other singular-C profiles, including floating differential-capacitance modes after
zero-row elimination, are explicitly unsupported in this implementation. No epsilon
capacitance, epsilon resistance, approximate rank, or silent alternative solver is
used. Evidence identifies this profile limitation separately from graph coverage.

### Exact Sparse Operator Construction

Before any global dense allocation, checked conservative dense workspace and cubic
work estimates are compared with the configured request ceilings. A conservative
64 * unknownCount * unknownCount slot estimate or a cubic work estimate exceeding
the available ceiling selects sparse construction. This is an operational dispatch
rule, not a magic dimension threshold or a substitute for individual admissions.
Every actual allocation and operation is still charged. A dense path admitted for
small fixtures may retain its verified coordinate proposals, but its final A/J/F,
reconstruction T and incidence P use the same CSR Prepared representation.

The sparse path assembles exact primitive adjacency directly into pre-admitted
row tables. It finds connected components of actual zero-C rows and eliminates
each with the existing verified local solve, inserting every Schur boundary-pair
contribution outward. Fill is admitted before mutation. No resistance/capacitance,
boundary pair or small-valued interval is dropped. Structural anchored-R positivity
and the Schur-complement theorem preserve reduced-G positive definiteness; local
elimination pivots are independently verified.

Positive off-diagonal CAP incidence partitions Cr into exact independent blocks.
Ground/source/receiver capacitance remains diagonal and does not merge these
blocks. Verify each block positive definite with the existing dense LDL/solve
implementation, then solve only the reduced-G and Lr columns structurally incident
on that block. All possible block-inverse fill is retained in CSR A/J; no global
C inverse or global matrix product is allocated. Identity coordinates use T = W;
the finite local CAP-block batch above additionally uses T = W Q and the full
transformed sparse neighbor pattern. If no candidate passes, preparation returns
typed inconclusive without a global dense modal solve. No source/coupling partition
is silently excluded from the required problem.

With the census above, dense mass-block work scales with sum(blockSize cubed),
and retained operator work/storage scales with admitted sparse structure and fill.
The iterative solve cost additionally depends on observed iteration counts and
condition; structure alone cannot certify its duration or mathematical success.

### Global Source Slope Authority

For every dynamic source, rise/fall slew intervals are finite and strictly positive.
With the selected normalized threshold spans dr and df, the all-history bound is

```text
S[j] = max(dr / riseSlew.lowerBound, df / fallSlew.lowerBound)
```

Constant sources have S[j] = 0 and cannot be requested as dynamic transitions.
Primary input and clock intervals come from admitted explicit source constraints.
Cell source intervals come from the source-qualified TimingCore range API and
cover every relevant arc/edge and the full admitted characterized input-slew
domain at the exact retained prescribed boundary load. For this fixed-load model,
unused output-load table coordinates are not reachable source conditions and need
not enlarge the interval. The boundary load and source/table identity remain bound
to the range receipt; this is a model-preserving restriction, not an inferred quiet
or phase premise. Where the model actually admits a load interval, that entire
interval must be evaluated. A
single executed lookup or observed path does not establish a global lower slew.
Every reachable table subregion and any allowed boundary rule participates in
the positive minimum. Unavailable authority, a nonpositive minimum, unsupported
extrapolation, unknown transitions, source ranges outside the admitted domain, or
incompatible threshold conventions fail before a certificate is published.

Path/clock composition propagates receiver slew intervals through full table range
evaluation. It cannot assume LUT monotonicity or sample only a maximum-slew point.
The existing prescribed-source NLDM load equation remains an explicit, retained
approximation in this model. The numerical solver does not infer a transistor
drive or effective Miller load. Conservatism is relative to these prescribed
source ramps, not to the physical current/voltage response of an NLDM driver.

### Verified Comparison Certificate

The error equation is C e' + G e = -L u'. After supported algebraic elimination,
choose a finite full-rank coordinate matrix Q. The admitted small dense reference
may try identity first to preserve weak-coupling source sparsity, then ordinary
Cholesky whitening and bounded symmetric Jacobi candidates for (Gr, Cr). The sparse
profile uses the structural algorithm-3.12 order fixed above. A modal rotation can lose
source cancellation in absolute-value bounds even when coupling is weak, so modal
coordinates are not intrinsically tighter. Every candidate consumes the shared
work budget and maximumCertificateAttempts. Its finite entries define an exact
coordinate transformation, not an assumption that approximate eigenvectors or
eigenvalues are accurate. Every accepted candidate satisfies the same certificates.
The sparse profile restricts Q to the finite local CAP-block batch above; the
general formula also describes the admitted small dense reference path.
Preparation may stop at its first valid
operator/stability/radius certificate. A later response-query proof failure is a
typed inconclusive result even if another coordinate system might succeed; no
query-time basis search or reconstruction is required. No quota, cancellation,
source-owner or fatal numerical failure is caught to advance to another
certificate. In algorithm 3.13.1 the residual method occupies ordinal slot 4 after
all available comparison candidates fail, only if maximumCertificateAttempts >= 4.
Its ordinal remains 4 for the singleton profile. The same Reduced and accounting
owners continue; no graph reconstruction or budget reset occurs.

Let W reconstruct eliminated error rows and let T = W Q. With outward arithmetic,
verify

```text
M = transpose(Q) Cr Q is positive definite
K = transpose(Q) Gr Q
A = -inverse(M) K
J = -inverse(M) transpose(Q) Lr
F[i,i] = upper(A[i,i])
F[i,j] = upper(abs(A[i,j])) for i != j
w > 0 and F w <= -alpha w, alpha > 0
r = upper(abs(J)) S
p >= 0 and -F p >= r
E = upper(abs(T)) p
```

The package-only TimingCore TimingNumericInterval helper owns outward interval
primitives. It provides finite lower/upper bounds, throwing point/range construction,
and outward adding, subtracting, multiplied(by:) and divided(by:) operations;
invalid arithmetic fails. This component consumes it and the existing source-
qualified parser/range APIs rather than implementing another literal/source parser.

Interval A/J contain the exact transformed matrices; F is a Metzler comparison
matrix. The w/alpha inequality proves stability. The p inequality proves the
invariant bound |y| <= p for every admitted bounded operating history, hence
|v - P u| <= E. Approximate solves may propose w/p; only outward-verified residual
inequalities admit them. Failed attempts may refine Q within remaining cumulative
work, but an ordinary residual tolerance never grants certification.

The same comparison system bounds source-separated forcings. For a requested
source k, verify pOwn >= 0 and pAgg >= 0 with

```text
-F pOwn >= upper(abs(J[:,k])) S[k]
-F pAgg >= sum(j != k, upper(abs(J[:,j])) S[j]) = rAgg
```

This avoids assuming independent physical realization of extrema. Relaxing source
correlation only enlarges the result. No observed grid or cycle agreement is used.
Preparation computes and verifies pOwn, pAgg and rAgg once per dynamic canonical
source and retains them immutably. rAgg is an outward sum of the other source
forcings, not a subtraction of independently rounded total/own upper bounds.
Constant-source zero forcing requires no dynamic source certificate. Sparse point
proposals remain untrusted until their final p inequalities above are verified.

### Source/Output-Local Residual Certificate

The user-declared input family is the full-phase, full-operating-history family of
nonoverlapping full-rail linear ramps specified above. This clarification does not
add a settled state, logical correlation, quiet interval, or single phase. The
following exact physical equations use the same immutable Graph.Reduced, after
verified zero-C Schur elimination:

```text
A = -inverse(Cr) Gr; J = -inverse(Cr) Lr
g_ij(t) = W_i exp(A t) J_j
h_ij(t) = W_i A exp(A t) J_j = derivative(g_ij(t))
D = P + W J; integral(h_ij, 0 ... infinity) = -W_i J_j
D + integral(h, 0 ... infinity) = P
```

A/J here describe mathematical operators; no dense inverse or global modal matrix
is required. All C-block solves and reconstruction retain exact physical source
and receiver identities. The ordinary candidate backend uses deterministic Native Swift sparse
factors/solves on the supported macOS platform. It grants no authority:
backend success/status, residual tolerance, grid agreement and point trajectories
are all proposals. A platform without this capability returns typed unsupported;
there is no silent alternative backend. The bounded native adapter exception below
owns bounded raw-allocation routing; no allocation is implicitly waived.

A source/output-local L1 checker can certify a point trajectory without scalar F.
Let R_i be a verified upper bound on W_i inverse(Gr) transpose(W_i), and let
normGinv(q) enclose sqrt(transpose(q) inverse(Gr) q). For the stable physical
charge-input impulse kernel, spectral weighted Cauchy-Schwarz proves

```text
integral(abs(W_i exp(A t) inverse(Cr) q), 0 ... infinity)
    <= sqrt(R_i) * normGinv(q)
```

This bounds only the residual/defect; the signed receiver/source candidate retains
its locality. For a continuous piecewise-linear candidate xhat with steps dt,
Delta = xhat_next - xhat_prev, and rSolve = Cr Delta/dt + Gr xhat_next, its
continuous ODE residual is rSolve - (1 - theta) Gr Delta. Consequently the L1
error of the candidate, truncated to zero after T, is at most

```text
sqrt(R_i) * (normGinv(qInitial)
  + sum_steps dt * (normGinv(rSolve)
                     + 0.5 * sqrt(transpose(Delta) Gr Delta))
  + normGinv(Cr xhat(T)))
```

Every norm, sum, product and square-root upper bound requires independent outward
verification. A point sparse solve does not establish normGinv. A checker must
retain finite independent Gr inverse/residual authority, the structural anchored-R
proof and the exact operator represented by admitted primitives. Scalar sqrt
proposals require a verified squared upper enclosure; an arbitrary epsilon or
unchecked system sqrt is insufficient. Signed interval residuals include operator
assembly and solve uncertainty. Initial, solve, interpolation and terminal-tail
errors remain separately attributable and all participate in the result.

The g initial charge defect is -L_j - Cr xhat_g(0). The h initial charge defect is
-Gr J_true_j - Cr xhat_h(0), using an independently verified C-block enclosure for
J_true_j. Replacing J_true by its ordinary candidate and omitting Gr times that
candidate error is invalid, especially at the measured high physical rates. The
terminal charge expression accounts for the complete omitted infinite future;
finite-horizon truncation alone is not a certificate.

Given certified source/output L1 gains Gij and Hij and suffix Htail_ij(delta),
the existing threshold/unique-event contract would admit the sufficient bounds

```text
E_i = sum_j S_j * Gij
M_i = sum_j S_j * (abs(Dij) + Hij)
minimumDerivative = mLower
  - (S_k + mUpper) * Htail_ik(deltaMin)
  - sum_(j != k) S_j * (abs(Dij) + Hij)
deltaMin = (min(receiverThreshold, lowerSlewThreshold) - E_i) / mUpper > 0
```

These use the original global admitted S_k for own prehistory and cover the full
query slope interval. A suffix may conservatively include the entire trajectory
error plus its candidate suffix; it must never subtract independently rounded
upper bounds to invent a tighter error. SI seconds are used in all Cr + dt Gr
systems; g L1 has seconds, h L1 and D are dimensionless, and S/m have inverse
seconds. Conversion to the host Liberty time unit occurs at its existing boundary.

The one approved saved-data fixed-load reweight gives candidate E_i from 0.00170
to 0.01730 at the eight required receivers. These are ordinary feasibility values,
not source-qualified range receipts or certified results. All eight sufficient
derivative lower bounds remain negative. Even with numerical error and own-history
tail artificially removed for diagnosis, clock0's aggregate term 5.069/ns exceeds
mLower 3.634/ns, and D1's 4.018/ns exceeds 3/ns. Thus finer grids alone cannot
close this particular response gate. This diagnoses certificate insufficiency;
it does not prove actual repeated crossings in the corrected source family.
The former 20 ps waveform witness used a BUF slew outside the corrected fixed-load
range and is not a counterexample to that range.

This first residual kernel uses this unchanged sufficient unique-event gate. Its
failure is typed not-certified and grants no finite Bounds; implementation
correctness does not promise that this sufficient gate passes the actual design.
The declared full-ramp family may support a later sharper certificate, but the
present kernel may not assume such a result. No first/last-crossing substitution
is permitted: possible extra clock crossings create additional sequential events
and invalidate the existing single-event NLDM/clock/path composition.

#### Higher-Order Candidate and Independent Continuous Checker

The initial ordinary proposal is three-stage Alexander SDIRK with finite binary
gamma = 0.435866521508459, a21 = (1-gamma)/2,
a31 = b1 = -1.5 gamma^2 + 4 gamma - 0.25,
a32 = b2 = 1.5 gamma^2 - 5 gamma + 1.25 and a33 = b3 = gamma.
For each stage, solve (Cr + dt gamma Gr) Yi = Cr x0 - dt sum_(j<i) aij Gr Yj;
x1 = Y3. A single shifted factor serves every stage and all source columns in that
step. Point derivatives f0/f1 propose -inverse(Cr) Gr x0/x1 using the existing
small physical C-block decomposition. Cubic Hermite interpolation proposes

```text
p(theta) = c0 + c1 theta + c2 theta^2 + c3 theta^3
c0 = x0; c1 = dt f0
c2 = 3 (x1-x0) - dt (2 f0+f1)
c3 = -2 (x1-x0) + dt (f0+f1)
```

The candidate's formal order and stability grant no authority. Its finite binary
coefficients are converted to four exact-point cubic Bernstein state coefficients
B0...B3. The independent checker verifies positive finite step times, exact grid
coverage, B0 equal to the admitted initial point and each following B0 equal to
the previous B3. Missing continuity would introduce a charge impulse and fails;
it cannot silently omit that error.

For arbitrary such point coefficients, let dk = 3 (B_(k+1)-Bk)/dt, k=0...2.
The derivative elevated to cubic Bernstein coefficients is d0,
(d0+2d1)/3, (2d1+d2)/3, d2. Compute each physical residual coefficient
rk = Cr derivative_k + Gr Bk outward. Convexity of the Gr-inverse norm proves

```text
integral_step normGinv(residual(t)) dt <= dt/4 * sum_(k=0...3) normGinv(rk)
```

For separate diagnostics, charge dt normGinv(r0) as solve error and bound the
remaining Bernstein residual variation as interpolation error. Derive differences
algebraically before interval evaluation where possible; never cancel two
independently rounded bounds. Both contributions are included, without assuming
an O(dt^p) formula or accepting an ordinary norm tolerance.

The Gr-inverse norm checker retains an exact-point positive w with outward
Gr w >= d > 0. Structural Gr is a symmetric anchored Stieltjes matrix. Given an
ordinary candidate z for inverse(Gr) b, verify r = b - Gr z and

```text
t = max_i upper(abs(r_i)) / lower(d_i)
transpose(r) inverse(Gr) r <= t * sum_i upper(abs(r_i)) * w_i
transpose(b) inverse(Gr) b
  = 2 transpose(b) z - transpose(z) Gr z
      + transpose(r) inverse(Gr) r
```

This independently encloses the norm from one native point solve and outward
products. The same checker with b = transpose(W_i) gives R_i. A negative or
nonfinite squared upper result fails; a square-root proposal must pass its outward
squared-upper test. Native factor success or residual stopping is never the proof.
The local C-block verifier encloses true J; initial defects retain its entire
interval, including the Gr times J uncertainty in h.

#### Internal Boundaries and Streaming Ownership

All types below remain internal to STAEngine; the existing host protocol and
public DTO stay unchanged. N abbreviates NativeSTAConservativeNumerics.

```swift
internal struct NativeSTAConservativeResidualCandidate {
    let numerical: NativeSTAConservativeNumerics
    struct Segment {
        let start: Double
        let end: Double
        let bernstein: [N.Matrix] // Exactly four physical n-by-2s point matrices.
    }
    struct Session: ~Copyable {
        func solveG(_ rhs: N.Matrix, into result: inout N.Matrix,
                    work: inout UInt64) throws
        func stream(initial: N.Matrix, times: [Double], work: inout UInt64,
                    consume: (Segment, inout UInt64) throws -> Void) throws
    }
    static func withSession<R>(
        reduced: NativeSTAConservativeSparseGraph.Reduced,
        numerical: N, work: inout UInt64,
        body: (borrowing Session, inout UInt64) throws -> R
    ) throws -> R
}

internal struct NativeSTAConservativeResidualCertificate {
    let numerical: NativeSTAConservativeNumerics
    struct Segment: Sendable {
        let start: Double
        let end: Double
        let bernstein: [N.Matrix] // Four receiver-by-2s interval matrices.
    }
    struct Errors: Sendable {
        let initial: N.Matrix
        let solve: N.Matrix
        let interpolation: N.Matrix
        let tail: N.Matrix
    }
    struct Facts: Sendable {
        let receiverRows: [Int]
        let sourceCount: Int
        let segments: [Segment]
        let errors: Errors
        let direct: N.Matrix
    }
    func prepare(_ reduced: NativeSTAConservativeSparseGraph.Reduced,
                 receiverRows: [Int], times: [Double],
                 work: inout UInt64) throws -> Facts
}

internal struct NativeSTAConservativeResidualResponse {
    let numerical: NativeSTAConservativeNumerics
    struct Facts: Sendable {
        let receiverRows: [Int]
        let sourceCount: Int
        let gL1: N.Matrix
        let hL1: N.Matrix
        let direct: N.Matrix
        let hSegments: [NativeSTAConservativeResidualCertificate.Segment]
        let hError: N.Matrix
    }
    func prepare(_ certificate: NativeSTAConservativeResidualCertificate.Facts,
                 work: inout UInt64) throws -> Facts
    func bounds(prepared: NativeSTAConservativeCoupling.ResidualPrepared,
                source: TimingParasitics.Endpoint,
                sink: TimingParasitics.Endpoint, edge: TimingEdge,
                sourceSlew: ClosedRange<Double>,
                work: inout UInt64) throws -> NativeSTAConservativeCoupling.Bounds
}
```

The candidate Session is synchronous, prepare-local, noncopyable and non-Sendable.
A private Core owns native factors/workspaces; withSession encloses its serialized
lease and registers idempotent nonthrowing cleanup with defer immediately after
construction. Its borrowing Session cannot escape into the copyable return value,
Prepared or a callback. solveG writes to pre-admitted exclusive checker scratch
reused across norm checks, rather than constructing another output at every call.
One complete step is passed synchronously to the internal consume closure; the checker
immediately validates residuals, projects W and releases full physical state
coefficients before the next step. No n-by-source-by-entire-grid history is kept.
All matrices carry columns [g for every canonical source, h for every canonical
source], including exact constant zero columns where applicable. Checker Errors
are aggregate receiver-by-2s L1 upper bounds including the receiver sqrt(R_i).
Direct is the interval receiver-by-source D, not an independently rounded absolute.
ReceiverRows identifies exact physical W rows; shape, ordering and coverage are
validated at both boundaries. Canonical required receiver selection belongs to
composition and cannot be inferred solely from a positive pin-load value.

For receiver Bernstein coefficients bk, the main integral upper is
sum_steps dt/4 sum_k upper(abs(bk)); this is a certified polynomial bound rather
than sample agreement. Response adds all four error components, retains only
h-column projected segments and hError, and discards checker g trajectories.
Suffix evaluation uses outward de Casteljau subdivision at the actual delta and
adds the entire hError; no query-time sparse solve or hidden refinement occurs.

| Owner | Files/responsibility | Verification owned |
|---|---|---|
| Native candidate | Deterministic Native Swift session, sparse factor lifecycle, SDIRK3/cubic point stream | Native capability/status/cleanup, point differential and finite resource/cancel failures |
| Numerical checker | New ResidualCertificate, verified local C/J, Gr weight/norm identity, streamed residual and physical projection | Initial true-J defect, cubic residual enclosure, forged point/projection/continuity refusal, budget and source-owner propagation |
| Response gains | New ResidualResponse, main/suffix Bernstein bounds and unchanged unique-event response | Signed/zero/local gain, suffix splitting, positive completion versus reversal/unproved-event refusal, full query-slope interval |
| Kernel composition | Existing Coupling/Graph, Prepared variants, receiver admission, fixed dispatch and shared context | Exact primitive/source binding, no accounting reset, comparison regression and actual residual selection |

The residual projection retains exactly the externally queried receiver set.
The host owns that complete set, including zero-load output ports, clock/control
receivers and every queried input pin. The current wire-preparation path establishes
that receiverLoads.keys contains every required host query, including zero-load
output ports; no new host declaration is needed. The kernel uses ALL these keys,
without a nonzero-load filter. The actual primary set has eight keys: four FF D/CLK
inputs, two BUF A inputs and two zero-load top outputs. Prescribed-source aliases
use the exact analytical path. This checked coverage obligation belongs to wire
preparation and must remain true when host query behavior changes. A parser's
network.connections array is not an external receiver inventory: SPEF *CONN *N
entries may also name every internal RC node. The kernel therefore must not union
all connection rows into the residual trace set merely because they are preserved
connections. Shape/endpoint bindings and required-receiver coverage remain strict.
An untraced queried sink fails explicitly as unproved; it never receives a point
fallback or silently disappears from a completed report.

Every internal RC node, primitive, coupled source and Schur/reconstruction mapping
remains in the full dynamic system. Only receiver projection/retention changes.
The concrete nominal census exposed 5,634 internal *N connections plus 15 pin
connections; their union selected all 5,627 unknown rows. Four coefficients times
5,627 rows times 14 source columns reserved 315,112 slots per segment: 200
segments alone require over 63 million slots, before the 16-million-slot native
reservation. The fine proposal grid requires at least 404 slabs from its seed/
horizon ratio and sqrt(6/5) growth: at least 127,305,248 projection slots plus
16 million native slots cannot fit the 64-million-slot request. The retained
actual nominal attempt reached that shared limit after approximately 114 seconds,
before downstream response construction. This is a demonstrated projection
inventory defect, not evidence that internal dynamics or coupling may be removed.
Receiver-sized traces close this specific resource gap while preserving the same
physical response and completed-result requirements.

#### Bounded Residual-Checker Checkpoints

The actual dimensions imply approximately 940,000 removable cancellation/source-
resource checks per slab in these candidate/coefficient operations; this is not
the total number of all residual-checker checks. The checker may batch only declared natural finite operations:
validation of one complete point-coefficient/candidate array, or one complete
Gr-inverse norm column. Its existing dimension/nonzero admission bounds each
operation. Before computing it, pre-admit the checked sum of the existing work
charges for that whole operation and run the original cancellation, deadline and
source-owner check. Execute exactly the same interval primitives, coefficient
validation, residual products and scalar reduction order. Immediately before any
normal completion/return, call the same numerical tick with zero additional work
to recheck cancellation, deadline and the source owner.

Every successful operation has the same total charged work and arithmetic result
as before. Insufficient capacity fails before the whole operation. An invalid
coefficient/arithmetic error discovered inside the operation remains that typed
failure and is never caught, clamped or converted to success. No successful return
can bypass the postcheck. This is not an arbitrary chunk size, a global tick switch,
a new backend or a weaker outward certificate. It does not group multiple slabs,
columns or unrelated checks into an unbounded interval. Existing native shared-
state, unsafe ownership, pointer-lifetime and cleanup contracts are unchanged;
their prior evidence remains applicable because this change does not alter them.
Meaningful tests compare exact successful work/result order, pre/post refusal,
invalid-input propagation and required receiver completeness.

The initial point-proposal grid is deterministic and scale-aware. Let minFullRail
and maxFullRail be the minimum and maximum positive full-rail durations from every
admitted rise/fall source-slew interval divided by its selected normalized threshold
span. Constants do not contribute. Let minRatio be the minimum positive midpoint
Cr[i,i]/Gr[i,i]. Set seed = min(minRatio, minFullRail) * Double.ulpOfOne and
horizon = 2 * maxFullRail. Both must be finite and strictly positive. Start at zero,
append seed (or horizon if smaller), then grow positive time by the ordinary point
ratio sqrt(sqrt(6/5)), clipping the last point to horizon. The finite binary square-root
proposal affects only grid selection, not numerical authority. The measured
SDIRK feasibility run used this fine ratio: its h residual bound 0.0118 permits
positive root-BUF-input derivative candidates, whereas the coarse 6/5 ratio
produced 0.083. The new fourth-root ratio doubles steps relative to that fine
proposal to address the measured dominant cubic interpolation error; only the
actual outward checker can establish the improvement. Every append consumes checked shared
work/storage; every next point must make strict finite progress. There is no guessed
hard step count and no reinterpretation of maximumBasisSweeps. Request ceilings
bound generation; inability to reach a valid horizon is typed not-certified or the
original capacity failure. This grid is an operational proposal only: the continuous
residual and terminal-tail checks, not the seed or horizon choice, prove its error.

Every candidate/checker factor, fill, trace, interval temporary, failed refinement
and native lower-call boundary uses the original cumulative work/storage,
source-owner and cancellation limits. A request-scoped finite time grid is an
untrusted numerical proposal and never enlarges the history family. Source-box
refinement reuses the prepared graph/gain facts and recomposes response bounds
under the same owners; it does not reset counters or turn unconverged estimates
into evidence. Unsupported native capability is
explicit. Fatal arithmetic/backend errors, quota, cancellation and source failures
propagate and cannot be caught as a certified-candidate retry.

#### Monotone Source-Domain Refinement

Initial cell source ranges cover the full admitted characterized input-slew domain
at exact fixed loads. If a required receiver has a completed unique-event/slew
certificate under box B0, its entire resulting slew interval is valid for every
history in B0. The owning path/source coordinator may evaluate each downstream
owned cell arc over that whole certified input interval and the same exact load,
and intersect the result with B0's output source range to obtain B1. Range receipt
identities remain retained. The prerequisite receiver certificate must cover all
relevant predecessor transitions, rise/fall directions, admitted upstream slew
ranges and arcs for the refined source; one executed path or a point query is not
a global reachable-input range. This uses only the original prescribed-source
NLDM input/output-slew relation, without adding a root/branch phase relation.
Since every actual modeled history is in B0 and obeys that original owned arc
relation, every such history remains in B1. Subsequent certificates
are recomputed/reweighted with B1 only after B0's prerequisite is proved.

No point observation, failed uniqueness query or assumed timing-check pass may
shrink a source range. Cycles cannot justify each other's first refinement; a
predecessor certificate must already be established in the previous box. If an
intersection is empty or loses a required arc/direction, fail rather than suppress
that history. Initial source errors are not silently accepted by fixed-point
iteration.

The coordinator prepares the primitive graph and receiver/source gains once. In
each round every upstream input uniqueness/slew query reads the same OLD source
box. Only after all relevant propagation/control arc inputs and directions of a
cell driver are proved does it evaluate that driver's output ranges and publish a
simultaneous intersection update for the next box. This prevents iteration order
from mixing new-box assumptions with old-box certificates. Constants, source
identity, load, output edges and source/table authority remain unchanged.

The kernel provides the internal operation:

```swift
func restrictSources(prepared: NativeSTAConservativeCoupling.Prepared,
                     to sources: [NativeSTAConservativeCoupling.Source],
                     work: inout UInt64) throws
    -> NativeSTAConservativeCoupling.Prepared
```

The replacement array has the same count and exact positional endpoint order,
source case, port/cell role and constant voltage as the previous array. Every new
dynamic rise/fall interval is finite, strictly positive and a subset of its old
interval; widening, reordering, changed roles/constants or incompatible identities
fail explicitly. Source indices and endpoint mappings remain fixed. Recompute
source slopes from the selected threshold spans and the new minimum slews with
outward arithmetic, using the original accounting owners. This method validates a
restriction; only the coordinator's retained previous-box proofs authorize it.
A caller cannot manufacture authority by passing a narrower numeric interval.

ResidualPrepared reuses the identical immutable response-gain facts with the new
source ranges/slopes. ComparisonPrepared reuses its old E, radius and
sourceCertificates, including own/aggressor radii and forcings. Those old-box
envelopes remain valid over the subset; recomputing query source slopes does not
invalidate them. No extra graph, factor, checker, sparse solve or fabricated
tighter comparison radius is introduced. Query stationary scaling still encloses
the actual new query slope range. Both variants retain the same exact primitive,
source and threshold identities.

Round control is deterministic while-changed with the same cumulative work,
construction-slot, source-owner, cancellation and deadline charges on every round
and query. Stop on bitwise unchanged intervals or no proved update. There is no
new arbitrary round cap and maximumCertificateAttempts retains its existing
candidate-attempt meaning. Existing finite request budgets bound even an endlessly
shrinking sequence; exhaustion propagates its typed failure. Retain every prior-
box certificate on which a published restriction depends. Stopping without further
proved shrink grants no missing event certificate. This remains coordinator
composition, not a wrapper, quiet/phase condition or initialization premise.

### Staged Source-History Certificates

The selected history refinement uses original owned clock/BUF and qualified FF
semantics. It introduces no new CQ/glitch response assumption. The exact graph,
native candidate, numerical gain facts, all-phase histories and existing completed
unique-event guarantee remain unchanged. Parent integration binds the changed
algorithm/proposal policy with a fresh exact producer/hash/reader identity; model,
public source/receipt grammar and completed-result meaning remain unchanged.

Cell source authority retains separate rise/fall output-slew ranges over every
relevant owned arc and its full admitted input domain at the same fixed load.
Previous-box refinement preserves those directions rather than merging their
minimum/maximum. Let Sr and Sf be the resulting directional slope upper bounds,
c = (Sr-Sf)/2 and r = (Sr+Sf)/2. Since u' = c + r xi with |xi| <= 1 and the exact
physical identity D + integral(h) = P holds, each source derivative contribution is
in c P +/- r (abs(D) + hL1). For every other resistive driver P = 0: its unconditional
radius uses the average directional slope r, with the existing certified h error
already in hL1. No positive/negative gain matrices are required. Existing own-
history and voltage bounds may retain the larger max(Sr,Sf) overbound.

The kernel adds only this internal history value/API; absent history is unrestricted:

```swift
internal enum NativeSTAConservativeSourceHistory: Sendable, Hashable {
    struct Clock: Sendable, Hashable {
        let rootIdentity: String
        let period: Double
        let riseReference: ClosedRange<Double>
        let fallReference: ClosedRange<Double>
    }
    case clock(Clock)
    case minimumPlateau(seconds: Double)
}

func addingSourceHistory(
    prepared: NativeSTAConservativeCoupling.Prepared,
    histories: [TimingParasitics.Endpoint: NativeSTAConservativeSourceHistory],
    work: inout UInt64
) throws -> NativeSTAConservativeCoupling.Prepared
```

Clock references are SI-second source threshold-crossing windows relative to one
owned primary-root cycle origin. For each integer n, windows translate by n*period;
per-cycle delay/slew variation is retained, not assumed identical. Global root
phase remains arbitrary and cancels only between facts with the same exact root
identity/period. Source rise/fall intervals remain the sole duration authority.
The owner validates source endpoint/role, selected corner/mode/load/Liberty and
root/edge/lineage receipts against the same immutable scenario. No public request
can supply an unvalidated history or a certification flag. Lower admission checks
canonical source presence, finite ordered windows, positive period/gap, dimensions
and consistent existing facts; unknown, gated or otherwise ineligible sources
remain unrestricted. Both Prepared variants reuse their existing numerical facts;
comparison may retain its old all-history bounds.

ClockPropagation first proves every available BUF-cone input frontier under the
OLD source box/history, evaluates its already owned function/unate arc and full
Liberty ranges, then publishes that frontier's source windows. All BUF cones are
completed before any FF-leaf query. Each publication intersects the old per-edge
source range with its proved wave-slew range (empty intersection fails), then uses
restrictSources and adds history in one atomic old-proof batch: source authorities,
Prepared and cache generation commit together, reusing numerical facts. Roots
remain unchanged. Same-frontier facts cannot prove each other.
The root SDC clock record supplies only its original declared waveform authority.
Q remains completely unrestricted throughout this stage and the FF CLK proof.

The existing bounds signature is unchanged. If its own canonical source has a
stored clock history, source/edge and the complete query slew interval determine
the root-relative query band B containing ALL receiver, lower-slew and upper-slew
crossings. Derive it outward from the source reference interval and each
(q +/- E - qSource)/m offset, including the entire slope range. The whole band,
not only the 50-percent time, must satisfy any segment condition. Other source
clock facts can be compared only with that same root/period. Their full-ramp start
and end windows follow from reference - qSource/m and reference + (1-qSource)/m,
with the source's own direction, thresholds and complete duration ranges.

If B is strictly after the latest possible start and strictly before the earliest
possible end of one current linear segment, delta = B.lower - latestStart > 0 and
that cross-source derivative radius is at most
(Smax + maxAbsCurrentSlope) * Htail(delta). For a proved plateau covering all B,
delta is measured from the latest previous ramp end and the radius is at most
Smax * Htail(delta). These follow from P=0 and the same fixed-slope tail identity
used for the own source. Consider all periodic windows needed by the admitted
intervals; no favorable cycle, quiet phase or guessed separation is selected.
Absent containment, retain the unconditional centered radius. Take only the minimum
of independently valid radii. Every suffix includes its complete infinite-history
residual error and terminal tail. Queries without own clock history retain unknown
phase; no duplicate caller clockQuery argument is introduced.

Only AFTER all required FF receiving CLK rise/fall transitions are certified unique
may the existing sequential owner add a Q minimumPlateau fact. Eligibility requires
its exact supported FF/unary-state output, no asynchronous or additional controls,
validated normal power and the already qualified CQ arrival/slew receipts. It does
not apply a CQ table to a nonunique/glitch input. With receiving active-edge period
P and each Q output-edge arrival interval Ae, let teMax be its full-rail duration
upper bound and qe its own normalized reference fraction. Set
L = min_e(Ae.lower - qe*teMax), U = max_e(Ae.upper + (1-qe)*teMax).
A positive outward lower bound P+L-U is a minimum plateau between Q transitions.
Arbitrary initial state, either output direction, held Q and skipped cycles remain
allowed: each qualified active clock event produces at most one state transition.
Nonpositive or unproved gaps supply no history fact. Clock uniqueness is never
justified by assuming this later Q fact.

For any source with a proved minimum plateau at least the retained h horizon T,
at most one nonzero ramp interval intersects the history window [0,T]. This can
also be established from a clock record's verified adjacent ramp windows. Let F
be the signed primitive of the candidate h polynomial on that window and let
osc(F) upper-bound max(F)-min(F). Its cross-source radius is at most
Smax * (abs(D) + osc(F) + hError). hError is the complete initial/solve/interpolation/
terminal error, added ONCE per source, so the infinite past is still enclosed.
Compute primitive extrema outward using integrated Bernstein coefficients (degree
four) and their convex hulls; no sampled extrema grant authority. Minimize with the
old centered radius. This isolated-event gain supports arbitrary DATA query phase;
it assumes neither Q's phase nor that Q changes on every clock cycle.

Wire preparation owns history publication and its checked monotonically advancing
generation. Every response-cache key includes that generation, so conditional
bounds cannot leak into a query using other facts; source-box updates also preserve
their existing invalidation. Phase facts derive only from retained owned waves;
sequential facts derive only after their prerequisites. Fresh source validation
replays this stage order and exact source/clock/receipt bindings, rather than
trusting serialized history claims. All maps, generations, period-window traversal,
primitive gains and failed conditions use the original cumulative work/storage,
cancellation/deadline and source owner. No counter reset, new public accuracy field
or mutable global history is added. Existing native unsafe-buffer/allocator paths
are unchanged, so their prior scoped ASAN evidence remains applicable.

Behavioral verification distinguishes missing/wrong-root/uncontained phase fallback,
whole-band containment, arbitrary global phase, per-edge centered radius, Q-before-
clock refusal, arbitrary initial/held/skipped Q, insufficient plateau fallback,
signed primitive oscillation plus one full error, generation-isolated caches and
complete required source/receiver replay. Actual success still requires every
required net/edge/corner under its caller budgets; an unproved case remains typed.

### Threshold and Unique-Crossing Certificate

Work in normalized rising progress; falling transitions complement physical voltage
and thresholds. For a full-rail ramp starting at t0 with positive slope m and sink
error E[i], require E[i] < min(lowerThreshold, 1 - upperThreshold). Then every
admitted waveform starts below the lower threshold and ends above the upper one.
For a threshold q its crossing is confined to

```text
t0 + (q - E[i]) / m <= crossing(q) <= t0 + (q + E[i]) / m
```

Bounds use outward operations. Delay subtracts the actual selected source threshold
crossing. Slew subtracts the two receiver threshold crossing intervals. Source
slew ranges map to positive slope ranges through the selected threshold span;
interval evaluation covers their entire continuum, rather than assuming that
endpoint evaluations of the final formula suffice.

To preserve the existing single-transition semantics, every completed result also
proves a strictly positive derivative throughout the possible crossing band.
Let yStar solve A yStar = -J[:,k] m. The own-source prehistory is enclosed by
pOwn, so choose

```text
beta >= max_i((pOwn[i] + abs(yStar[i])) / w[i])
deltaMin = earliest possible lower-threshold crossing - t0 > 0
decay >= exp(-alpha * deltaMin)
transient = w * beta * decay
minimumDerivative >= m - abs(T) * (abs(A) * transient
                                      + abs(A) * pAgg + rAgg)
```

All magnitudes and inequalities use outward intervals; yStar and beta cover the
full admitted m range. The final lower bound must be strictly positive at every
queried receiver. The own ramp remains fixed over the whole band. This proves
one crossing of each threshold; voltage guards exclude additional crossings
elsewhere within that source transition.

Preparation also verifies a unit-slope equilibrium column yUnit for each dynamic
source, satisfying A yUnit = -J[:,k], and retains its interval enclosure. Each
query obtains yStar by outward multiplication of this column by the actual signed
source-slope interval. The own prehistory radius still uses the global admitted
S[k], never the query's potentially narrower slope. This reuse changes neither
the stationary equation nor the history set and avoids iterative solves per sink.

Scalar decay uses a proved upper bound such as (1 + x/n)^(-n) for x >= 0 and an
admitted positive integer n, evaluated outward. Increasing n spends cumulative
work and tightens the bound. No arbitrary exp epsilon or empirical fit is used.

A finite upper derivative also bounds the minimum possible slew:

```text
Dout = P + T J
maximumAbsoluteDerivative <= abs(Dout) S + abs(T) abs(A) p
minimumSlew >= (upperThreshold - lowerThreshold)
               / maximumAbsoluteDerivative
```

Intersect this positive lower bound with the threshold-time difference bounds.
This prevents a loose time-interval subtraction from inventing zero-slew source
authority downstream. Inconsistent intersections fail as invalid certificates.
Ideal-source aliases use their exact analytical ramp, preserving separate terminal
identities. Constants never acquire crossings.

## Runtime Flows

Preparation validates source authority, builds complete coupling components, admits
storage, constructs operators and numerical certificates, then retains immutable
Prepared facts, including source-separated radii and unit-slope equilibrium columns,
for the scenario. Their construction and storage are admitted and charged once
before publication. A response query validates its exact source/sink,
edge and entire slew interval; obtains the error and derivative certificates;
computes crossing/delay/slew intervals; and returns Bounds only after all conditions
hold. Both early/late data and clock consumers use these intervals, with their
separate wire derates, and retain the shared source-bound observations.

## State, Ownership, and Lifecycle

Prepared and all numerical arrays are immutable after successful preparation and
owned by the run-local scenario. Per-source certificates share that lifetime;
response queries reuse them without mutable cache insertion or iterative solves.
Cumulative logical construction-slot admission
uses the existing request-owned NativeSTAStateBudget with its common Mutex. Work
is charged through the existing inout request counter and source resource checks.
There is no global design cache, mutable process-wide design state or target-
dependent isolation. The narrowly scoped native allocator-routing exception below
is platform-adapter state, not logical design or certificate state. Releasing a temporary array does not refund cumulative slots.
Reserved slots are conservative logical construction charges, not measured
allocations, live bytes or RSS. The accounting owner enforces admission without
providing a measured resource-usage report.

## Failure, Concurrency, and Constraints

The implementation uses a typed error enum, with distinct cases for invalid source
authority, invalid primitive/binding, unsupported capacitance profile, unverified
operator/comparison certificate, unproved crossing, unproved unique transition,
unsupportedNativeCapability, nativeBackendFailure, and inconsistent numerical
bounds. Missing native capability is typed unsupported; backend arithmetic/status
failure is fatal. Neither is a completed observation. Endpoint and edge context accompany crossing
errors. Existing STAPathAnalysisError.capacity and cancellation errors remain
distinct and propagate unchanged. The parent may map these to typed diagnostics;
it cannot convert them to a finite conservative result or a completed observation.

### Residual Unique-Transition Failure Diagnostics

The existing internal unprovedUniqueTransition failure may carry an optional typed
context whose default is nil. Only the residual failure branch populates it. This
is failure evidence, not another certificate, waveform-method selection, public
receipt or reporting schema. Existing failure taxonomy and algorithm 3.13.1's
successful-result meaning, source model and unique-event contract are unchanged.
No event-packing implementation or new event authority is implied.

The branch first determines the failed scalar condition from the calculations
already used by bounds. It retains endpoint, edge and a fixed scalar summary in
local values before attempting diagnostic arrays. The optional complete context
contains E, mLower/mUpper, global Sown, deltaMin, own Htail, own hError, ownTerm,
aggregate aggressor term, Dmin/Dmax, retained trajectory horizon and segmentCount.
Its perSourceContributions has exactly the validated canonical source count s,
with each source's S, directAbs, hL1, hError and resulting upper contribution.
These entries use the same source ordering and previously computed gain facts;
constants retain their zero contribution. Values label the exact sufficient
condition that failed, not a proven physical glitch or an actual timing violation.

Before allocating or populating the s-entry array, checked source-count/storage
and work calculations pre-admit the whole bounded operation. The source count is
already bounded by the validated graph and original request budget; no new
arbitrary diagnostic cap is introduced. Cancellation, deadline and source-owner
checks run at the existing boundaries and before normal completion. No new matrix
solve, trace reconstruction, unconstrained full-waveform storage, unconditional
stderr dump, process-global diagnostic state or uncharged callback is permitted.

Diagnostic construction is fallible. Capacity, arithmetic, cancellation and
source-owner errors propagate explicitly as their original failures; they must
not be caught to publish finite Bounds, silently drop a partial context, or hide
an original capacity refusal. The precomputed fixed scalar summary establishes
the original unproved condition before this attempt. It is retained in the emitted
unproved error when construction completes and may accompany a later capacity
failure only through already supported bounded error context. An arbitrary owner
error is not replaced or masked merely to attach a diagnostic. There is no
independent allocating fallback after an admission failure, and no promise that
an error type without contextual storage can carry the entire original summary.
Tests distinguish a residual unproved context, the legacy nil-context case, exact
per-source accounting and diagnostic-capacity/owner failure propagation.

### Deterministic Native Sparse Cholesky and Bounded Allocation

Algorithm 3.15.0 uses one deterministic Native Swift sparse Cholesky proposal on
macOS with the Darwin allocation adapter. The previous SDK numeric factorization
is withdrawn: the captured 5,596-row identical CSR/RHS produced different fresh
factor solutions despite matching permutations, and factor-buffer zeroing and
single-thread BLAS did not restore replay. No SDK symbolic/numeric/solve calls or
alternate backend remain in this proposal. Point success still grants no numerical
authority; the independent continuous residual certificate remains unchanged.

The existing synchronous allocation lease and Mutex-protected quota/address
records remain the storage owner. Its quota is checked
floor(maximumPathStates / 4) * 8 bytes, pre-admitted once as quota / 8 logical
slots. Metadata uses floor(quota / (16 * Record.stride)) records, within that same
quota. All payload, including temporary and simultaneously retained factors,
counts toward both cumulative allocated bytes and peak live bytes. Raw buffers do
not receive a second construction-slot charge for storage already covered by this
reservation. No quota, record table, counter or cancellation owner is reset during
factor reuse. Payload failure, injected malloc failure and record exhaustion retain
their original typed failure; no allocation fallback is permitted.

For n rows, symbolic work owns exactly n * ceil(n / 64) UInt64 adjacency words,
with checked size/stride/byte arithmetic. Active degrees are exact integers. The
first elimination pass selects min(activeDegree, originalIndex), enumerates
neighbors in ascending original index, and joins each neighbor clique by fixed
word-order OR operations. Added-edge popcounts update degrees. It records the
permutation and exact column counts, including each diagonal. The bitset is then
reset from the same lower union pattern. A second pass follows the fixed recorded
order and emits the exact-sized CSC L pattern: each column scans remaining
permutation positions in ascending order, then performs the identical clique
update. No guessed fill buffer, graph dictionary, hash iteration or dynamic
symbolic growth is used. Structural counts and positions must agree in both
passes. All Int/Int32/UInt64/Double buffers use the same allocation lease; original
CSR matrices remain borrowed only for the synchronous construction scope.

The owner retains initialized raw CSC column starts, row indices, the permutation
and inverse permutation, base G/C midpoint arrays on that exact pattern, numeric
L values, and one n-entry solve scratch. Once construction completes, symbolic
bitsets, degrees and neighbor scratch are released; their bytes remain charged to
the cumulative quota. Input midpoint entries scatter by checked binary lookup
into the permuted pattern. Every factor call first marks the prior numeric state
unusable and reconstructs every value from sG * G + sC * C, including exact fill
zeros. It then performs right-looking Cholesky: columns ascend, off-diagonal rows
ascend, and rank-one target columns and rows ascend. Nonpositive/nonfinite pivots,
nonfinite updates or a missing structural target fail explicitly. Only a complete
factor marks the owner solvable. Repeating a factor uses identical inputs and
floating-point operation order, independent of allocator addresses or SDK state.

For every RHS column in original order, solve permutes into the retained scratch,
performs ascending forward substitution and descending transposed substitution,
then inverse-permutes into the caller's column-major array. Every arithmetic
result is checked finite. RHS storage is never retained or allowed to escape;
no solve allocation is necessary. The non-Sendable factor remains inside the
serialized noncopyable Session. close is idempotent and nonthrowing, deinitializes
each initialized range and releases it exactly once; partial construction/factor
failure and cancellation follow the same cleanup path before lease termination.
No raw pointer crosses an actor/task or escapes into shared routing state.

Work admission uses overflow-checked operation bounds before each finite symbolic
or numeric column and each RHS. Symbolic bounds cover degree scans, bitset word
updates/popcounts and pattern emission. Numeric bounds cover divisions and the
triangular rank-one update count times the bounded binary-search depth. Solve
bounds cover permutation and both triangular traversals. Every column boundary
and solve boundary checks the same cancellation/deadline/source owner; finite
budgets fail before the corresponding batch. This replaces the opaque SDK n^3
and n^2-RHS admission proxy with explicit owned operation bounds, without hidden
counter relaxation. No Linux/WASM/Embedded capability or threading semantics are
inferred from this macOS implementation.

Behavioral evidence must cover independent SPD solves, fill-producing sparse
patterns, shifts and ill-conditioned physical RC input, exact fresh-owner/reused-
owner/refactor replay, multiple RHS ordering, nonpositive pivots, malformed input,
allocation/quota/record/work/cancellation failure and complete cleanup. The saved
5,596-row production CSR/RHS replay is the required actual-scale determinism
check; small matrix success alone does not qualify the actual preparation path.

For the observed nonpositive sparse comparison-weight proposal, the existing
refusal branch may retain a bounded diagnostic using two outward matvecs:
h = (-F) w - 1 and F z, where z = max(-w, 0). If F is Metzler, z is nonnegative
and nonzero, and F z is verified nonnegative, F is not Hurwitz: a Hurwitz Metzler
matrix would have inverse(F) <= 0, contradicting z = inverse(F) F z. Rows with
z[i] = 0 have nonnegative F z by exact off-diagonal sign; positive-support rows
require the outward inequality directly or the verified relation
F z >= 1 + h on that support. Diagnostics retain the true residual, weight range,
negative-entry count and witness inequality facts under the same work/storage and
cancellation checks. Without a verified witness, only proposal failure is known.
This failure-snapshot diagnosis neither changes the refused result nor grants
finite timing authority, and is not an alternative successful certificate.

The same failure-only diagnostic may also retain principalNonHurwitzWitness,
either diagonal(row, coefficient) or reciprocalPair(first, second,
firstDiagonal, secondDiagonal, forward, reverse, determinantUpper). For a finite
exact-point, validated CSR Metzler F, a diagonal coefficient >= 0 is a size-one
non-Hurwitz witness; a structurally missing diagonal is exact zero. With negative
diagonals, a reciprocal pair whose outward determinant
Fii * Fjj - Fij * Fji has upper bound < 0 is a size-two witness. The principal
block then has a positive eigenvalue, and a Metzler matrix's spectral bound is
at least that of its principal block. This bounded CSR/reciprocal-index search
and its metadata use the same cumulative admission, work and cancellation checks.
Malformed CSR or unsupported arithmetic fails explicitly. These coordinate
diagnostics are not physical endpoint voltages and cannot authorize timing bounds.
The independent principalWitness(comparison, numerical, work) preflight needs no
weight proposal. It may refuse a whitening candidate before its weight portfolio when that same
principal proof already rules out its Hurwitz certificate; an absent witness
grants no authority and the ordinary weight proposal continues. The failure
diagnostic reuses this proof routine rather than duplicating the decision.

Finite budgets cover primitive scanning, aliases, dense products/factorization,
interval temporary arrays, Jacobi sweeps, certificate attempts, source-separated
solves, records and scalar decay refinement. Checked dimension/work arithmetic
and state admission precede allocation. maximumNodes applies to original component
endpoints before quotient; maximumPathStates and maximumPathWorkUnits are shared
with the rest of the request. The public STAConservativeCoupledRCOptions owns
maximumNodes, maximumBasisSweeps and maximumCertificateAttempts as positive,
finite operational caps. These caps participate in configuration identity and
bound candidate generation and certificate refinement in addition to the shared
work/storage ceilings. There are no public observed-convergence tolerances; an
internal residual proposal grid cannot grant authority by grid agreement.
Every completed event interval is finite and confined
to its admitted full-rail ramp by the threshold/derivative certificate.
Cancellation and source accounting are checked during bounded loops, not just
between completed components. The existing canonical reducer call used solely
for mirroredSourceGroups is a bounded lower-call exception: all raw records,
endpoints and SourceIDs are admitted first, conservative linear temporary-table
storage and worst-case sorting/pass work are charged before entry, and cancellation
is checked immediately before and after the call. Its internal loops do not expose
an additional cancellation checkpoint; the pre-admitted finite input bounds this
uninterruptible interval. No other uncharged or unbounded lower call is implied.
One failed required component/corner publishes no partial completed report.

The pre-sprint dense baseline assembles one operator across all unknowns before
zero-C-row elimination; component node admission does not partition it. Its
quadratic storage and cubic verified-solve work do not establish actual-design
feasibility from small fixtures. The retained census now establishes a sparse
structural route for 5,627 unknowns; sparse implementation/runtime verification and
actual comparison/crossing certificates remain completion requirements. Bounds
that the sparse comparison cannot prove remain typed inconclusive.

## Verification and Change Impact

Behavioral tests belong to the existing TimingEngineTests target, under the
ConservativeCoupling name. Every command has an external timeout. The following
fixtures reject violations of this contract rather than merely matching API shape.

| Invariant | Behavioral evidence |
|---|---|
| Exact coupled primitive topology | Two-node coupled analytic modes; same totals with different R/topology; one record versus two distinct parallel CAP records |
| DC identity and exact aliases | Zero-R endpoint aliases, source-to-source CAP, exact driver-following receivers, conflicting-driver rejection |
| Supported singular profile | An actual zero-C row agrees with independent Schur elimination; a floating differential-C nullspace is explicitly refused |
| All bounded histories | One-pole reference E = R * ((Cg + Cc) * Sown + Cc * Saggressor); shifted rise/fall clocks and opposite prehistory remain inside envelopes |
| Numerical enclosure | Rounded ill-conditioned fixtures either enclose independent analytic references or fail; approximate eigenbasis perturbation cannot grant an invalid certificate |
| Global slope authority | Off-route characterized transition minimum controls S; nonpositive/out-of-domain minima and zero-slew sources fail |
| Crossing and uniqueness | Weak coupling gives finite brackets and positive derivative; adversarial reversal/glitch cases without a derivative certificate fail |
| Clock history | Arbitrary admitted phase/prehistory is enclosed; an RC/period combination without full threshold crossings returns no completed bound |
| Interval composition | Interior LUT extrema and source slew ranges are covered; pointwise maximum-slew lookup is insufficient |
| Limits and lifecycle | Primitive nodes, retained workspace, work, cancellation and decay-proof exhaustion fail without partial completed observations |
| Exact sparse algebra | CSR/block-C/zero-row Schur A/J and signed stationary enclosures agree with independent dense small references, including source/sink aliases and real Schur fill |
| Sparse certificate authority | BiCGStab stopping or finite iteration-limit proposals alone cannot pass; invalid F dominance, nonpositive weight, unsatisfied residual and failed crossing inequalities are refused |
| Local-basis necessity and authority | Passive C = [[1,0,0],[0,2,-1],[0,-1,2]] and G = [[101,-100,0],[-100,101,0],[0,0,1]] have a non-Hurwitz identity comparison; local generalized modes on the size-two CAP block must be verified independently and agree with the physical dense reference, without global mixing |
| Local-basis composition | WQ reconstructs physical-node intervals and transformed J retains every source; all off-block fill, failed candidates and unit-slope precomputation consume shared budgets |
| Actual-scale execution | Complete exact 5,627-unknown inventory executes under recorded caller ceilings with all three corners and seven sources retained; either complete certificates or the exact typed unproved condition is recorded with actual elapsed work/resource context |
| Report binding | Exact source/candidate/net/corner/configuration identities survive save/reload; omitted coupling sources cannot pass required coverage |

The parent owns end-to-end interval propagation and required-corner integration
evidence. Changing source slope authority, normalized waveform/history semantics,
primitive interpretation, algebraic profile, threshold semantics or rounding method
invalidates the corresponding prepared certificate and requires new evidence.
Passing fixtures establishes only the exercised model/backend/platform scope.

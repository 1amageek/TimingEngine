# Source Transforms

## Purpose and Scope

Parent: [TimingCore](../DESIGN.md). Own the additive controlled timing-artifact
read seam and invocation-managed retention. No children. Parsing semantics and
Native STA remain with their existing owners.

## Responsibilities and Boundaries

Reuse CircuiteFoundation controlled discovery, exact content identity and close
semantics. Translate its resource callbacks to the caller's existing
`LibertySourceResourceAccounting`. No second I/O engine, deadline or quota is
created. Legacy reader calls are unchanged. Controlled capability is explicit.

## Related Designs

| Design | Relationship | Contract Used | Cautions |
|---|---|---|---|
| [TimingCore](../DESIGN.md) | parent | Artifact reader and typed values | No STA equations |
| [PreparedExecution](../../STAEngine/PreparedExecution/DESIGN.md) | used by | Same invocation accountant and retained inputs | Strict preparation remains refused until every transform is wired |
| CircuiteFoundation SourceDiscovery | depends on | Controlled immutable pages, accounted contiguous borrow and close | Its errors and cleanup failures are preserved |

## Architecture

```text
controlled reader -> CF discovery + thin caller-accounting adapter
  -> verified immutable pages -> admitted contiguous/Data publication
  -> TimingArtifactRead(data, retained anchor) -> borrowed parsing
```

## Contracts and Invariants

A controlled read returns bytes together with a retention anchor. Retaining a
copy retains the anchor; a detached Data copy transfers its storage responsibility
to the caller. Exact reference equality is checked against actual discovery.
Account source pages, temporary contiguous borrowing and the separately published
Data payload while simultaneously live. Managed capacities exclude allocator/RSS
and Foundation internal overhead. Descriptor extents account the concrete Int32
payload; descriptor lifecycle and read ceilings remain CF-owned.

Check before and after every external accounting callback. Callbacks run outside
all Mutex critical sections. The adapter retains only the first caller error in
an invocation-local Mutex. Its fixed CF sentinel never replaces that error at the
Timing boundary. A CF close/abort failure is retained as a secondary cause; pure
CF errors pass through unchanged. No fallback or default bytes are published.

## State, Ownership, and Lifecycle

CF pages retain their own reservations. The Data publication owns its exact byte
reservation and metadata reservation. Failure releases the local owners. Reader
copies have no mutable invocation state. The adapter's first error uses one common
Mutex on all targets; no conditional storage or isolation branches are added.

## Failure, Concurrency, and Constraints

Legacy custom readers default to a typed unsupported controlled capability.
Only newly created exact root capabilities are closed; every normal/failure path
awaits close. Cancellation/deadline/resource causes remain observable. The caller
retains the read anchor through its actual use; no naked Data lifetime guarantee
is inferred.

## Verification and Change Impact

Focused tests must prove actual filesystem and in-memory exact bytes, digest
refusal, callback cancellation before copy, tiny capacity, original cause and
last-copy refund. Native strict admission remains blocked until input parsers,
joins, graph, scenario and output owners satisfy their own contracts.


## Controlled Grammar Handoff

`TimingTransformValue<Value>` retains a concrete owner and its wrapper metadata.
Controlled design/SPEF parser requirements receive the host's typed
`TimingBoundedJSONDecoding`; it supplies the already-owned bounded PDK decoder,
without a TimingCore dependency on PDK or a second JSON parser. The host audits
Timing's custom Decodable and CodingKey operations separately. Controlled SDC and
parasitic reduction use the same caller accountant directly. Default controlled
requirements explicitly refuse; old methods retain their existing behavior.
These additive ownership seams participate in the selected host Native
qualification owned by [PreparedExecution](../../STAEngine/PreparedExecution/DESIGN.md#strict-native-qualification-scope).


| Shared state | Native / WASM / Embedded storage | Access | Release |
|---|---|---|---|
| CF bridge first caller error | One `Mutex<(any Error)?>` in common source | Brief first-write/read only; callbacks outside lock | Read invocation |
| PDK bridge first caller error and balanced depth | One common `Mutex<State>` in STAEngine | Checked depth reserve/release and first-write/read; callbacks outside lock | Decoder handle/invocation |

These declarations introduce no target-specific raw state, Sendable change or
synchronization bypass. Selected Native controlled-reader behavior passed its
actual resource/failure/copy gates; no WASM/Embedded runtime or parallel file-I/O
claim is made.


`TimingControlledTransformFailure` preserves the complete lower controlled failure
when exposing an original caller cause. Its fixed wrapper capacity is reserved
before decoding; inspecting cause does not detach lower failure strings or their
private reservations. Domain failures with no caller callback failure pass through
unchanged, including all lower retained anchors.


## Serialized JSON Publication

`TimingJSONEncoding` traverses the existing Encodable schema with a checked JSON
grammar visitor before Foundation encoding. The visitor charges every field,
container, scalar and source UTF-8 byte on the original accountant. The admitted
output upper bound covers escaping, delimiters, indentation and number spelling;
it is not a guessed multiplicative envelope. The encoding pass is separately
charged by that byte bound before Foundation runs. Its internal implementation
workspace is excluded from the managed-payload contract, as other Foundation
internal workspace; caller-owned custom Encodable intermediates remain the schema
owner's responsibility. Encoded Data and an optional exact static domain prefix
are admitted simultaneously before concatenation. The returned value retains its
actual output lease through the last handle copy. Hashing remains the caller's
separately admitted operation. Legacy formatting and bytes are preserved.


## Controlled Diagnostic Failure

`TimingControlledDiagnostics<Retention>` is invocation-local and prepays one
terminal failure wrapper plus its concrete source-owner payload before work starts.
It retains the original rich Error and complete source owner. `failure` performs no
accounting/cancellation callback after the operation fails. A source-derived message
uses `sourceFailure(utf8ByteCount:construct:)`: the schema owner supplies the exact
sum of literal UTF-8 fragments and source fields; bytes and scheduled construction
work are admitted before the lazy constructor runs. No description is generated
from an unknown Error to invent a bound. Caller-owned failure text requires no
new message copy; complete lower anchored failures remain retained. Each boundary
produces only its operation's one terminal thrown failure, not an error collection.


The fixed Swift 6.4 case-mapping helper reuses the qualified PEX source-backed
Unicode sizing contract: each special mapping's UTF-8 length is represented by
UInt8 in the standard-library table reader. Reserve that one-mapping scratch
before reading properties, sum actual scalar mapping lengths, then admit input
capacity plus mapped output capacity before lowercased/uppercased. Verify the
actual result length. This preserves Unicode behavior without an ASCII profile or
a guessed expansion multiplier. Standard-library changes require requalification.

The numeric diagnostic bound is tied to exact Swift 6.4 source:
[FloatingPointTypes.swift.gyb](https://github.com/swiftlang/swift/blob/swift-6.4.0-RELEASE/stdlib/public/core/FloatingPointTypes.swift.gyb)
implements Double description/debugDescription by formatting into an inline
64-byte ASCII buffer and publishing a subrange. Int decimal magnitude is counted
without formatting (20 bytes including sign on the selected 64-bit target); Bool
needs at most five bytes. `TimingDiagnosticTextCapacity.description` combines
these representation bounds with actual static punctuation and source fields.
Schema owners sum independently coexisting nested descriptions and final message
payloads before lazy construction. It does not bound arbitrary descriptions or
call an unknown error's description to manufacture a capacity.


Controlled filesystem authority comes from the reader constructor: an explicit
workspace root, or `allowControlledLocalFileSystemRoot: true` for the existing
local-file-system namespace. The latter defaults false and is a caller grant,
never inferred from an untrusted binding's root ID. Legacy unbudgeted reads keep
their existing namespace behavior. Source-derived failure path text is sized and
admitted before the rich TimingError is constructed and retains its original
artifact owner through the prepaid failure boundary.

## Runtime Provenance Inputs

Controlled runtime attestation uses the same Bundle executable URL/fallback as
legacy identity, with a capability for that actual executable's parent directory.
This is process identity authority, not a root selected by an artifact proposal.
CF discovery accounts actual immutable executable pages/read/hash work; the final
64-byte digest String is copied under its own lease so the binary pages are not
retained by a small producer identity. Root close is explicit on success/failure.
No unbudgeted cached digest substitutes for an invocation's controlled capture.
The caller supplies the finite existing artifact-access read policy; all source
work/storage/deadline callbacks remain the original invocation's accountant.
Foundation's Bundle/URL/ProcessInfo infrastructure discovery is outside managed
payload accounting. Application-owned path publication, platform String, fixed
environment Data, hash/copy workspace and returned scalar values are admitted.
Legacy cached identity and its wire values remain unchanged.

Controlled filesystem diagnostic sizing sums the public relative-path segments and separators without first constructing `stringValue`. When an error is actually built, the relative-path join and final materialization text receive separate simultaneous reservations. A terminal error retains the final text receipt; join scratch is lexical.

## T1 Controlled In-Memory Identity and Failure Ownership

The in-memory controlled reader owns exact dictionary lookup, byte-count and digest
validation rather than calling the legacy uncontrolled reader. Existing dictionary
Data remains reader/caller-owned; successful publication retains its exact payload
and `TimingArtifactRead` metadata through the last copied handle. Before the public
CF `digest(data:using:)` call, reserve simultaneously the INSTANCE
`foundationDataCopyCost(byteCount:)` temporary copy and STATIC
`SHA256ContentDigester.managedCost(byteCount:)` temporary hash payload, retain the
latter's digest output through comparison, and precharge both public work costs
in addition to the existing controlled payload work. Each external accounting
callback is followed by a cancellation/deadline check before growth or hashing.
No allocator/RSS or backend-private workspace is inferred. A prepaid
`TimingControlledDiagnostics` retains the actual artifact binding; missing, size
and digest failures lazily construct the same rich `TimingError` under
`sourceFailure`. Size the actual local segments/separators or service resource,
admit a local relative-path join separately from the final materialization text,
and retain final text and terminal metadata through all copied failure handles.
Controlled service failures use `TimingArtifactBinding`'s stable diagnostic text
`service:<serviceID>/<namespaceID>/<resourceID>@<generation>` with the public raw
IDs and unsigned decimal generation. This diagnostic display preserves all
resource facts without changing artifact identity or the legacy reflection-based
`materializationDescription`. Checked raw UTF-8 sums, fixed punctuation and the
mathematically derived UInt64 decimal width admit the final text before growth;
decimal intermediate text has its own simultaneous temporary receipt. Successful
service reads construct no diagnostic text. Long service-ID missing and mismatch
cases must retain this canonical cause through copied failures and refuse a
diagnostic text quota before constructing it.
Quota/cancellation/work failures preserve their exact caller cause and release
lexical owners without refunding spent work. Representable size-mismatch causes,
legacy uncontrolled behavior and the filesystem controlled implementation remain
unchanged. If either source count cannot
be represented by the existing Int64 size-error fields, controlled intake returns
an anchored static `TimingError.invalidInput` before numeric conversion or dynamic
diagnostic construction; public UInt64 content references never authorize a trap.
The UInt64.max reference/one-byte registered Data regression must preserve that
typed failure and its owner through copied handles and final refund. The T1 cases in
[`ControlledArtifactReadTests`](../../../Tests/LibertyCodecTests/ControlledArtifactReadTests.swift)
must reject zero hash scratch and payload-only work, preserve long-path missing
and digest causes with retained failure copies, refuse unadmitted failure text,
and prove hash-reservation cancellation, cumulative work and last-copy refunds.
The central RED gate confirmed the unadmitted hash and dynamic-failure paths;
the explicit implementation and service diagnostic correction passed the final
selected Native GREEN gates and finding-limited recheck.

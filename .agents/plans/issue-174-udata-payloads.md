# Issue 174: nominal userdata payloads

Source: https://github.com/mascarenhas/titan/issues/174
Branch: `codex/issue-174`
Research base: `602b0b39` (PRs 173 and 176 are merged).

## Delivery contract

Implement the complete issue, including its enumerated standard-library owner
migrations. Commit milestones, obtain independent implementation and audience-
aware documentation reviews, run the complete local mixed suite, push and obtain
green Linux CI (including sanitizer) before opening the completed PR. Leave the
PR unmerged. macOS CI is waived: never dispatch it. Keep the language-server API
marker at 1; the generated-code ABI requires a clean rebuild transition.

Update both human language/implementation manuals and relevant agent skills.
Human language docs explain behavior and runnable examples; implementation docs
explain representation and ownership; skills provide operational decisions and
traps without duplicating the manuals wholesale.

## Confirmed issue semantics

- Native non-GC values occupy generated C payload members; traced values occupy
  dense UV slots. Preserve logical field/part indices and private gaps.
- Use erased runtime types and retain TValue/Udata-pointer traced exceptions.
- Union variants contain an actual common tag-header first subobject and allocate
  their own active size. Reflection tag/arity cannot depend on UV counts.
- Physical metadata is separate from type-checking serialization and optional
  for analysis clients; both binary formats and incremental objects carry it.
- Fixed complete non-GC foreign aggregates/arrays copy into nominal storage;
  projections borrow interior pointers without allocating wrappers. Constness
  is shallow and explicit C qualifiers survive. No general aggregate boxing.
- Direct fresh array/FAM constructor arguments may fuse into const slots only.
  Preserve lexical evaluation/failure order, snapshots, alignment, checked sizes,
  zero-count distinct addresses, ordinary borrowed fallbacks, and owned identity.
- Native C values stay exact until a real typed/boxed boundary converts them.
  Optional native fields need explicit presence plus exact native value.
- Keep existing Runtime/Task lifetime protocols; initialize native objects only
  after their final nominal owner exists, never copy initialized native handles.

## Physical reconstruction decision

The maintainer proposed public-first physical storage so consumers need only the
public prefix. Use an actual public-prefix C struct as the first subobject of a
producer's complete record payload, followed by private native members. Binary
consumers reconstruct only the compatible anonymous public-prefix type and read
it directly. Merely casting a flat full struct to an unrelated shorter struct
is not the selected design. Logical Titan field indices and visibility remain
unchanged; compiled layout metadata supplies the dense UV mapping separately.

Private C declarations and layout details stay producer-owned. No supplemental
private C declaration graph, tag-name isolation, layout-only surrogate, or memcpy
access is necessary. Omit a public payload prefix when there are no public native
members; GC-only public access needs only the UV mapping and actual nuvalue.

Records with any private field have a private synthesized constructor. Binary
record literals reject missing private fields using nfields versus visible fields,
including generic literals. Thus binary consumers never allocate these full
private payloads. Public factories and escaped first-class constructors allocate
inside the producer. Explicit source imports retain full descriptors and headers.
For unions, use the real common tag-header first subobject; public variants
expose all parts, and private variants remain accessible through producer-owned
reflection accessors without exporting their private physical layout.

The complete-definition/offset discussion above was a research detour, not an
additional implementation requirement. The durable goal remains the full issue
174 delivery under this newer maintainer-directed representation.

## Implementation stages

1. Define checked nominal storage and separate physical metadata; implement
   producer/consumer reconstruction and ABI/cache/publication updates. Test
   source-free DSO/archive consumers with interleaved logical private fields,
   private foreign aggregates in producer-only tails, public prefix offsets and
   alignment, and analysis-only imports.
2. Migrate record/union constructors, reads/stores, cases, Interface snapshots,
   generated Lua/reflection accessors, and native scalar/Option boundaries.
   Add topical compiler tests for raw/GC/mixed/generic and private layouts.
3. Enable fixed foreign aggregate/array storage and checked pointer projection.
   Add extent, recursive GC/FAM rejection, shallow-const, copy independence,
   source snapshot, rooting, and exact native numeric regressions.
4. Supply compiler-owned field access for private native callbacks and migrate
   HTTP, filesystem, stream, DNS/connect/shutdown, timer, TCP/process/signal,
   Runtime, watcher, and pipe/TTY owners. Preserve every initialization, failure,
   cancellation, close, and callback-root boundary.
5. Implement fresh const array/FAM tail plans before ordinary/generic argument
   adjustment erases provenance. Migrate filesystem read buffers, WorkOwner's
   carrier, and spawn options/stdio exactly as specified by the issue.
6. Add missing native reflection/GC/callback lifetime cases, isolated allocation
   probes and generated-C evidence; extend existing sanitizer selectors.
7. Update both documentation audiences, obtain independent code and separate
   documentation review, fix findings, run focused and full local gates.
8. Push final commits, monitor/fix Linux CI via gh, open and attach completed PR
   only when Linux is green. Never dispatch macOS.

## Research seams and traps

- Nominal eligibility: `checker/declarations.lua:check_user_value_slot_type`
  and record/union `checkbodies` uses. Keep ordinary module/Interface boxing
  eligibility unchanged.
- Normalize unsized array fields/parts in canonical descriptor construction;
  synthesized constructors currently reparse source parameter types.
- Add checked pointer projections at record VarDot and case binders.
- Recognize direct constructors before `generic_instantiate_direct_call`;
  named, fixed, and generic argument checking must carry nominal slot demand.
- Extend `_plan_c_allocation`; codegen consumes plans, never syntax guesses.
- Current Option native carrier is universally TValue. Ordinary wrap/force
  before construction already narrows C values; payload-only changes cannot
  satisfy native-exact optional storage by themselves.
- TCP and stdio currently share alloc/read callbacks with matching UV prefixes.
  Embedding removes TCP's leading GC field but stdio still retains its union.
  Their callback slots diverge; use concrete compiler-owned access.
- Preserve unrelated module, Interface, closure, Array-proxy, and custom
  five-uservalue coroutine protocols.
- Union reflection must query actual private variants' tag/arity/parts while
  public schemas retain omissions and logical ordinals. JSON shape is unchanged.

## Validation setup

Fresh local Lua/LuaRocks prefix: `/tmp/titan-174-validation`.
Preparation log: `/tmp/titan-174-prepare.log`.
Use explicit `busted --run=checkout` with command-scoped installed SDK root for
focused compiler edits, then rebuild the canonical provider and use `make test`
with ambient Lua/root/CPP/line overrides cleared. Do not reuse old ABI providers.
Use the existing native HTTP/fs/net/os/uv/async/reflect/json owners. Compiler
representation and allocator probes belong in Busted/native harness coverage,
not library API tests. Shared checkout artifacts prohibit concurrent compiler
fixtures without isolated copies.

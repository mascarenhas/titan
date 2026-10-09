# Native source coverage implementation

Coverage adds an opt-in branch to the existing compiler/test pipeline. It does
not add a runner or change native discovery, logical module identities, source
visibility, the generated ABI, or language-server API version.

## Explicit regions and final conversion

The coverage code generator emits reserved standalone `// TITAN_COVERAGE_*`
comments for nested source, authored-C, and generated regions. Source filenames
are hex encoded in markers so quotes, Windows separators, spaces, and arbitrary
bytes cannot confuse the marker grammar. Ordinary generation remains byte
compatible with its previous source-location policy.

Statements, expression lowering that emits statements, authored function bodies,
foreign bodies, closures, and user initializers own source regions. Wrappers,
signatures, prologues, epilogues, metadata, and synthesized constructors use
generated attribution. Selected source-defined foreign functions are outlined before
header planning in this mode; otherwise an inline body could run only in an
excluded consumer/test object or disappear from the notes-only denominator.
The ordinary mode restores cached inline decisions when changing policies.
Foreign `elseif` conditions own separate decision regions, and a repeat loop's
`until` condition owns its evaluation region. The synthesized constant C
backedge is generated scaffolding; a body `break` does not falsely mark the
unevaluated `until` condition as executed.

`driver.format_generated_file` uses a fixed clang-format `CommentPragmas`
reservation to preserve standalone marker comments. Coverage skips the ordinary
blank-line normalization after `#line` directives because it could change an
authored C region's intentional progression. After formatting,
`coverage_lines.convert` consumes the markers
and writes standard `#line` directives. No formatter/layout pass follows it.
The generic recursive `util.render` remains independent of C locations.

The converter maintains a stack of region owners. Each safe physical/logical
line in a source expansion receives the same Titan anchor, rather than drifting
across unrelated source lines. Ending a nested region restores its parent;
ending the outermost source region restores the generated C filename and physical line.
Authored-C regions preserve intentional line progression. The scanner tracks
block/line comments, quoted/character literals, escapes, line splicing, and
preprocessor logical lines. It never inserts controls inside a continued macro,
literal, comment, or escaped-newline logical line, and recognizes markers only
as standalone comments in neutral lexical context. Malformed or unbalanced
metadata is an error. The converter returns source anchors alongside its C
output; a saved `.coverage-anchors` receipt distinguishes declaration-only
source constituents from attribution gaps.

This implements the marker/postprocessing architecture selected in issue #210.
It does not copy the OpenModelica converter or freeze every ordinary `#line`
region. Statement anchors intentionally do not imply expression-level coverage.

## Build ownership

`coverage.lua` owns the explicit source inventory, isolated outputs, toolchain
probe, settings stamp, and compiler-written preliminary manifest.
`titanc` marks all declared production names as source-required roots before
resolution and also checks names absent from the test dependency graph.
Discovery still sees only the original requested test roots. A selected module
containing tests fails with guidance to split the mixed owner.

The resolver gives every source object/header a coverage-owned native output
before incremental object lookup, while retaining the real source filename for
checking and mapping. Scope/tool/settings changes reject reuse of the directory.
Use a fresh directory after replacing the SDK: ordinary generated C environments
retain inode-sensitive header-search identities, including byte-identical
reinstalled headers. Coverage preserves that existing compiler validation.
The settings stamp hashes the compiler, C parser, and executed `titanc` frontend.
Per-module receipts include the exact source inventory/hashes, object, notes and
attribution metadata hashes. Missing or changed receipts force source compilation. Coverage
objects cannot be mistaken for ordinary source-adjacent objects by timestamps.
These receipts do not invalidate callers when an imported inline foreign helper
changes. Callers using `--incremental` still own the complete dependency graph;
the repository coverage recipe rebuilds rather than relying on timestamp reuse.

Selected objects receive O0/no-LTO, GCC coverage, atomic profile update, and
retention of uncalled static functions. GCC `-dumpbase stable.c
-dumpbase-ext .c` fixes `.gcno` and embedded `.gcda` identity while the compiler
still writes to a unique sibling temporary `.o` and atomically publishes it.
Only final image links and provider capability links receive the coverage
runtime. Test/support/entrypoint and unrelated native dependencies are not
instrumented. Build-generated counters are harmless because runs own fresh
prefixes after all probes.

The explicit Windows `llvm-gcov` backend instead pins Clang/LLVM 22.1.8 and
uses `-dumpdir` with the owning object directory. LLVM keeps the source basename
for notes and embedded data filenames even though compilation writes a unique
sibling temporary object. Source-owned native lambdas receive `used` only in
selected LLVM translation units so that uncalled bodies retain executable
notes. Global `-femit-all-decls` is deliberately avoided: it also emits unrelated
inline header bodies with dependencies the image need not supply. Ordinary and
GCC emission retain their existing policy.

Object publication preserves the prior object until the sibling compilation
succeeds. A failed compilation invalidates that attempt's compiled entry and
cannot link the old object as a fallback; a successful retry atomically replaces
it. Coverage receipts still reject the prior object after source changes,
including changes with an equal filesystem timestamp.

The repository workflow builds a normal shared standard provider with 22
measured production roots and unmeasured `titan.test`. It stages the explicit
test ensemble and native fixtures inside the coverage build directory, then
builds an ordinary uninstrumented 28-root consumer against that provider.
Neither provider nor consumer enables incremental reuse without a dependency DAG.
Runtime `TITAN_PATH_0_6` and provider-first Lua paths select the same measured
provider in the consumer and joined children. The repository test helper also
honors an explicit provider directory in fresh `lua -E` hosts, where ambient
Lua paths are intentionally ignored. Static children receive a link-only
coverage runtime flag. The runner streams output through a pipe and audits all
28 test roots using the ordinary output validator. General CLI source-linked
coverage remains available independently of this repository workflow.

The manifest names every source constituent, mapped tracked path, source hash,
instrumented object, notes/data path, object/notes hash, and linked image/hash.
Uninstrumented prebuilt dependencies remain explicitly unmeasured. No binary
metadata/ABI version needs to change; the ordinary compiler and object contracts
remain intact.
Repeated `seal --unmeasured-input` arguments bind separately built consumers and
their original/staged test inputs to the same run through the existing hashed
link inventory. They do not add measured sources or executable lines.
`seal --unmeasured-input-file` provides the same explicit inputs through a strict
UTF-8 JSON array, avoiding Windows' command-line length limit. The list itself
is hashed. No directory search substitutes for a caller's consumer inventory.

Windows final-program paths take the coverage output root while preserving
logical provider identity and the normal executable-directory lookup. The
manifest includes the actual measured DLL and an explicitly unmeasured EXE
launcher, plus entrypoint/resource and native final-link inputs. Windows has no
static provider companion. The repository Make workflow copies a prepared SDK
into a fresh local NTFS workspace, replaces only the private copy's standard DLL
and shims, builds the ordinary native consumer there, and seals all input files.
The coverage host supervises the aggregate directly: nesting the ordinary test
supervisor could hide an unjoined child by cleaning it up first.

## Host collection and reporting

The installed Python `titan-coverage` command runs the backend capability probe,
seals manifests, supervises runs, and normalizes reports. It uses GCC's gcov
JSON v2 by default and pinned gcovr 8.4 for standard rendering. It does not invent
counts, use C/C++ decision heuristics on Titan syntax,
or place report dependencies in the synthetic runner.

`load_manifest` validates the sealed inputs, tools and runner rather than hashing
the executing Python script. A compatible updated reporter can therefore read
retained notes and run counters from outside the sealed build and write a fresh
report without changing that build. The embedded Windows runner source identity
remains checked by `validate_runner`.

The Windows LLVM reader first validates the exact `*11B` binary version, file
stamp, per-function line/CFG checksums, function inventory and counter arity.
This parses metadata rather than reconstructing counts. The matching
`llvm-cov gcov --intermediate-format` remains the sole count reader. Its strict
UTF-8 intermediate adapter requires the exact source/function/executable-line
inventory from the notes, unsigned bounded counts, and complete records. Any
stderr diagnostics, unknown records, missing inventory or malformed input fail,
even when LLVM exits zero. Notes/data are copied into one private reader
directory per object and checked unchanged afterwards. This precheck matters:
LLVM can accept some altered binary version fields without a diagnostic.

The LLVM probe binds compiler/profiler executable and explicitly imported
implementation-DLL hashes, the effective x64 Windows GNU target, and the static
profile-runtime archive. It verifies multi-file attribution, notes-only zeros,
stable temporary-object notes, shared-provider exit, threaded atomic counters,
and joined child processes. The native Python executable hash, implementation,
version and bitness are also sealed and checked on readback. Windows Python
must be a direct installation whose implementation DLLs are adjacent to its
executable; virtual-environment redirectors are not supported by this identity
contract. It materializes the embedded C process supervisor
once under the build-owned `tools` directory, recording its exact source,
compile argv, image hash and PE import inventory. Existing helpers validate or
fail; sealing and execution never repair them or choose a PATH substitute.
The helper uses `-g0` and a deterministic PE timestamp so build-directory debug
paths do not change its byte identity across compatible builds.

Sealing preserves and checks compiler-written hashes, verifies staged/tracked
byte identity, records compiler/profiler/libgcov/target identities, and rejects
incompatible compiler-probe evidence. A run receipt records exact build identity,
argv, counter prefix, observed hashes, exit status, and completion limitations.
Run directories are never reused. After the owned process group has completed,
reporting validates receipts and copies each matching notes/counter pair to a
private gcov work directory. Unexecuted notes are read without `.gcda`, keeping
their executable lines at zero. Unknown inventory/source attribution, malformed
data, missing notes, source edits, profile mismatches, and counters changed by
late children are observable failures.
On POSIX, `start_new_session` gives the leader a private process group. After
reaping the leader, `killpg(pgid, 0)` must confirm that group is empty before
counter hashing. After natural leader completion, a remaining group forces
incomplete status 125, preserving the raw leader status, and triggers bounded
group retirement. Timeout and
interruption cleanup also signal that group and escalate to `SIGKILL` even if
its leader has already exited, retaining statuses 124 and 130 respectively.
The final emptiness wait is bounded; permission
errors or remaining zombies cannot establish emptiness. Unconfirmed runs skip
counter collection and cannot produce even an incomplete diagnostic report.
This boundary does not contain descendants that deliberately change their
session or process group.

On Windows, the native helper creates the leader suspended, assigns it atomically
to a kill-on-close Job Object, and resumes it only after assignment. Its child
handle list contains exactly the three standard handles. Python owns the sole
noninherited writer of a separate control pipe; only the helper inherits its
read handle and clears inheritance before creating the leader. Pipe EOF requests
bounded retirement. Python starts the helper with a private headless console;
the helper verifies that its console contains only its own PID and has no
window before creating the leader. The leader inherits that console, so console
infrastructure stays outside the measured job while descendants retain ordinary
console inheritance. Python keeps the caller console. Explicit output pipes
preserve native stdio, and terminal input uses a low-level forwarding pump.

LLVM capability fixtures use a unique workspace beside the sealed helper.
Success removes that workspace; failure retains its generated sources and
available notes/data, raw reader output and native receipts, plus a `failure.json`
naming the stage and available expected/observed oracle. Compile/link receipts
retain status and at most 64 KiB of each output stream, with original sizes and
hashes. Native probe streams are teed while forwarding, with the same retention
bound and observed byte counts/hashes. Retained sizes come from the actual files
after closing; storage failure keeps draining and preserves a native rejection. No
caller environment is recorded. Diagnostic-write failure preserves the primary
tool rejection. The CLI names the retained directory explicitly.

The helper requires a reaped leader and a confirmed empty job before its final
control observation and receipt. Natural leader exit with live descendants is
incomplete status 125; timeout 124 and interruption 130 take precedence without changing
the raw leader DWORD. Python interruption before collection also makes the run
incomplete, even if the helper's finite admission boundary has already closed.
Repeated interrupts cannot turn that result into success. A parent crash leaves
the run uncollected, and a forced-helper backstop or unconfirmed emptiness
prevents counter collection. Readback validates the native receipt hash, exact
control enrollment, cleanup/status relationships and sealed helper identity.
Native helper receipt version 4 records the verified private console and leader
creation flags; readback rejects an unverified console or incompatible helper.

Run receipt version 2 records the ownership policy, group identity, retirement,
emptiness confirmation and raw leader status. Readback rejects legacy receipts,
missing ownership evidence, and a complete state inconsistent with retirement
or the leader status. The sealed build manifest remains version 1, allowing an
unchanged measured image to receive a fresh capture with the corrected host.

Raw gcov data includes generated C locations and native arcs/functions for
diagnosis. Normalization retains only declared Titan executable lines, verifies
each source location, applies tracked-path mappings, and strips unsupported
branch/function metrics. Public LCOV uses verified repository-relative `SF`
paths; gcovr renders HTML and Cobertura from the normalized line trace and exact
source-line checksums. Source inventory gaps fail unless compiler anchors
explicitly prove that a source constituent has no executable regions.
Sealing accepts LF and CRLF source rows but rejects bare carriage returns:
Titan locations count LF bytes, whereas gcovr's source reader treats CR as a
line break. Rejecting that mismatch prevents shifted HTML and LCOV checksums.

Unselected source-defined foreign bodies can remain inline in generated headers.
GCC may include those physical header locations in a selected translation unit's
raw notes. They have no Titan source ownership and stay outside the declared
source-line report, like other native/header code.

Linux/macOS/Windows receipts remain separate. GCC and the explicitly selected
Windows LLVM backend have different tool, runtime and counter policies;
compatible-run merging cannot combine them. Build-owned helper paths are not
semantic differences between otherwise compatible Windows builds, but helper
source/image/compiler identity and counter policy remain part of compatibility.

## Verification owners

`spec/coverage_lines_spec.lua` owns the lexical converter's malformed, nested,
generated/authored, comment/literal, continuation, filename, and newline cases.
`spec/coder/coverage_attribution_spec.lua` owns real Titan emission, nested
lowering, ordinary policy restoration, body/initializer ownership, outlining,
and contributors. Native compiler coverage regressions execute compiled Titan
and assert exact gcov source lines. These remain compiler tests rather than
stdlib behavior wrappers.

`spec/coverage_host_test.py` is a dedicated host-tool gate using real GCC/gcov
and pinned gcovr. It covers notes-only modules, repeated/parallel/child/shared
provider runs, failed/abnormal exits, standard reports, duplicate/stale evidence,
source/notes/profile mismatches, staged source identity, and reporter pinning.
It is not required by ordinary Windows/Clang tests. The stdlib Make target
reuses the existing aggregate and native fixtures with a complete production
inventory. Ordinary full-suite and VM gates continue to validate shipping
behavior independently of instrumentation.

`spec/coverage_backend_spec.lua` owns explicit backend selection and early
Windows rejection of the default GCC backend. Host tests also cover strict
LLVM metadata/intermediate rejection, runner and consumer-list provenance,
Python interruption, and receipt readback. Native Windows validation must use
the genuinely installed compiler/host, prove EXE/DLL and provider selection,
and render the complete stdlib report; scratch capability probes alone do not
establish that integration.

The [initial validation record](native-coverage-validation.md) contains the
complete stdlib baseline, coverage-driven test gaps, exact tools and local VM
receipts.

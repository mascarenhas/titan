# Persistent successful C-probe markers

## Maintainer decision

Titan uses a deliberately small persistent cache for compile-only C probes:

1. The only entry key is `SHA-256` of the exact probe C text. Titan does not
   preprocess that text for the cache and does not key compiler, flags,
   environment, headers, include search, or dependency state.
2. Only a completed successful compiler probe is persisted. Compiler rejection,
   spawn failure, interruption, workspace failure, and cleanup failure never
   create an entry.
3. An entry is an empty `<hash>.success` marker. Presence of that regular file
   is itself sufficient evidence to recover success. There is no payload,
   decoder, diagnostic, or rejected-verdict record.
4. Publication occurs only after the ordinary probe source/object cleanup, via
   a distinct same-directory temporary marker and atomic rename. Cache I/O
   fails open.
5. The cache serves stable local rebuilds as well as CI. If compiler/header or
   build-policy isolation is desired, clear the cache, choose another prefix,
   or select another namespace with `TITAN_PROBE_CACHE_IDENTITY`.

This trades exhaustive invalidation for a direct trusted-build-state policy.
Do not add dependency manifests, preprocessing, search snapshots, compiler
identity graphs, VFS/configuration discovery, or rejection records unless the
maintainer explicitly changes this decision.

## Layout

The production root is `<prefix>/var/cache/titan-probes/<ABI>`, where a
nonempty `TITAN_PREFIX` selects the prefix and the supported installation root
from `package.cpath` is the fallback. A nonempty
`TITAN_PROBE_CACHE_IDENTITY` selects
`namespace-<sha256(identity)>/` below that root. Marker basenames remain the
probe-content hash regardless of namespace.

CI keeps this directory out of the prepared full-tree tar and snapshots it
independently with `actions/cache@v5`. The regular Linux producer, macOS, and
sanitizer jobs use distinct lane namespaces and keys. The regular lane restores
before its first build and explicitly saves after bundled tests/smoke but before
the system-libuv/OpenSSL canary can add markers from another provider
configuration. Compiler specs disable the persistent cache because independent
fixtures intentionally reuse header pathnames; the preceding production build
still benefits. Primary keys end in the commit SHA while stable restore prefixes
permit reuse. Cache entries must come only from a trusted writer because their
presence is authoritative.

Direct source imports retain unique randomized physical checking headers for
concurrency, cleanup, and transactional safety. Probes do not render those
names. The checker derives a stable private wrapper name from the logical module
and eventual public-header path; the wrapper includes the unique physical file
by absolute quoted spelling, preserving nested quoted-include origin. Every
probe descriptor field is stable, cache lookup precedes workspace/wrapper
creation, conflicting bindings fail, and wrapper creation failure is
infrastructure rather than a cacheable verdict.

## Validation

- Pure-Lua SHA-256 standard, binary/NUL, and padding-boundary vectors.
- A cold successful probe creates one empty hash-named marker; a fresh service
  hits it before workspace creation even when the semantic call-site key differs.
- Exact source-byte and namespace changes miss.
- Two randomized checking-header paths behind one stable wrapper produce the
  same header key, baseline key, and probe C; the second service hits before
  workspace creation. Conflicting bindings and wrapper-write failures fail, and
  a real nested quoted include retains its physical origin. A relative source
  root with a cross-directory source import proves that the unique checking path
  is absolutized and cleaned before wrapper construction.
- Rejected, unstarted, interrupted, and cleanup-failed probes create no marker.
- Unwritable or structurally blocked cache roots fail open.
- Focused cprobe/driver/workflow specs, full compiler coverage, mixed suite, and
  local cold/warm profiles report process counts and wall time.

## Local profile

A controlled bundled-provider rebuild with an empty namespace completed in
153.5 seconds and launched 1,050 compiler processes, creating 244 success
markers. Repeating the same build in the same prefix completed in 150.2 seconds
and launched 945 compiler processes: 105 exact-text successful probes were
recovered without invoking the compiler, a 10% process reduction and 2.1% wall
reduction. That measurement preceded the stable source-foreign wrapper above;
those probes now retain exact generated C while no longer changing merely
because a safe physical checking-header nonce changed.

A separate compile-only profile used Clang with the CI ASan+UBSan flags for 400
distinct successful probe texts. The cold run took 11.7 seconds, launched 400
compiler processes, and created 400 markers; the warm run took 0.04 seconds,
launched no compiler, and reused all 400 markers.

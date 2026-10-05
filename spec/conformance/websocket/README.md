# WebSocket conformance gate

This harness runs **all 301 uncompressed cases in both Titan roles** against the
Autobahn 25.10.1 Linux amd64 image at the digest in `pins.json`. The image's
source is `6ed6f439dc7ed0d7432fe2cf7481b110905ecc5c`. Its runtime inventory contains
517 cases: `expected.json` records all 301 selected IDs and all 216 excluded IDs.
Only exact top-level compression groups 12 and 13 are excluded because Titan v1
does not negotiate permessage-deflate. UTF-8, close-reason case 7.5.1, close-code
case 7.7.8, limits/performance groups 9/10, and every other base case remain selected.

The echo fixtures use public installed APIs and a 32 MiB incoming-message cap so
the suite's 16 MiB payloads fit. This test profile does not change the production
1 MiB default or substitute for native default-limit/security/TLS tests.

The integration owner must first install the current implementation into an
isolated prefix and freeze that prefix for the run. The harness installs nothing
and does not acquire the image. Docker must already have the exact image, and
the caller must have authorized access to Docker and loopback networking. On a
sandboxed Codex host, invoke the checked script through the standard approval
mechanism. Never use a shared-provider install or a privileged container.

```sh
cd spec/conformance/websocket
python3 -m unittest -v test_check_reports.py test_orchestration.py
python3 run.py --prefix /tmp/titan-193-prefix \
  --checkout /var/home/mascarenhas/Code/titan \
  --output-root "$PWD/.artifacts/runs"
```

Use a disk-backed output root. `run.py` creates a fresh unique directory, compiles
both fixtures as installed consumers in that directory, sets `TITAN_PATH_0_6`
to the frozen prefix's absolute provider directory, and runs fuzzingclient
against the Titan echo server followed by the Titan case driver against
fuzzingserver. The driver fetches `/getCaseCount`, checks the exact dotted ID from
`/getCaseInfo` before each ordinal, echoes complete text/binary messages, continues
after errors from deliberately malformed cases, and awaits `/updateReports`
closure. It logs every case start and end, and the parent audits exact coverage.

Every child has an owned process group and every container has a unique owned
name. The parent bounds readiness and total execution, retires/kills/joins owned
processes on all exits, and attempts the other full role after a role fails.
The pinned per-case ceiling is 600 seconds, exceeding the suite's 480-second
case deadlines; the full-role ceiling is 15 minutes. A measured complete 602-case
final provider5 run took 68.3 seconds and produced 22.5 MB of evidence before archival. The
evidence ceiling is 100 MiB, checked during compilation, readiness and execution;
crossing it fails the run and retires owned processes. `measurement.json`
records accepted final production commit `2bf8aae5`, provider5, source/argv
receipts, reports and archive identities. The final measurements came from a busy
host while other integration gates ran. These
generous bounds retain over 25 times the measured slowest-role duration and
over four times the observed evidence size. The 600-second case bound preserves
the pinned runner's 480-second large-case deadlines even though the measured
maximum case took 1.046 seconds.
CLI overrides may raise budgets or set a full-role budget no shorter than the per-case ceiling.
Performance duration is evidence, not a score-based conformance threshold. A timeout is a failed run.

`check_reports.py` rejects missing/malformed/empty reports, duplicate JSON keys,
wrong/extra agents, missing/extra cases, absent or rejected `behavior` and
`behaviorClose`, mismatched individual-report identities/roles/results, and
missing individual JSON/HTML/wire evidence. No NON-STRICT waiver exists.
INFORMATIONAL is accepted and recorded only for 7.1.6, 7.13.1 and 7.13.2: the
pinned case sources explicitly set both behavior fields informational. These
cases remain executed and covered. Native tests own their current RFC semantics.

The run directory and adjacent `.tar.gz` preserve configs, exact expected
manifest, all per-case JSON/HTML and wire logs, process logs, source revision and
dirty source hashes, image labels/digest/runtime inventory, provider/compiler
and executable hashes, sampled Titan RSS, report durations, total wall time and
evidence bytes. Prefix hashes must remain stable throughout execution.
`summary.json` is the outcome and `evidence-sha256.json` fingerprints the files.
Docker exit zero alone cannot pass. This Linux container run makes no native
Windows, macOS, arm64, or verified-wss claim.

To recheck archived role reports:

```sh
python3 check_reports.py /path/to/run/reports/servers --agent EXACT_SERVER_AGENT --role server
python3 check_reports.py /path/to/run/reports/clients --agent EXACT_CLIENT_AGENT --role client
```

The checker unit tests inject both-role passes and malformed/missing/false-green
reports, including close failures hidden behind OK message results. They also
prove that an empty manifest or edited case selection/informational policy fails.
The orchestration tests use real disposable children to prove owned process-group
retirement and joining, failing deadlines/peer exits, and exact driver evidence.

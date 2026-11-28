#!/usr/bin/env python3
"""Check Titan's bundled stdlib dependencies and LuaRocks rockspec dependencies.

Parses authoritative pins directly from the repository (Makefile,
vendor/*/dependencies.tsv, vendor/*/UPSTREAM.md, scripts/build_uwasi_bundle.mjs,
titan-*.rockspec, and luarocks.lock), verifies cross-file pin parity, and
compares them against upstream GitHub releases/tags/commits and the LuaRocks
5.5 manifest.

Excluded by design: minicoro (heavily modified in-tree, no longer tracked as
upstream vendored code) and host toolchains (Lua, LuaRocks, wasi-sdk, Binaryen).
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple
import urllib.error
import urllib.parse
import urllib.request


GITHUB_API = "https://api.github.com"
LUAROCKS_MANIFEST_5_5 = "https://luarocks.org/manifest-5.5"
ISSUE_MARKER = "<!-- titan-bundled-deps-tracker -->"
USER_AGENT = "titan-dependency-check"

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
ROCK_VERSION_RE = re.compile(r"^(\d+(?:\.\d+)*)-(\d+)$")
SIMPLE_VERSION_RE = re.compile(r"^(\d+(?:\.\d+)*)(?:-(\d+))?$")
SHA40_RE = re.compile(r"^[0-9a-f]{40}$")


@dataclass
class DepStatus:
    name: str
    section: str  # "bundled" | "rockspec"
    policy: str
    pinned: str
    latest: Optional[str]
    status: str  # "up-to-date" | "outdated" | "ahead" | "tracked" | "offline" | "error"
    url: str = ""
    notes: str = ""
    constraint: str = ""
    error: str = ""


def parse_numeric_tuple(text: str) -> Tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


def compare_numeric_tuples(a: Sequence[int], b: Sequence[int]) -> int:
    width = max(len(a), len(b))
    pa = tuple(a) + (0,) * (width - len(a))
    pb = tuple(b) + (0,) * (width - len(b))
    if pa < pb:
        return -1
    if pa > pb:
        return 1
    return 0


def parse_rock_version(text: str) -> Tuple[Tuple[int, ...], int]:
    match = SIMPLE_VERSION_RE.match(text.strip())
    if not match:
        raise ValueError(f"not a numeric LuaRocks version: {text!r}")
    base = parse_numeric_tuple(match.group(1))
    rev = int(match.group(2)) if match.group(2) is not None else -1
    return base, rev


def compare_rock_versions(a: str, b: str) -> int:
    base_a, rev_a = parse_rock_version(a)
    base_b, rev_b = parse_rock_version(b)
    cmp_base = compare_numeric_tuples(base_a, base_b)
    if cmp_base != 0:
        return cmp_base
    if rev_a == -1 or rev_b == -1:
        return 0
    if rev_a < rev_b:
        return -1
    if rev_a > rev_b:
        return 1
    return 0


def rock_version_sort_key(text: str) -> Tuple[Tuple[int, ...], int]:
    base, rev = parse_rock_version(text)
    padded = base + (0,) * max(0, 4 - len(base))
    return padded, rev


def satisfies_clause(version: str, clause: str) -> bool:
    clause = clause.strip()
    if not clause:
        return True
    match = re.match(r"^(~>|>=|<=|==|!=|>|<|=)?\s*(\d+(?:\.\d+)*(?:-\d+)?)$", clause)
    if not match:
        raise ValueError(f"unsupported rockspec version constraint: {clause!r}")
    op = match.group(1) or "=="
    target = match.group(2)
    cmp_val = compare_rock_versions(version, target)
    if op in ("==", "="):
        return cmp_val == 0
    if op == "!=":
        return cmp_val != 0
    if op == ">=":
        return cmp_val >= 0
    if op == ">":
        return cmp_val > 0
    if op == "<=":
        return cmp_val <= 0
    if op == "<":
        return cmp_val < 0
    if op == "~>":
        if cmp_val < 0:
            return False
        target_base, _ = parse_rock_version(target)
        if len(target_base) == 1:
            upper = (target_base[0] + 1,)
        else:
            # Pessimistic operator `~> X.Y` -> `< (X+1).0`, `~> X.Y.Z` -> `< X.(Y+1).0`.
            upper = target_base[:-2] + (target_base[-2] + 1,)
        ver_base, _ = parse_rock_version(version)
        return compare_numeric_tuples(ver_base, upper) < 0
    raise ValueError(f"unhandled operator: {op!r}")


def satisfies_constraint(version: str, constraint: str) -> bool:
    parts = [part.strip() for part in constraint.split(",") if part.strip()]
    return all(satisfies_clause(version, part) for part in parts)


def read_make_vars(path: Path) -> Dict[str, str]:
    text = path.read_text(encoding="utf-8")
    values: Dict[str, str] = {}
    for line in text.splitlines():
        match = re.match(r"^([A-Z0-9_]+)\s*(?::=|\?=|=)\s*(.*?)\s*$", line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def read_tsv(path: Path) -> Dict[str, Dict[str, str]]:
    rows: Dict[str, Dict[str, str]] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5:
            raise ValueError(f"{path}:{lineno}: expected 5 TSV columns, got {len(fields)}")
        name, directory, tarball, sha256, url = fields
        rows[name] = {
            "dir": directory,
            "tarball": tarball,
            "sha256": sha256,
            "url": url,
        }
    return rows


def read_upstream_md(path: Path) -> Dict[str, str]:
    text = path.read_text(encoding="utf-8")
    result: Dict[str, str] = {}
    for key in ("Upstream", "Release", "Commit"):
        match = re.search(rf"^- {key}:\s*(?:`([^`]+)`|<([^>]+)>|(\S+))", text, re.MULTILINE)
        if match:
            result[key.lower()] = next(group for group in match.groups() if group is not None)
    return result


def read_uwasi_builder_commit(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = re.search(r"^const\s+UPSTREAM\s*=\s*'([0-9a-f]{40})';", text, re.MULTILINE)
    if not match:
        raise ValueError(f"{path}: missing UPSTREAM commit constant")
    return match.group(1)


def parse_rockspec_table(text: str, key: str) -> List[Tuple[str, str]]:
    match = re.search(rf"^{re.escape(key)}\s*=\s*\{{(.*?)^\}}", text, re.MULTILINE | re.DOTALL)
    if not match:
        return []
    entries: List[Tuple[str, str]] = []
    for item in re.findall(r'"([^"]+)"', match.group(1)):
        parts = item.strip().split(None, 1)
        name = parts[0].lower()
        constraint = parts[1].strip() if len(parts) > 1 else ""
        entries.append((name, constraint))
    return entries


def read_rockspec(root: Path) -> Tuple[Path, List[Tuple[str, str]], List[Tuple[str, str]]]:
    candidates = sorted(root.glob("titan-*.rockspec"))
    if len(candidates) != 1:
        raise ValueError(f"expected exactly one titan-*.rockspec in {root}, found {len(candidates)}")
    path = candidates[0]
    text = path.read_text(encoding="utf-8")
    return (
        path,
        parse_rockspec_table(text, "dependencies"),
        parse_rockspec_table(text, "test_dependencies"),
    )


def read_luarocks_lock(path: Path) -> Dict[str, str]:
    text = path.read_text(encoding="utf-8")
    match = re.search(r"dependencies\s*=\s*\{(.*?)\}", text, re.DOTALL)
    if not match:
        raise ValueError(f"{path}: missing dependencies table")
    locked: Dict[str, str] = {}
    for quoted, bare, version in re.findall(
        r'(?:\["([^"]+)"\]|([A-Za-z0-9_.-]+))\s*=\s*"([^"]+)"', match.group(1)
    ):
        locked[(quoted or bare).lower()] = version.strip()
    return locked


def sqlite_release_code(version: str) -> str:
    match = SEMVER_RE.match(version)
    if not match:
        raise ValueError(f"invalid sqlite3 version: {version!r}")
    major, minor, patch = (int(group) for group in match.groups())
    return str(major * 1_000_000 + minor * 10_000 + patch * 100)


def load_repo_pins(root: Path) -> Tuple[Dict[str, Any], List[str]]:
    parity_errors: List[str] = []
    mk = read_make_vars(root / "Makefile")
    win_tsv = read_tsv(root / "vendor/windows-native/dependencies.tsv")
    bt_tsv = read_tsv(root / "vendor/libbacktrace/dependencies.tsv")
    lpeg_md = read_upstream_md(root / "vendor/lpeglabel/UPSTREAM.md")
    uwasi_md = read_upstream_md(root / "vendor/uwasi/UPSTREAM.md")
    uwasi_builder_sha = read_uwasi_builder_commit(root / "scripts/build_uwasi_bundle.mjs")
    rockspec_path, rock_deps, rock_test_deps = read_rockspec(root)
    lock_deps = read_luarocks_lock(root / "luarocks.lock")

    # Cross-file parity: Makefile vs vendor/windows-native/dependencies.tsv
    expected_win = {
        "libuv": (f"libuv-v{mk['LIBUV_VERSION']}", mk["LIBUV_SHA256"]),
        "llhttp": (f"llhttp-release-v{mk['LLHTTP_VERSION']}", mk["LLHTTP_SHA256"]),
        "sqlite3": (f"sqlite-autoconf-{mk['SQLITE3_RELEASE']}", mk["SQLITE3_SHA256"]),
        "openssl": (f"openssl-{mk['OPENSSL_VERSION']}", mk["OPENSSL_SHA256"]),
    }
    for name, (exp_dir, exp_sha) in expected_win.items():
        row = win_tsv.get(name)
        if not row:
            parity_errors.append(f"vendor/windows-native/dependencies.tsv missing row for {name}")
            continue
        if row["dir"] != exp_dir:
            parity_errors.append(
                f"{name}: Makefile expects {exp_dir}, vendor/windows-native/dependencies.tsv has {row['dir']}"
            )
        if row["sha256"] != exp_sha:
            parity_errors.append(
                f"{name}: Makefile SHA-256 ({exp_sha[:12]}) disagrees with vendor/windows-native/dependencies.tsv ({row['sha256'][:12]})"
            )

    # SQLite version vs numeric release code parity
    exp_sqlite_rel = sqlite_release_code(mk["SQLITE3_VERSION"])
    if mk["SQLITE3_RELEASE"] != exp_sqlite_rel:
        parity_errors.append(
            f"sqlite3: Makefile SQLITE3_VERSION={mk['SQLITE3_VERSION']} implies SQLITE3_RELEASE={exp_sqlite_rel}, got {mk['SQLITE3_RELEASE']}"
        )

    # libbacktrace Windows TSV self-consistency
    bt_row = bt_tsv.get("libbacktrace")
    bt_sha = ""
    if not bt_row:
        parity_errors.append("vendor/libbacktrace/dependencies.tsv missing row for libbacktrace")
    else:
        dir_match = re.match(r"^libbacktrace-([0-9a-f]{40})$", bt_row["dir"])
        if not dir_match:
            parity_errors.append(f"libbacktrace: unexpected directory name {bt_row['dir']!r}")
        else:
            bt_sha = dir_match.group(1)
            if bt_row["tarball"] != f"libbacktrace-{bt_sha}.tar.gz":
                parity_errors.append(f"libbacktrace: tarball {bt_row['tarball']!r} disagrees with SHA {bt_sha[:12]}")
            if not bt_row["url"].endswith(bt_sha):
                parity_errors.append(f"libbacktrace: URL {bt_row['url']!r} disagrees with SHA {bt_sha[:12]}")

    # LPegLabel Makefile vs vendor/lpeglabel/UPSTREAM.md
    lpeg_md_rel = lpeg_md.get("release", "").lstrip("v")
    lpeg_md_sha = lpeg_md.get("commit", "")
    if lpeg_md_rel != mk["LPEGLABEL_VERSION"]:
        parity_errors.append(
            f"lpeglabel: Makefile LPEGLABEL_VERSION={mk['LPEGLABEL_VERSION']} disagrees with vendor/lpeglabel/UPSTREAM.md ({lpeg_md.get('release')})"
        )
    if lpeg_md_sha != mk["LPEGLABEL_COMMIT"]:
        parity_errors.append(
            f"lpeglabel: Makefile LPEGLABEL_COMMIT={mk['LPEGLABEL_COMMIT'][:12]} disagrees with vendor/lpeglabel/UPSTREAM.md ({lpeg_md_sha[:12]})"
        )

    # uwasi UPSTREAM.md vs scripts/build_uwasi_bundle.mjs
    uwasi_ver = uwasi_md.get("release", "").lstrip("v")
    uwasi_sha = uwasi_md.get("commit", "")
    if not SHA40_RE.match(uwasi_sha):
        parity_errors.append(f"uwasi: invalid commit in vendor/uwasi/UPSTREAM.md: {uwasi_sha!r}")
    elif uwasi_sha != uwasi_builder_sha:
        parity_errors.append(
            f"uwasi: vendor/uwasi/UPSTREAM.md commit ({uwasi_sha[:12]}) disagrees with scripts/build_uwasi_bundle.mjs ({uwasi_builder_sha[:12]})"
        )

    # Rockspec vs luarocks.lock parity (excluding lua interpreter)
    rock_runtime = [(name, constraint) for name, constraint in rock_deps if name != "lua"]
    rock_runtime_names = {name for name, _ in rock_runtime}
    lock_names = set(lock_deps.keys())
    for missing in sorted(rock_runtime_names - lock_names):
        parity_errors.append(f"luarocks.lock missing rockspec dependency {missing!r}")
    for extra in sorted(lock_names - rock_runtime_names):
        parity_errors.append(f"luarocks.lock pins {extra!r} which is not in {rockspec_path.name} dependencies")
    for name, constraint in rock_runtime:
        locked = lock_deps.get(name)
        if locked and constraint and not satisfies_constraint(locked, constraint):
            parity_errors.append(
                f"{name}: luarocks.lock version {locked} does not satisfy {rockspec_path.name} constraint {constraint!r}"
            )

    pins = {
        "bundled": {
            "libuv": {"version": mk["LIBUV_VERSION"]},
            "llhttp": {"version": mk["LLHTTP_VERSION"]},
            "sqlite3": {"version": mk["SQLITE3_VERSION"]},
            "libbacktrace": {"commit": bt_sha},
            "lpeglabel": {"version": mk["LPEGLABEL_VERSION"], "commit": mk["LPEGLABEL_COMMIT"]},
            "uwasi": {"version": uwasi_ver, "commit": uwasi_sha},
            "openssl": {"version": mk["OPENSSL_VERSION"], "mode": mk.get("OPENSSL_MODE", "system")},
        },
        "rockspec_file": rockspec_path.name,
        "rockspec_deps": rock_runtime,
        "rockspec_test_deps": [(name, constraint) for name, constraint in rock_test_deps if name != "lua"],
        "luarocks_lock": lock_deps,
    }
    return pins, parity_errors


LUA_TOKEN_RE = re.compile(
    r'--[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\{|\}|\[|\]|=|[A-Za-z_][A-Za-z0-9_]*'
)


def unquote_lua_string(token: str) -> str:
    body = token[1:-1]
    return re.sub(r"\\(.)", r"\1", body)


def parse_luarocks_manifest(text: str, target_rocks: Iterable[str]) -> Dict[str, List[str]]:
    """Extract version strings for `target_rocks` from a LuaRocks manifest file."""
    targets = {name.lower() for name in target_rocks}
    found: Dict[str, List[str]] = {name: [] for name in targets}

    repo_match = re.search(r"(?:^|\n)repository\s*=\s*\{", text)
    if not repo_match:
        raise ValueError("LuaRocks manifest missing top-level `repository = {` table")

    depth = 1
    current_rock: Optional[str] = None
    in_bracket = False
    pending_key: Optional[str] = None
    after_eq = False

    for match in LUA_TOKEN_RE.finditer(text, repo_match.end()):
        tok = match.group(0)
        if tok.startswith("--"):
            continue
        if tok == "{":
            if depth == 1:
                current_rock = pending_key.lower() if (after_eq and pending_key) else None
            elif depth == 2 and current_rock in targets and after_eq and pending_key:
                found[current_rock].append(pending_key)
            depth += 1
            pending_key = None
            after_eq = False
            in_bracket = False
        elif tok == "}":
            depth -= 1
            if depth == 1:
                current_rock = None
            pending_key = None
            after_eq = False
            in_bracket = False
            if depth == 0:
                break
        elif depth in (1, 2):
            if tok == "[":
                in_bracket = True
            elif tok == "]":
                in_bracket = False
            elif tok == "=":
                after_eq = True
            elif tok[0] in ('"', "'"):
                if in_bracket:
                    pending_key = unquote_lua_string(tok)
                    after_eq = False
            elif not in_bracket and not after_eq:
                pending_key = tok
    return found


def latest_stable_rock_version(versions: Sequence[str]) -> Optional[str]:
    stable = [ver for ver in versions if ROCK_VERSION_RE.match(ver)]
    if not stable:
        return None
    return max(stable, key=rock_version_sort_key)


class HttpFetcher:
    def __init__(self, github_token: Optional[str] = None, timeout: int = 30) -> None:
        self.github_token = github_token
        self.timeout = timeout

    def get_text(self, url: str, headers: Optional[Dict[str, str]] = None) -> str:
        req_headers = {"User-Agent": USER_AGENT}
        if headers:
            req_headers.update(headers)
        request = urllib.request.Request(url, headers=req_headers)
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            return response.read().decode("utf-8", errors="replace")

    def github_json(self, path: str) -> Any:
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if self.github_token:
            headers["Authorization"] = f"Bearer {self.github_token}"
        url = f"{GITHUB_API}{path}" if path.startswith("/") else path
        return json.loads(self.get_text(url, headers=headers))


def latest_github_release(
    fetcher: HttpFetcher,
    repo: str,
    tag_regex: str,
    max_pages: int = 3,
) -> Tuple[str, str]:
    pattern = re.compile(tag_regex)
    best: Optional[Tuple[Tuple[int, ...], str, str]] = None
    for page in range(1, max_pages + 1):
        releases = fetcher.github_json(f"/repos/{repo}/releases?per_page=100&page={page}")
        if not releases:
            break
        for rel in releases:
            if rel.get("draft") or rel.get("prerelease"):
                continue
            tag = rel.get("tag_name") or ""
            match = pattern.match(tag)
            if not match:
                continue
            version = match.group(1)
            key = parse_numeric_tuple(version)
            if best is None or compare_numeric_tuples(key, best[0]) > 0:
                best = (key, version, rel.get("html_url") or f"https://github.com/{repo}/releases/tag/{tag}")
        if best is not None:
            break
    if best is None:
        raise RuntimeError(f"no matching stable release in {repo} for /{tag_regex}/")
    return best[1], best[2]


def latest_github_matching_ref(
    fetcher: HttpFetcher,
    repo: str,
    prefix: str,
    ref_regex: str,
) -> Tuple[str, str]:
    pattern = re.compile(ref_regex)
    refs = fetcher.github_json(f"/repos/{repo}/git/matching-refs/{prefix}")
    best: Optional[Tuple[Tuple[int, ...], str, str]] = None
    for item in refs:
        ref = item.get("ref") or ""
        match = pattern.match(ref)
        if not match:
            continue
        version = match.group(1)
        key = parse_numeric_tuple(version)
        if best is None or compare_numeric_tuples(key, best[0]) > 0:
            tag = ref.removeprefix("refs/tags/")
            best = (key, version, tag)
    if best is None:
        raise RuntimeError(f"no matching tag in {repo} under {prefix}")
    return best[1], best[2]


def latest_github_rock_tag(fetcher: HttpFetcher, repo: str, tag_regex: str) -> Tuple[str, str]:
    pattern = re.compile(tag_regex)
    tags = fetcher.github_json(f"/repos/{repo}/tags?per_page=100")
    best: Optional[Tuple[Tuple[Tuple[int, ...], int], str, str]] = None
    for item in tags:
        tag = item.get("name") or ""
        match = pattern.match(tag)
        if not match:
            continue
        version = match.group(1)
        key = rock_version_sort_key(version)
        if best is None or key > best[0]:
            best = (key, version, tag)
    if best is None:
        raise RuntimeError(f"no matching tag in {repo} for /{tag_regex}/")
    return best[1], best[2]


def compare_version_status(pinned: str, latest: str, cmp_fn: Callable[[str, str], int]) -> str:
    diff = cmp_fn(pinned, latest)
    if diff == 0:
        return "up-to-date"
    if diff < 0:
        return "outdated"
    return "ahead"


def check_bundled_dependencies(
    pins: Dict[str, Any],
    fetcher: Optional[HttpFetcher],
) -> List[DepStatus]:
    bundled = pins["bundled"]
    results: List[DepStatus] = []

    def run_check(
        name: str,
        policy: str,
        pinned: str,
        notes: str,
        probe: Callable[[HttpFetcher], Tuple[str, str, str, str]],
    ) -> None:
        if fetcher is None:
            results.append(
                DepStatus(name=name, section="bundled", policy=policy, pinned=pinned, latest=None, status="offline", notes=notes)
            )
            return
        try:
            latest, status, url, extra_notes = probe(fetcher)
            combined_notes = "; ".join(part for part in (extra_notes, notes) if part)
            results.append(
                DepStatus(
                    name=name,
                    section="bundled",
                    policy=policy,
                    pinned=pinned,
                    latest=latest,
                    status=status,
                    url=url,
                    notes=combined_notes,
                )
            )
        except Exception as exc:  # noqa: BLE001
            results.append(
                DepStatus(
                    name=name,
                    section="bundled",
                    policy=policy,
                    pinned=pinned,
                    latest=None,
                    status="error",
                    notes=notes,
                    error=str(exc),
                )
            )

    def probe_libuv(http: HttpFetcher) -> Tuple[str, str, str, str]:
        cur = bundled["libuv"]["version"]
        latest, url = latest_github_release(http, "libuv/libuv", r"^v(\d+\.\d+\.\d+)$")
        status = compare_version_status(
            cur, latest, lambda a, b: compare_numeric_tuples(parse_numeric_tuple(a), parse_numeric_tuple(b))
        )
        if status == "outdated":
            url = f"https://github.com/libuv/libuv/compare/v{cur}...v{latest}"
        return latest, status, url, ""

    def probe_llhttp(http: HttpFetcher) -> Tuple[str, str, str, str]:
        cur = bundled["llhttp"]["version"]
        latest, tag = latest_github_matching_ref(
            http, "nodejs/llhttp", "tags/release/v", r"^refs/tags/release/v(\d+\.\d+\.\d+)$"
        )
        status = compare_version_status(
            cur, latest, lambda a, b: compare_numeric_tuples(parse_numeric_tuple(a), parse_numeric_tuple(b))
        )
        url = (
            f"https://github.com/nodejs/llhttp/compare/release/v{cur}...{tag}"
            if status == "outdated"
            else f"https://github.com/nodejs/llhttp/releases/tag/{tag}"
        )
        return latest, status, url, ""

    def probe_sqlite3(http: HttpFetcher) -> Tuple[str, str, str, str]:
        cur = bundled["sqlite3"]["version"]
        latest, _ = latest_github_matching_ref(
            http, "sqlite/sqlite", "tags/version-", r"^refs/tags/version-(\d+\.\d+\.\d+)$"
        )
        status = compare_version_status(
            cur, latest, lambda a, b: compare_numeric_tuples(parse_numeric_tuple(a), parse_numeric_tuple(b))
        )
        return latest, status, "https://sqlite.org/changes.html", ""

    def probe_libbacktrace(http: HttpFetcher) -> Tuple[str, str, str, str]:
        cur = bundled["libbacktrace"]["commit"]
        head = http.github_json("/repos/ianlancetaylor/libbacktrace/commits/master")
        latest_sha = head["sha"]
        latest_date = (head.get("commit", {}).get("committer", {}).get("date") or "")[:10]
        if latest_sha == cur:
            return (
                f"{latest_sha[:12]} ({latest_date})" if latest_date else latest_sha[:12],
                "up-to-date",
                f"https://github.com/ianlancetaylor/libbacktrace/commit/{latest_sha}",
                "",
            )
        ahead_note = ""
        try:
            cmp_data = http.github_json(f"/repos/ianlancetaylor/libbacktrace/compare/{cur}...{latest_sha}")
            ahead = cmp_data.get("ahead_by")
            if isinstance(ahead, int):
                ahead_note = f"{ahead} commit(s) behind master"
        except Exception:  # noqa: BLE001
            pass
        latest_label = f"{latest_sha[:12]} ({latest_date})" if latest_date else latest_sha[:12]
        return (
            latest_label,
            "outdated",
            f"https://github.com/ianlancetaylor/libbacktrace/compare/{cur[:12]}...{latest_sha[:12]}",
            ahead_note,
        )

    def probe_lpeglabel(http: HttpFetcher) -> Tuple[str, str, str, str]:
        cur = bundled["lpeglabel"]["version"]
        latest, tag = latest_github_rock_tag(http, "sqmedeiros/lpeglabel", r"^v(\d+\.\d+\.\d+(?:-\d+)?)$")
        status = compare_version_status(cur, latest, compare_rock_versions)
        url = (
            f"https://github.com/sqmedeiros/lpeglabel/compare/v{cur}...{tag}"
            if status == "outdated"
            else f"https://github.com/sqmedeiros/lpeglabel/releases/tag/{tag}"
        )
        return latest, status, url, ""

    def probe_uwasi(http: HttpFetcher) -> Tuple[str, str, str, str]:
        cur = bundled["uwasi"]["version"]
        latest, url = latest_github_release(http, "swiftwasm/uwasi", r"^v?(\d+\.\d+\.\d+)$")
        status = compare_version_status(
            cur, latest, lambda a, b: compare_numeric_tuples(parse_numeric_tuple(a), parse_numeric_tuple(b))
        )
        if status == "outdated":
            url = f"https://github.com/swiftwasm/uwasi/compare/{cur}...{latest}"
        return latest, status, url, ""

    def probe_openssl(http: HttpFetcher) -> Tuple[str, str, str, str]:
        cur = bundled["openssl"]["version"]
        latest, url = latest_github_release(http, "openssl/openssl", r"^openssl-(4\.\d+\.\d+)$", max_pages=5)
        status = compare_version_status(
            cur, latest, lambda a, b: compare_numeric_tuples(parse_numeric_tuple(a), parse_numeric_tuple(b))
        )
        return latest, status, url, "tracks latest 4.* series"

    run_check("libuv", "bundled", bundled["libuv"]["version"], "re-check vendor/libuv/ patches", probe_libuv)
    run_check("llhttp", "bundled", bundled["llhttp"]["version"], "", probe_llhttp)
    run_check("sqlite3", "bundled (native + browser)", bundled["sqlite3"]["version"], "", probe_sqlite3)
    run_check(
        "libbacktrace",
        "bundled (Win pinned; Unix master)",
        bundled["libbacktrace"]["commit"][:12] if bundled["libbacktrace"]["commit"] else "missing",
        "re-check vendor/libbacktrace/ patches",
        probe_libbacktrace,
    )
    run_check("lpeglabel", "vendored", bundled["lpeglabel"]["version"], "re-check vendor/lpeglabel/ edits", probe_lpeglabel)
    run_check("uwasi", "vendored (browser VFS)", bundled["uwasi"]["version"], "re-check vendor/uwasi/ seams + build_uwasi_bundle.mjs", probe_uwasi)
    run_check(
        "openssl",
        f"optional bundled (default {bundled['openssl']['mode']})",
        bundled["openssl"]["version"],
        "OPENSSL_MODE=bundled fallback",
        probe_openssl,
    )
    return results


def check_rockspec_dependencies(
    pins: Dict[str, Any],
    fetcher: Optional[HttpFetcher],
    manifest_text: Optional[str] = None,
) -> List[DepStatus]:
    runtime_deps: List[Tuple[str, str]] = pins["rockspec_deps"]
    test_deps: List[Tuple[str, str]] = pins["rockspec_test_deps"]
    locked: Dict[str, str] = pins["luarocks_lock"]

    all_entries: List[Tuple[str, str, str]] = (
        [(name, constraint, "rockspec (locked)") for name, constraint in runtime_deps]
        + [(name, constraint, "test_dependencies") for name, constraint in test_deps]
    )

    manifest_error = ""
    manifest_versions: Dict[str, List[str]] = {}
    if manifest_text is not None:
        try:
            manifest_versions = parse_luarocks_manifest(manifest_text, [name for name, _, _ in all_entries])
        except Exception as exc:  # noqa: BLE001
            manifest_error = str(exc)
    elif fetcher is not None:
        try:
            fetched = fetcher.get_text(LUAROCKS_MANIFEST_5_5)
            manifest_versions = parse_luarocks_manifest(fetched, [name for name, _, _ in all_entries])
        except Exception as exc:  # noqa: BLE001
            manifest_error = f"failed to fetch {LUAROCKS_MANIFEST_5_5}: {exc}"

    results: List[DepStatus] = []
    for name, constraint, policy in all_entries:
        pinned = locked.get(name, "(unpinned)")
        url = f"https://luarocks.org/search?q={urllib.parse.quote(name)}"
        if fetcher is None and manifest_text is None:
            results.append(
                DepStatus(
                    name=name,
                    section="rockspec",
                    policy=policy,
                    pinned=pinned,
                    latest=None,
                    status="offline",
                    constraint=constraint,
                    url=url,
                )
            )
            continue
        if manifest_error:
            results.append(
                DepStatus(
                    name=name,
                    section="rockspec",
                    policy=policy,
                    pinned=pinned,
                    latest=None,
                    status="error",
                    constraint=constraint,
                    url=url,
                    error=manifest_error,
                )
            )
            continue

        latest = latest_stable_rock_version(manifest_versions.get(name, []))
        if latest is None:
            results.append(
                DepStatus(
                    name=name,
                    section="rockspec",
                    policy=policy,
                    pinned=pinned,
                    latest=None,
                    status="error",
                    constraint=constraint,
                    url=url,
                    error=f"no stable version found for {name!r} in LuaRocks 5.5 manifest",
                )
            )
            continue

        if name in locked:
            status = compare_version_status(locked[name], latest, compare_rock_versions)
            notes = ""
            if status == "outdated" and constraint and not satisfies_constraint(latest, constraint):
                notes = f"latest {latest} is outside rockspec constraint `{constraint}`"
        else:
            if constraint and not satisfies_constraint(latest, constraint):
                status = "outdated"
                notes = f"latest {latest} does not satisfy rockspec constraint `{constraint}`"
            else:
                status = "tracked"
                notes = "unpinned test floor"

        results.append(
            DepStatus(
                name=name,
                section="rockspec",
                policy=policy,
                pinned=pinned,
                latest=latest,
                status=status,
                constraint=constraint,
                url=url,
                notes=notes,
            )
        )
    return results


def render_markdown(
    pins: Dict[str, Any],
    bundled: Sequence[DepStatus],
    rockspec: Sequence[DepStatus],
    parity_errors: Sequence[str],
    *,
    for_issue: bool = False,
) -> str:
    lines: List[str] = []
    if for_issue:
        lines.append(ISSUE_MARKER)
        lines.append("")
    lines.append("## Bundled and vendored stdlib dependencies")
    lines.append("")
    lines.append("| Dependency | Policy | Pinned | Latest | Status | Details |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for item in bundled:
        latest_cell = f"`{item.latest}`" if item.latest else "—"
        if item.latest and item.url:
            latest_cell = f"[`{item.latest}`]({item.url})"
        detail = item.error if item.status == "error" else item.notes
        lines.append(
            f"| `{item.name}` | {item.policy} | `{item.pinned}` | {latest_cell} | **{item.status}** | {detail} |"
        )
    lines.append("")
    lines.append(f"## Rockspec dependencies (`{pins['rockspec_file']}` + `luarocks.lock`, LuaRocks 5.5)")
    lines.append("")
    lines.append("| Rock | Kind | Constraint | Pinned | Latest | Status | Details |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- |")
    for item in rockspec:
        latest_cell = f"`{item.latest}`" if item.latest else "—"
        if item.latest and item.url:
            latest_cell = f"[`{item.latest}`]({item.url})"
        pinned_cell = f"`{item.pinned}`" if item.pinned != "(unpinned)" else item.pinned
        constraint_cell = f"`{item.constraint}`" if item.constraint else "—"
        detail = item.error if item.status == "error" else item.notes
        lines.append(
            f"| `{item.name}` | {item.policy} | {constraint_cell} | {pinned_cell} | {latest_cell} | **{item.status}** | {detail} |"
        )

    if parity_errors:
        lines.append("")
        lines.append("## Internal pin parity errors")
        lines.append("")
        for err in parity_errors:
            lines.append(f"- {err}")

    lookup_errors = [item for item in (*bundled, *rockspec) if item.status == "error"]
    if lookup_errors:
        lines.append("")
        lines.append("## Upstream lookup errors")
        lines.append("")
        for item in lookup_errors:
            lines.append(f"- `{item.name}`: {item.error}")

    lines.append("")
    lines.append(
        "_Notes: `minicoro` is intentionally excluded (modified in-tree). "
        "Re-run locally with `python3 scripts/check_bundled_deps.py` (or `--offline` for pin parity only)._"
    )
    return "\n".join(lines) + "\n"


def render_text(
    pins: Dict[str, Any],
    bundled: Sequence[DepStatus],
    rockspec: Sequence[DepStatus],
    parity_errors: Sequence[str],
) -> str:
    lines: List[str] = ["Bundled and vendored stdlib dependencies:"]
    for item in bundled:
        latest = item.latest or "-"
        extra = f" ({item.error or item.notes})" if (item.error or item.notes) else ""
        lines.append(f"  {item.name:14s} pinned={item.pinned:14s} latest={latest:25s} [{item.status}]{extra}")
    lines.append(f"Rockspec dependencies ({pins['rockspec_file']} + luarocks.lock):")
    for item in rockspec:
        latest = item.latest or "-"
        extra = f" ({item.error or item.notes})" if (item.error or item.notes) else ""
        lines.append(
            f"  {item.name:14s} constraint={item.constraint:10s} pinned={item.pinned:12s} latest={latest:12s} [{item.status}]{extra}"
        )
    if parity_errors:
        lines.append("Pin parity errors:")
        for err in parity_errors:
            lines.append(f"  - {err}")
    return "\n".join(lines) + "\n"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--offline", action="store_true", help="Verify local pin parity only without network access")
    parser.add_argument("--format", choices=("text", "markdown", "json"), default="text")
    parser.add_argument("--output", type=Path, help="Write report output to PATH instead of stdout")
    parser.add_argument("--fail-on-outdated", action="store_true", help="Exit 1 when any dependency is outdated or ahead")
    parser.add_argument("--luarocks-manifest", type=Path, help="Read LuaRocks manifest from a local file instead of luarocks.org")
    args = parser.parse_args(argv)

    pins, parity_errors = load_repo_pins(args.root.resolve())
    token = os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN")
    fetcher = None if args.offline else HttpFetcher(github_token=token)
    manifest_text = args.luarocks_manifest.read_text(encoding="utf-8") if args.luarocks_manifest else None

    bundled = check_bundled_dependencies(pins, fetcher)
    rockspec = check_rockspec_dependencies(pins, fetcher, manifest_text=manifest_text)

    outdated = [item for item in (*bundled, *rockspec) if item.status in ("outdated", "ahead")]
    lookup_errors = [item for item in (*bundled, *rockspec) if item.status == "error"]

    markdown = render_markdown(pins, bundled, rockspec, parity_errors, for_issue=False)
    issue_body = render_markdown(pins, bundled, rockspec, parity_errors, for_issue=True)

    if args.format == "json":
        payload = {
            "outdated_count": len(outdated),
            "parity_errors": parity_errors,
            "lookup_errors": [{"name": item.name, "error": item.error} for item in lookup_errors],
            "bundled": [asdict(item) for item in bundled],
            "rockspec": [asdict(item) for item in rockspec],
            "markdown": markdown,
            "issue_body": issue_body,
        }
        rendered = json.dumps(payload, indent=2) + "\n"
    elif args.format == "markdown":
        rendered = markdown
    else:
        rendered = render_text(pins, bundled, rockspec, parity_errors)

    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)

    if parity_errors or lookup_errors:
        return 2
    if args.fail_on_outdated and outdated:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

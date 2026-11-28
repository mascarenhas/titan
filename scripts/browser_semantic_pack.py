#!/usr/bin/env python3
"""Verify a local source rock/SDK pair and publish a deterministic semantic pack."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile


SEMANTIC_FILES = ("absent-modules", "analysis-target", "titan.a")
NOTICES = (
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    *(f"LICENSES/{name}-LICENSE" for name in (
        "go", "lpeg", "lpeg-patterns", "lpeglabel", "lua", "sqlite3", "ta-regex", "uwasi"
    )),
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def regular(path):
    require(path.is_file() and not path.is_symlink(), f"{path}: expected a regular file")
    return path.read_bytes()


def git(tree, *args):
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith("GIT_")}
    env.update(GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1",
               GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    return subprocess.check_output(["git", "-C", str(tree), *args], env=env)


def git_inventory(tree, commit, directory=""):
    entries, pins = {}, {}
    for line in git(tree, "ls-tree", "-rz", commit).split(b"\0"):
        if not line:
            continue
        info, filename = line.split(b"\t", 1)
        mode, kind, oid = info.decode("ascii").split(" ")
        relative = str(PurePosixPath(directory, filename.decode("utf-8")))
        if mode == "160000" and kind == "commit":
            pins[relative] = oid
            nested, nested_pins = git_inventory(tree / filename.decode("utf-8"), oid, relative)
            entries.update(nested)
            pins.update(nested_pins)
        else:
            require(kind == "blob" and mode in ("100644", "100755"),
                    f"{relative}: unsupported source tree mode {mode}")
            entries[relative] = oid
    return entries, pins


def verify_rock(rock, source, entries, pins, rockspec):
    # LuaRocks removes the top-level .gitignore and can retain the submodule
    # administrative pointers; neither is needed by the unpacked source.
    optional = {"titan/.gitignore"} | {f"titan/{name}/.git" for name in pins}
    expected = {f"titan/{name}": oid for name, oid in entries.items()}
    expected[rockspec] = entries[rockspec]
    directories = {str(parent) + "/" for name in set(expected) | optional
                   for parent in PurePosixPath(name).parents if parent != PurePosixPath(".")}
    with zipfile.ZipFile(rock) as archive:
        known = set()
        for member in archive.infolist():
            name = member.filename
            require(name not in known, f"source rock: duplicate member {name}")
            known.add(name)
            mode = stat.S_IFMT(member.external_attr >> 16)
            if member.is_dir():
                require(name in directories and mode in (0, stat.S_IFDIR),
                        f"source rock: unexpected directory {name}")
                continue
            require((name in expected or name in optional) and mode in (0, stat.S_IFREG),
                    f"source rock: unexpected or nonregular member {name}")
            if name not in expected:
                continue
            filename = name.removeprefix("titan/")
            if filename == ".gitignore" and not (source / filename).exists():
                # It is not a build input; still verify any copy in the rock.
                data = archive.read(member)
            else:
                data = regular(source / filename)
                require(member.file_size == len(data) and archive.read(member) == data,
                        f"source rock: {name} disagrees with the producer source")
            blob = hashlib.sha1(f"blob {len(data)}\0".encode("ascii"), usedforsecurity=False)
            blob.update(data)
            blob_hash = blob.hexdigest()
            require(blob_hash == expected[name], f"source rock: {name} disagrees with the pinned Git tree")
        missing = sorted(set(expected) - known - optional)
        require(not missing, f"source rock: missing {', '.join(missing)}")


def compiler_receipt(args, prefix, pins):
    lua_dir = prefix / "share/lua/5.5"
    native_ext = "dll" if os.name == "nt" else "so"
    lua_path = f"{lua_dir.as_posix()}/?.lua;{lua_dir.as_posix()}/?/init.lua"
    lua_cpath = f"{prefix.as_posix()}/lib/lua/5.5/?.{native_ext}"
    env = {key: value for key, value in os.environ.items()
           if not key.upper().startswith(("TITAN_", "LUA_", "GIT_"))}
    env["TITAN_ROOT"] = str(prefix)
    result = subprocess.check_output([args.lua, "-E", "scripts/browser_semantic_pack.lua",
                                      str(prefix), args.profile, pins["lua-5.5.1"], lua_path, lua_cpath],
                                     env=env, text=True, encoding="utf-8")
    version_row, *files = result.splitlines()
    release, library, abi, api, wasi_sdk, profile = version_row.split("\t")
    verified = dict(row.split("\t") for row in files)
    require(tuple(verified) == SEMANTIC_FILES, "unexpected compiler semantic receipt")
    return release, library, abi, int(api), wasi_sdk, profile, verified


def write_pack(output, payloads):
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".browser-semantics-", delete=False) as temp:
        staged = Path(temp.name)
    try:
        with staged.open("wb") as file, gzip.GzipFile(filename="", mode="wb", fileobj=file,
                                                      compresslevel=9, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.USTAR_FORMAT) as archive:
                for name, data in sorted(payloads.items()):
                    entry = tarfile.TarInfo(name)
                    entry.mode = 0o644
                    entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data))
        staged.chmod(0o644)
        os.replace(staged, output)
    finally:
        staged.unlink(missing_ok=True)


def produce(args):
    source = Path.cwd()
    prefix, rocks_tree = (Path(root).resolve(strict=True) for root in (args.prefix, args.rocks_tree))
    require(prefix == rocks_tree, "browser-semantic-pack requires the same PREFIX and ROCKS_TREE")
    rock, output = Path(args.rock), Path(args.output).resolve()
    require(not output.is_relative_to(prefix), "PACK_OUTPUT must be outside the SDK prefix")
    require(re.fullmatch(r"[0-9a-f]{40}", args.commit), "TITAN_COMMIT must be a full 40-hex commit")
    require(re.fullmatch(r"titan-[0-9]+\.[0-9]+\.[0-9]+-1\.src\.rock", rock.name), "unexpected SOURCE_ROCK basename")
    rockspec = rock.name.removesuffix(".src.rock") + ".rockspec"
    git_root = Path(args.git_root)
    require(git(git_root, "cat-file", "-t", args.commit) == b"commit\n", "TITAN_COMMIT is not a commit")
    entries, pins = git_inventory(git_root, args.commit)
    require(rockspec in entries, f"TITAN_COMMIT lacks {rockspec}")
    rock_bytes = regular(rock)
    verify_rock(io.BytesIO(rock_bytes), source, entries, pins, rockspec)

    # The compiler installed in the chosen SDK must come from the verified
    # sources, not another installation with the same ABI and release number.
    for package in ("titan-compiler", "c-parser"):
        directory = prefix / "share/lua/5.5" / package
        installed = {str(path.relative_to(directory).as_posix()) for path in directory.rglob("*.lua")}
        expected = {name.removeprefix(package + "/"): name for name in entries
                    if name.startswith(package + "/") and name.endswith(".lua")}
        if package == "titan-compiler" and os.name == "nt":
            expected["titanc.lua"] = "titanc"
        require(installed == expected.keys(), f"{directory}: compiler source inventory disagrees with the source rock")
        for name, original in sorted(expected.items()):
            require(regular(directory / name) == regular(source / original),
                    f"{directory / name}: compiler source disagrees with the source rock")
    release, library, abi, api, wasi_sdk, profile, verified = compiler_receipt(args, prefix, pins)
    require(rock.name == f"titan-{release}-1.src.rock", "SOURCE_ROCK release disagrees with the SDK compiler")
    require(output.name == f"titan-{release}-1-browser-semantics.tar.gz", "unexpected PACK_OUTPUT basename")

    payloads, digests, sdk_digests = {}, {}, []
    for name, expected_hash in verified.items():
        relative = f"lib/titan-browser/{library}/{name}"
        data = regular(prefix / relative)
        digest = hashlib.sha256(data).hexdigest()
        require(digest == expected_hash, f"{relative}: SDK file changed during validation")
        payloads[relative] = data
        digests[relative] = digest
        sdk_digests.append({"path": relative, "sha256": expected_hash})
    for name in NOTICES:
        relative = f"share/titan/{name}"
        data = regular(prefix / relative)
        require(data and data == regular(source / name), f"{relative}: notice disagrees with the source rock")
        payloads[relative] = data
        digests[relative] = hashlib.sha256(data).hexdigest()

    manifest = {
        "abi": abi,
        "build_profile": profile,
        "wasi_sdk_version": wasi_sdk,
        "files": [{"path": name, "sha256": digests[name], "size": len(data)}
                  for name, data in sorted(payloads.items())],
        "language_server_api": api,
        "library_version": library,
        "release": release,
        "sdk_digests": sorted(sdk_digests, key=lambda row: row["path"]),
        "source_rock": {"name": rock.name, "sha256": hashlib.sha256(rock_bytes).hexdigest()},
        "tag": f"v{release}",
        "titan_commit": args.commit,
    }
    payloads["manifest.json"] = (json.dumps(manifest, ensure_ascii=False, sort_keys=True,
                                            separators=(",", ":")) + "\n").encode("utf-8")
    write_pack(output, payloads)
    print(f"Browser semantic pack ({profile}): {output}")


def nonempty(value):
    if not value.strip():
        raise argparse.ArgumentTypeError("a nonempty value is required")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)

    for name in ("lua", "prefix", "rocks-tree", "rock", "output", "commit", "git-root"):
        parser.add_argument(f"--{name}", type=nonempty, required=True)
    parser.add_argument("--profile", choices=("production", "validation"), required=True)
    args = parser.parse_args()
    try:
        produce(args)
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f"browser-semantic-pack: {error}\n")


if __name__ == "__main__":
    main()

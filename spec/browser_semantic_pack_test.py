"""Offline tests for the transport portion of the browser semantic pack."""
import hashlib
import importlib.util
import io
from pathlib import Path
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import warnings
import zipfile


module_path = Path(__file__).resolve().parents[1] / "scripts/browser_semantic_pack.py"
repository = module_path.parents[1]
module_spec = importlib.util.spec_from_file_location("browser_semantic_pack", module_path)
pack = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(pack)


def blob_id(data):
    sha = hashlib.sha1(f"blob {len(data)}\0".encode("ascii"), usedforsecurity=False)
    sha.update(data)
    return sha.hexdigest()


class SemanticPackTests(unittest.TestCase):
    def test_transport_is_sorted_reproducible_and_has_no_host_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first, second = root / "first/a.tar.gz", root / "second/b.tar.gz"
            for file in first, second:
                file.parent.mkdir()
            payloads = {"share/titan/LICENSE": b"authoritative text\n", "manifest.json": b"{}\n"}
            pack.write_pack(first, payloads)
            pack.write_pack(second, dict(reversed(list(payloads.items()))))
            data = first.read_bytes()
            self.assertEqual(data, second.read_bytes())
            self.assertEqual(data[:10], b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff")
            with tarfile.open(first, "r:gz") as archive:
                self.assertEqual(archive.getnames(), sorted(payloads))
                for member in archive:
                    self.assertTrue(member.isreg())
                    self.assertEqual(member.mode, 0o644)
                    self.assertEqual((member.uid, member.gid, member.mtime), (0, 0, 0))
                    self.assertEqual((member.uname, member.gname), ("", ""))
                    self.assertEqual(archive.extractfile(member).read(), payloads[member.name])

    def test_source_rock_rejects_wrong_missing_and_duplicate_entries(self):
        rockspec = "titan-0.6.0-1.rockspec"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contents = {rockspec: b"rock metadata", "dependency/source.c": b"pinned object"}
            entries = {name: blob_id(data) for name, data in contents.items()}
            for name, data in contents.items():
                filename = root / name
                filename.parent.mkdir(parents=True, exist_ok=True)
                filename.write_bytes(data)
            pins = {"dependency": "unused-commit"}
            files = [(rockspec, contents[rockspec]), (f"titan/{rockspec}", contents[rockspec]),
                     ("titan/dependency/source.c", contents["dependency/source.c"])]

            def verify(records):
                rock = io.BytesIO()
                with warnings.catch_warnings(), zipfile.ZipFile(rock, "w") as archive:
                    warnings.filterwarnings("ignore", message="Duplicate name:")
                    for name, data in records:
                        archive.writestr(name, data)
                pack.verify_rock(rock, root, entries, pins, rockspec)

            verify(files)
            with self.assertRaisesRegex(ValueError, "disagrees with the producer source"):
                verify(files[:-1] + [(files[-1][0], b"different source")])
            with self.assertRaisesRegex(ValueError, "missing titan/dependency/source.c"):
                verify(files[:-1])
            with self.assertRaisesRegex(ValueError, "duplicate member"):
                verify(files + files[-1:])
            with self.assertRaisesRegex(ValueError, "disagrees with the pinned Git tree"):
                entries["dependency/source.c"] = blob_id(b"different pin")
                verify(files)


@unittest.skipUnless(os.getenv("TITAN_PACK_TEST_PREFIX"), "requires a finished browser SDK")
class FullSDKPackTests(unittest.TestCase):
    def setUp(self):
        root = tempfile.TemporaryDirectory(prefix="titan-pack-")
        self.addCleanup(root.cleanup)
        self.root = Path(root.name)
        installed = Path(os.environ["TITAN_PACK_TEST_PREFIX"]).resolve()
        self.lua = installed / "bin/lua"
        self.prefix = self.root / "private SDK"
        self.relative = Path("lib/titan-browser/0.6")
        self.assets = self.prefix / self.relative
        self.assets.mkdir(parents=True)
        for leaf in (*pack.SEMANTIC_FILES, "build-profile"):
            shutil.copyfile(installed / self.relative / leaf, self.assets / leaf)
        for directory in ("share/lua/5.5", "lib/lua/5.5", "share/titan"):
            shutil.copytree(installed / directory, self.prefix / directory)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith(("EM", "TITAN_", "LUA_"))}
        self.profile = (self.assets / "build-profile").read_text().strip()
        self.run_lua("""
local incremental = require "titan-compiler.incremental"
local io = require("titan-compiler.io").new_sync()
local digest = { io = io, cache_adapter = { sha256_binary = require("titan")._sha256_binary } }
local installed, copied = ...
assert(incremental.load_sdk_digests(digest, installed .. "/sdk-digests"))
local rows = assert(digest.incremental.sdk).files
local files = {}
for index, leaf in ipairs({ "absent-modules", "analysis-target", "titan.a" }) do
    local source = assert(io:realpath(installed .. "/" .. leaf))
    local destination = copied .. "/" .. leaf
    assert(assert(rows[source]).digest == incremental.file_digest(digest, destination))
    files[index] = destination
end
assert(incremental.write_sdk_digests(digest, copied .. "/sdk-digests", files))
""", installed / self.relative, self.assets)
        self.commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository,
                                              env=self.env, text=True).strip()
        self.rock = self.root / "titan-0.6.0-1.src.rock"
        rockspec = self.rock.name.removesuffix(".src.rock") + ".rockspec"
        with zipfile.ZipFile(self.rock, "w", zipfile.ZIP_DEFLATED) as rock:
            rock.write(repository / rockspec, rockspec)
            self.archive_git(rock, repository, self.commit, "titan")

    def archive_git(self, zip_archive, tree, commit, prefix):
        git = ["git", "-C", str(tree)]
        data = subprocess.check_output([*git, "archive", commit], env=self.env)
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as source:
            for member in source:
                if member.isreg():
                    zip_archive.writestr(f"{prefix}/{member.name}", source.extractfile(member).read())
        listing = subprocess.check_output([*git, "ls-tree", "-rz", commit], env=self.env)
        for record in listing.split(b"\0"):
            if record.startswith(b"160000 "):
                info, name = record.decode().split("\t", 1)
                self.archive_git(zip_archive, tree / name, info.split()[-1], f"{prefix}/{name}")

    def run_lua(self, script, *args):
        package = self.prefix / "share/lua/5.5"
        native = self.prefix / "lib/lua/5.5"
        setup = f'package.path = "{package}/?.lua;{package}/?/init.lua"; package.cpath = "{native}/?.so"\n'
        subprocess.run([str(self.lua), "-E", "-", *map(str, args)], input=setup + script,
                       cwd=repository, env=self.env, text=True, check=True)

    def make_pack(self, output, **overrides):
        values = {
            "PREFIX": self.prefix, "ROCKS_TREE": self.prefix, "TITAN_LUA": self.lua,
            "SOURCE_ROCK": self.rock, "TITAN_COMMIT": self.commit, "PACK_OUTPUT": output,
            "TITAN_BUILD_PROFILE": self.profile,
        }
        values.update(overrides)
        poisoned = {**self.env, "GIT_DIR": str(self.root / "wrong git directory"),
                    "GIT_WORK_TREE": str(self.root / "wrong worktree"), "LUA_PATH": "/invalid/?.lua",
                    "LUA_INIT": "error('unexpected startup')", "TITAN_TARGET": "invalid",
                    "TITAN_PATH": str(self.root / "wrong provider"), "TITAN_ROOT": "/invalid"}
        return subprocess.run(["make", "--no-print-directory", "browser-semantic-pack",
                               *(f"{key}={value}" for key, value in values.items())],
                              cwd=repository, env=poisoned, capture_output=True, text=True)

    def output(self, directory):
        destination = self.root / directory
        destination.mkdir(exist_ok=True)
        return destination / "titan-0.6.0-1-browser-semantics.tar.gz"

    def test_full_provider_reproducibility_and_relocation(self):
        first, second = self.output("one"), self.output("two")
        for output in first, second:
            result = self.make_pack(output)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        semantic = [str(self.relative / name) for name in pack.SEMANTIC_FILES]
        expected = sorted(semantic + [f"share/titan/{name}" for name in pack.NOTICES])
        relocated = self.root / "relocated"
        with tarfile.open(first, "r:gz") as archive:
            self.assertEqual(sorted(expected + ["manifest.json"]), archive.getnames())
            raw = archive.extractfile("manifest.json").read()
            manifest = json.loads(raw)
            self.assertEqual((json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode(), raw)
            self.assertEqual(self.commit, manifest["titan_commit"])
            self.assertEqual(self.profile, manifest["build_profile"])
            self.assertEqual({"name": self.rock.name, "sha256": hashlib.sha256(self.rock.read_bytes()).hexdigest()},
                             manifest["source_rock"])
            self.assertEqual(expected, [row["path"] for row in manifest["files"]])
            self.assertEqual(semantic, [row["path"] for row in manifest["sdk_digests"]])
            for row in manifest["files"]:
                member = archive.getmember(row["path"])
                data = archive.extractfile(member).read()
                self.assertTrue(member.isreg())
                self.assertEqual((len(data), hashlib.sha256(data).hexdigest()), (row["size"], row["sha256"]))
                self.assertEqual(data, (self.prefix / row["path"]).read_bytes())
                if row["path"] in semantic:
                    target = relocated / row["path"]
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
        self.run_lua("""
local path = ...
local driver = require "titan-compiler.driver"
local io = setmetatable({
    run = function() error("a semantic input unexpectedly started a process") end,
}, { __index = require("titan-compiler.io").new_sync() })
local target = assert(driver.browser_analysis_target(path, { io = io }))
local context = driver.new_resolver_context({
    io = io, target = "browser", analysis_only = true, browser_analysis_target = target,
})
local json, provider, _, inventory = driver.find_static_interface("", "titan.json", context)
assert(json and provider == target.provider_file and #inventory.key_order == 21)
assert(driver.language_server_cache_identity({ context = context }))
assert(driver.close_resolver_context(context))
""", relocated)

    def test_producer_rejects_invalid_pairs_without_output(self):
        output = self.output("negative")
        further = self.root / "other prefix"
        further.mkdir()

        def reject(reason, destination=output, **overrides):
            result = self.make_pack(destination, **overrides)
            self.assertNotEqual(0, result.returncode, result.stdout)
            self.assertIn(reason, result.stderr)
            self.assertFalse(destination.exists())

        reject("SOURCE_ROCK is required", SOURCE_ROCK="")
        reject("same PREFIX and ROCKS_TREE", ROCKS_TREE=further)
        reject("PACK_OUTPUT must be outside", self.prefix / output.name)
        reject("build profile does not match", TITAN_BUILD_PROFILE=(
            "validation" if self.profile == "production" else "production"))
        for file, reason, new in (
            (self.assets / "titan.a", "titan.a: missing file", None),
            (self.assets / "titan.a", "titan.a: digest disagrees", b"!<arch>\n"),
            (self.prefix / "share/titan/LICENSES/lua-LICENSE", "notice disagrees", b"changed notice"),
            (self.prefix / "share/lua/5.5/titan-compiler/version.lua", "compiler source disagrees", b"return {}"),
            (self.rock, "not a zip file", b"wrong source rock"),
        ):
            with self.subTest(reason=reason):
                real = file.read_bytes()
                try:
                    if new is None:
                        file.unlink()
                    else:
                        file.write_bytes(new)
                    reject(reason)
                finally:
                    file.write_bytes(real)

        manifest = self.assets / "sdk-digests"
        original = manifest.read_bytes()
        try:
            self.run_lua("""
local manifest, absent = ...
local io = require("titan-compiler.io").new_sync()
local codec = require "titan-compiler.graphcodec"
local record = assert(codec.decode(assert(io:read_file(manifest))))
record.files[assert(io:realpath(absent))] = nil
assert(io:write_file(manifest, assert(codec.encode(record))))
""", manifest, self.assets / "absent-modules")
            reject("sdk-digests: missing record for absent-modules")
        finally:
            manifest.write_bytes(original)

        target, provider = self.assets / "analysis-target", self.assets / "titan.a"
        original_target = target.read_bytes()
        self.run_lua("""
local pathname = ...
local io = require("titan-compiler.io").new_sync()
local codec = require "titan-compiler.graphcodec"
local record = assert(codec.decode(assert(io:read_file(pathname))))
record.lua.fork_revision = string.rep("a", 40)
assert(io:write_file(pathname, assert(codec.encode(record))))
""", target)
        reject("Lua fork does not match")
        target.write_bytes(original_target)
        obj = self.root / "browser.o"
        obj.write_bytes(subprocess.check_output(["ar", "p", str(provider), "browser.o"], env=self.env))
        provider.unlink()
        subprocess.run(["ar", "qc", str(provider), str(obj)], check=True, env=self.env)
        self.run_lua("""
local target, provider = ...
local io = require("titan-compiler.io").new_sync()
local codec = require "titan-compiler.graphcodec"
local record = assert(codec.decode(assert(io:read_file(target))))
record.provider_sha256 = require("titan-compiler.sha256").hex_via(
    require("titan")._sha256_binary, assert(io:read_file(provider)))
assert(io:write_file(target, assert(codec.encode(record))))
""", target, provider)
        reject("expected the full browser standard provider inventory")


if __name__ == "__main__":
    unittest.main()

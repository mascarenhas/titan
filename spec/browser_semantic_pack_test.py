"""Offline tests for the transport portion of the browser semantic pack."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import warnings
import zipfile


module_path = Path(__file__).resolve().parents[1] / "scripts/browser_semantic_pack.py"
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


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Extract a pinned archive and restore the modes it recorded.

Python's ``zipfile`` writes members with the process umask and drops the ZIP
Unix mode, so a plain ``extractall`` leaves Chrome for Testing's executable
non-executable. This helper restores each member's recorded mode (the shell
binary is the one that matters) and refuses entries that escape the target.
"""
import os
import sys
import zipfile


def main(argv):
    if len(argv) != 3:
        print("usage: browser_extract_zip.py ARCHIVE DESTINATION", file=sys.stderr)
        return 2
    archive, destination = argv[1], argv[2]
    root = os.path.realpath(destination)
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            path = os.path.realpath(os.path.join(root, member.filename))
            if path != root and not path.startswith(root + os.sep):
                print(f"archive member escapes destination: {member.filename}", file=sys.stderr)
                return 1
            package.extract(member, root)
            mode = (member.external_attr >> 16) & 0o777
            if member.is_dir():
                if mode:
                    os.chmod(path, mode)
            else:
                os.chmod(path, mode if mode else 0o644)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

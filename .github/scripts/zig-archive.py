#!/usr/bin/env python3
"""install-zig's steps that must work alike on every runner:

- `fields MANIFEST`: print the manifest's version, url and sha256, a line each.
- `check ARCHIVE SHA256`: fail unless the archive's SHA-256 is that one.
- `unzip ARCHIVE DESTINATION`: unpack a zip into DESTINATION without its
  top directory, as `tar --strip-components=1` does a tarball.
"""
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import zipfile


def fields(manifest):
    with open(manifest, encoding="utf-8") as source:
        description = json.load(source)
    for key in ("version", "url", "sha256"):
        if key not in description:
            raise SystemExit(f"Zig manifest is missing {key!r}")
        print(description[key])


def check(archive, expected):
    digest = hashlib.sha256()
    with open(archive, "rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != expected:
        raise SystemExit(f"Zig archive's SHA-256 is {digest.hexdigest()}, not the manifest's {expected}")


def unzip(archive, destination):
    destination = Path(destination)
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            # A name is read as Windows reads it, where `\\` separates too
            # and a drive roots it, so no name leaves the directory there.
            name = member.filename.replace("\\", "/")
            parts = PurePosixPath(name).parts[1:]
            if not parts:
                continue
            if ".." in parts or PurePosixPath(name).is_absolute() or any(":" in part for part in parts):
                raise SystemExit(f"Zig archive names {member.filename!r}, outside its directory")
            target = destination.joinpath(*parts)
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read(member))


if __name__ == "__main__":
    command, *arguments = sys.argv[1:]
    {"fields": fields, "check": check, "unzip": unzip}[command](*arguments)

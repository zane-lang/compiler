#!/usr/bin/env python3
"""Refresh non-Dependabot tool pins; changes are proposed in a pull request."""
import json
import os
from pathlib import Path
import re
from urllib.request import Request, urlopen


def fetch(url):
    """Read upstream JSON, authenticating only requests to the GitHub API."""
    headers = {"User-Agent": "zane-toolchain-updater"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if url.startswith("https://api.github.com/") and token:
        headers["Authorization"] = "Bearer " + token
    with urlopen(Request(url, headers=headers), timeout=60) as response:
        return json.load(response)


def stable_latest(versions):
    """Select the newest numeric release and ignore prerelease names."""
    return max((v for v in versions if re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", v)),
               key=lambda v: tuple(map(int, v.split("."))))


def main():
    """Refresh stable release pins for the scheduled update pull request."""
    root = Path(__file__).resolve().parents[2]
    bootstrap = root / "dev/setup/bootstrap-toolchain"
    content = bootstrap.read_text()
    def releases(name):
        packages = fetch(f"https://api.github.com/repos/ocaml/opam-repository/contents/packages/{name}")
        return [p["name"].removeprefix(name + ".") for p in packages]

    versions = {name: stable_latest(releases(name)) for name in ("dune", "menhir", "sedlex", "uuseg")}
    # uuseg requires the uucp of its own Unicode version, the same major.
    major = versions["uuseg"].split(".")[0]
    versions["uucp"] = stable_latest(v for v in releases("uucp") if v.split(".")[0] == major)
    for name, version in versions.items():
        content = re.sub(rf'{name.upper()}_VERSION="[^"\n]+"',
                         f'{name.upper()}_VERSION="{version}"', content)
    bootstrap.write_text(content)
    lean = fetch("https://api.github.com/repos/leanprover/lean4/releases/latest")["tag_name"]
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", lean):
        raise ValueError("Unexpected Lean release tag")
    (root / "formal/lean-toolchain").write_text(f"leanprover/lean4:{lean}\n")
    index = fetch("https://ziglang.org/download/index.json")
    version = stable_latest(index)
    source = index[version]["x86_64-linux"]
    if not re.fullmatch(r"[0-9a-f]{64}", source["shasum"]):
        raise ValueError("Invalid Zig checksum")
    if source["tarball"] != f"https://ziglang.org/download/{version}/zig-x86_64-linux-{version}.tar.xz":
        raise ValueError("Unexpected Zig distribution URL")
    data = {"version": version, "url": source["tarball"], "sha256": source["shasum"]}
    (root / "dev/toolchains/zig.json").write_text(json.dumps(data, indent=2) + "\n")


if __name__ == "__main__":
    main()

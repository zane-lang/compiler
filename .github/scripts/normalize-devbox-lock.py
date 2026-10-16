#!/usr/bin/env python3
"""Keep local-flake lock references portable between checkout directories."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
lock = root / "devbox.lock"
data = json.loads(lock.read_text())
for name, package in data["packages"].items():
    if name.startswith("path:"):
        package["resolved"] = name
        package.pop("last_modified", None)
lock.write_text(json.dumps(data, indent=2) + "\n")

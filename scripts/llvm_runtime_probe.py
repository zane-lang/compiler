#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys


def find_libllvm(libdir_arg: str) -> int:
	libdir = pathlib.Path(libdir_arg)
	preferred = libdir / "libLLVM.so"
	if preferred.exists() and (preferred.is_file() or preferred.is_symlink()):
		print(preferred)
		return 0

	for path in sorted(libdir.iterdir()):
		name = path.name
		if not re.fullmatch(r"^libLLVM\.so(?:\.\d+)*$", name):
			continue
		if path.exists() and (path.is_file() or path.is_symlink()):
			print(path)
			return 0

	raise SystemExit(
		f"libLLVM shared library matching libLLVM.so or libLLVM.so.* not found in {libdir}"
	)


def find_libffi(llvm_shared_arg: str) -> int:
	if shutil.which("ldd") is None:
		raise SystemExit(
			"Build error: ldd utility is required to locate libffi for LLVM runtime linking. "
			"Please ensure your system runtime tools are installed."
		)

	try:
		output = subprocess.run(
			["ldd", llvm_shared_arg],
			capture_output=True,
			text=True,
			check=True,
		).stdout
	except subprocess.CalledProcessError as exc:
		details = exc.stderr.strip() or exc.stdout.strip() or str(exc)
		raise SystemExit(f"failed to inspect LLVM shared library dependencies: {details}") from exc

	for line in output.splitlines():
		if "libffi.so" not in line:
			continue

		if "=>" in line:
			candidate_part = line.split("=>", 1)[1].strip()
			if candidate_part != "not found":
				match = re.match(r"(/[^()]+)", candidate_part)
				if match:
					candidate = match.group(1).strip()
					if candidate.startswith("/"):
						print(candidate)
						return 0
		else:
			match = re.search(r"(/[^\s]+libffi\.so[^\s]*)", line)
			if match:
				candidate = match.group(1)
				if candidate.startswith("/"):
					print(candidate)
					return 0

	raise SystemExit(f"libffi shared library not found in LLVM dependencies of {llvm_shared_arg}")


def parent_dir(path_arg: str) -> int:
	if path_arg == "":
		print("")
		return 0

	parent = pathlib.Path(path_arg).parent
	if parent.is_dir():
		print(parent)
	else:
		print("")
	return 0


def main() -> int:
	if len(sys.argv) != 3:
		raise SystemExit("usage: llvm_runtime_probe.py <find-libllvm|find-libffi|parent-dir> <path>")

	command, path_arg = sys.argv[1], sys.argv[2]
	if command == "find-libllvm":
		return find_libllvm(path_arg)
	if command == "find-libffi":
		return find_libffi(path_arg)
	if command == "parent-dir":
		return parent_dir(path_arg)

	raise SystemExit(f"unknown command: {command}")


if __name__ == "__main__":
	raise SystemExit(main())

@echo off
rem `zig cc` as one command, for `ZANE_CC` on Windows, where the compiler
rem runs it through cmd.exe and so cannot run the `zig-cc` shell script
rem beside it. `ZIG` names the `zig` to use, when it is not the one on the
rem path.
if defined ZIG ("%ZIG%" cc %*) else (zig cc %*)

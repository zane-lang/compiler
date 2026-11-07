@echo off
rem `zig cc` as one command, for `ZANE_CC` on Windows, where the compiler
rem runs it through cmd.exe and so cannot run the `zig-cc` shell script
rem beside it itself: this runs it with the environment's `sh`, which leaves
rem every argument as it is given. `ZIG` names the `zig` to use, when it is
rem not the one on the path.
setlocal
set "MSYS2_ARG_CONV_EXCL=*"
sh "%~dp0zig-cc" %*

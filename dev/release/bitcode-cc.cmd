@echo off
rem bitcode-cc for cmd.exe, which runs ZANE_BITCODE_CC on Windows and
rem cannot run a Python script alone.
python "%~dp0bitcode-cc" %*

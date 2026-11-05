@echo off
rem Run by pixi when it activates the environment on Windows (pixi.toml),
rem after each package's own activation: what the build reads besides the
rem tools on PATH (README.md, "Setup").

rem MSVC's compiler and linker, which OCaml's MSVC build compiles C and
rem links with, from the newest Visual Studio with its C++ tools when the
rem shell is not a developer prompt already.
where cl >nul 2>nul
if errorlevel 1 (
	for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
		call "%%i\VC\Auxiliary\Build\vcvars64.bat" >nul
	)
)

rem The project's opam root and switch, which `pixi run setup` makes.
rem conda's opam package points OPAMROOT at a root of its own, with a
rem switch named `conda` in it; the project keeps one inside the
rem environment's directory.
set "OPAMROOT=%PIXI_PROJECT_ROOT%\.pixi\opam"
set OPAMSWITCH=

rem The repository's own commands, and the C compiler `zanec` links with:
rem `zig cc` for MinGW, the only Windows target the runtime supports
rem (docs/design/platforms.md), through a wrapper cmd.exe can run. conda
rem names its zig for the triple it was built on.
set "PATH=%PIXI_PROJECT_ROOT%\dev\bin;%PATH%"
if not defined ZANE_CC set "ZANE_CC=%PIXI_PROJECT_ROOT%\dev\bin\zig-cc.cmd"
if not defined ZIG set "ZIG=%CONDA_PREFIX%\Library\bin\x86_64-w64-mingw32-zig.exe"

rem The LLVM the compiler's bindings and stubs build against
rem (lib/llvm/config/discover.ml), and its archive tools, which the tests'
rem archives are made with.
set "LLVM_CONFIG=%CONDA_PREFIX%\Library\bin\llvm-config.exe"
set AR=llvm-ar
set STRIP=llvm-strip

rem The switch's tools and libraries, once it has been made.
if exist "%PIXI_PROJECT_ROOT%\_opam" (
	for /f "usebackq delims=" %%i in (`opam env --switch^="%PIXI_PROJECT_ROOT%" --set-switch --shell^=cmd`) do %%i
)

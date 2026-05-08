project(
  'zane',
  'cpp',
  version: '1.0.0',
  default_options: [
    'cpp_std=c++23',
    'warning_level=2',
    'buildtype=release',
  ],
)

python = import('python').find_installation()
bison = find_program('bison', required: true)
re2c = find_program('re2c', required: true)

coda_inc = include_directories('vendor/coda/include')
coda_dep = declare_dependency(include_directories: coda_inc)

zanecpp_inc = include_directories('vendor/zane-cpp/include')
zanecpp_dep = declare_dependency(include_directories: zanecpp_inc)

nlohmann_dep = dependency('nlohmann_json', required: true, method: 'cmake')
cereal_dep  = dependency('cereal', required: true, method: 'cmake')

src_dir = include_directories('src')
grammar_dir = include_directories('grammar')

buildtype = get_option('buildtype')
is_debug = buildtype.startswith('debug')

exe_cpp_args = []
exe_link_args = []

if is_debug
  exe_cpp_args += ['-O1', '-g', '-fsanitize=address,undefined', '-fstack-protector-strong']
  exe_link_args += ['-fsanitize=address,undefined']
else
  exe_cpp_args += ['-O3', '-march=native', '-flto', '-fvisibility=hidden']
  exe_link_args += ['-flto', '-Wl,--strip-all', '-Wl,--gc-sections']
endif

# ---------------- LLVM (manual llvm-config integration) ----------------
llvm_modules = [
  'core',
  'orcjit',
  'executionengine',
  'support',
  'x86codegen',
  'x86asmparser',
  'x86desc',
  'x86disassembler',
  'x86info',
  'aarch64codegen',
  'aarch64asmparser',
  'aarch64desc',
  'aarch64disassembler',
  'aarch64info',
  'aarch64utils',
  'windowsdriver',
]

llvm_config = find_program('llvm-config-21', 'llvm-config', required: true)

llvm_cxxflags_s = run_command(llvm_config, '--cxxflags', check: true).stdout().strip()
llvm_ldflags_s  = run_command(llvm_config, '--ldflags',  check: true).stdout().strip()
llvm_libs_s     = run_command(llvm_config, ['--libs'] + llvm_modules, check: true).stdout().strip()
llvm_syslibs_s  = run_command(llvm_config, '--system-libs', check: true).stdout().strip()
llvm_libdir_s   = run_command(llvm_config, '--libdir', check: true).stdout().strip()
llvm_shared_s   = run_command(
  python,
  '-c',
  '''
import pathlib, sys

libdir = pathlib.Path(sys.argv[1])
preferred = libdir / 'libLLVM.so'
if preferred.exists() and (preferred.is_file() or preferred.is_symlink()):
    print(preferred)
    raise SystemExit(0)

candidates = sorted(libdir.glob('libLLVM.so*'))
for path in candidates:
    if path.exists() and (path.is_file() or path.is_symlink()):
        print(path)
        break
else:
    raise SystemExit('libLLVM shared library not found')
''',
  llvm_libdir_s,
  check: true,
).stdout().strip()
# Resolve libffi from LLVM's shared-library dependencies so the zane binary
# does not rely on LLVM's own RUNPATH entries at runtime.
llvm_libffi_s = run_command(
  python,
  '-c',
  '''
import re, shutil, subprocess, sys

if shutil.which('ldd') is None:
    raise SystemExit('Build error: ldd utility is required to locate libffi for LLVM runtime linking. Please ensure your system runtime tools are installed.')

try:
    output = subprocess.run(
        ['ldd', sys.argv[1]],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
except subprocess.CalledProcessError as exc:
    details = exc.stderr.strip() or exc.stdout.strip() or str(exc)
    raise SystemExit(f'failed to inspect LLVM shared library dependencies: {details}')

for line in output.splitlines():
    if 'libffi.so' not in line:
        continue
    candidate = ''
    if '=>' in line:
        candidate_part = line.split('=>', 1)[1].strip()
        if candidate_part != 'not found':
            match = re.match(r'(/[^()]+)', candidate_part)
            if match:
                candidate = match.group(1).strip()
    else:
        match = re.search(r'(/[^\s]+libffi\.so[^\s]*)', line)
        if match:
            candidate = match.group(1)
    if candidate.startswith('/'):
        print(candidate)
        break
else:
    raise SystemExit('libffi shared library not found in LLVM dependencies')
''',
  llvm_shared_s,
  check: true,
).stdout().strip()
llvm_libffi_dir_s = run_command(
  python,
  '-c',
  '''
import pathlib, sys

if sys.argv[1] != '':
    parent = pathlib.Path(sys.argv[1]).parent
    if parent.is_dir():
        print(parent)
''',
  llvm_libffi_s,
  check: true,
).stdout().strip()

llvm_cxxflags = llvm_cxxflags_s == '' ? [] : llvm_cxxflags_s.split()
llvm_ldflags  = llvm_ldflags_s  == '' ? [] : llvm_ldflags_s.split()
llvm_libs     = llvm_libs_s     == '' ? [] : llvm_libs_s.split()
llvm_syslibs  = llvm_syslibs_s  == '' ? [] : llvm_syslibs_s.split()

# Rewrite -I... include dirs to -idirafter ... to avoid shadowing libstdc++ headers
# (fixes conflicting <cxxabi.h> / __cxa_init_primary_exception)
llvm_incdirs = []
llvm_other_cargs = []
llvm_runtime_rpath = [llvm_libdir_s]
llvm_extra_link_args = []

if llvm_libffi_s != ''
  if llvm_libffi_dir_s != '' and not llvm_runtime_rpath.contains(llvm_libffi_dir_s)
    llvm_runtime_rpath += llvm_libffi_dir_s
  endif
  llvm_extra_link_args += ['-Wl,--no-as-needed', llvm_libffi_s, '-Wl,--as-needed']
endif

foreach a : llvm_cxxflags
  if a.startswith('-I')
    llvm_incdirs += a.substring(2)

  # prevent llvm-config from overriding project configuration / breaking deps
  elif a.startswith('-std=')
    # drop
  elif a == '-fno-exceptions'
    # drop
  elif a == '-fno-rtti'
    # drop

  else
    llvm_other_cargs += a
  endif
endforeach

llvm_fixed_cargs = llvm_other_cargs
foreach d : llvm_incdirs
  llvm_fixed_cargs += ['-idirafter', d]
endforeach

llvm_dep = declare_dependency(
  compile_args: llvm_fixed_cargs,
  link_args: llvm_ldflags + llvm_libs + llvm_syslibs + llvm_extra_link_args,
)
# ----------------------------------------------------------------------

embedded_data_header = custom_target(
  'embedded_data',
  output: 'embedded_data.hpp',
  command: [python, files('scripts/embed_data.py')],
  depend_files: [
    files('data/types.csv'),
    files('data/builtins.csv'),
  ],
  build_by_default: true,
)

generated_parser = custom_target(
  'generated_parser',
  input: files('grammar/parser.y'),
  output: ['parser.cpp', 'parser.hpp'],
  command: [bison, '--defines=@OUTPUT1@', '--output=@OUTPUT0@', '@INPUT@'],
  build_by_default: true,
)

generated_lexer = custom_target(
  'generated_lexer',
  input: files('grammar/lexer.re'),
  output: 'lexer.cpp',
  command: [re2c, '--output', '@OUTPUT@', '@INPUT@'],
  build_by_default: true,
)

sources = run_command(
  'find', 'src', '-name', '*.cpp', check: true
).stdout().strip().split('\n')

zane_exe = executable(
  meson.project_name(),
  sources + [embedded_data_header, generated_parser, generated_lexer],
  include_directories: [src_dir, grammar_dir],
  dependencies: [nlohmann_dep, cereal_dep, llvm_dep, coda_dep, zanecpp_dep],
  build_by_default: true,
  cpp_args: exe_cpp_args,
  link_args: exe_link_args,
  build_rpath: ':'.join(llvm_runtime_rpath),
)

upx = find_program('upx', required: false)
if upx.found() and buildtype == 'release'
  upx_target = custom_target(
    'upx_pack',
    output: 'upx_pack.stamp',
    command: [python, files('scripts/upx_pack.py'), upx, zane_exe.full_path(), '@OUTPUT@'],
    depends: zane_exe,
    build_by_default: true,
  )
endif

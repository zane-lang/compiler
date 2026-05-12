project(
  'helios',
  'cpp',
  version: '0.1.0',
  default_options: ['cpp_std=c++23']
)

llvm_modules = [
  'core', 'orcjit', 'executionengine', 'support',
  'x86codegen', 'x86asmparser', 'x86desc', 'x86disassembler', 'x86info',
  'aarch64codegen', 'aarch64asmparser', 'aarch64desc', 'aarch64disassembler', 'aarch64info', 'aarch64utils'
]

llvm_config = find_program('llvm-config-21', 'llvm-config', required: true)

llvm_cxxflags_s = run_command(llvm_config, '--cxxflags', check: true).stdout().strip()
llvm_ldflags_s  = run_command(llvm_config, '--ldflags',  check: true).stdout().strip()
llvm_libs_s     = run_command(llvm_config, ['--libs'] + llvm_modules, check: true).stdout().strip()
llvm_syslibs_s  = run_command(llvm_config, '--system-libs', check: true).stdout().strip()

llvm_cxxflags = llvm_cxxflags_s == '' ? [] : llvm_cxxflags_s.split()
llvm_ldflags  = llvm_ldflags_s  == '' ? [] : llvm_ldflags_s.split()
llvm_libs     = llvm_libs_s     == '' ? [] : llvm_libs_s.split()
llvm_syslibs  = llvm_syslibs_s  == '' ? [] : llvm_syslibs_s.split()

llvm_incdirs = []
llvm_other_cargs = []

foreach a : llvm_cxxflags
  if a.startswith('-I')
    llvm_incdirs += a.substring(2)
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
  link_args: llvm_ldflags + llvm_libs + llvm_syslibs,
)

helios_sources = files(
  'src/main.cpp', 
)

helios_inc = include_directories('include')

# Create a dummy executable to generate compile_commands.json
# This binary isn't intended to be run, just to satisfy LSP and build config
exe = executable(
  'helios_dummy',
  helios_sources,
  include_directories: [helios_inc],
  dependencies: [llvm_dep],
  install: false,
  build_by_default: false # Don't build this unless explicitly asked
)

project('zane', 'cpp',
  version: '0.1.0',
  default_options: ['cpp_std=c++20', 'warning_level=3'])

re2c = find_program('re2c', required: true)
elkhound = find_program('elkhound', required: true)

elkhound_runtime = dependency('elkhound_runtime', method: 'cmake', required: true)

parser_gen = custom_target('parser',
  input: 'src/grammar/parser.gr',
  output: ['zane_parser.cc', 'zane_parser.h'],
  command: [elkhound, '-o', '@OUTDIR@/zane_parser', '@INPUT@'],
  build_by_default: true,
)

lexer_gen = custom_target('lexer',
  input: 'src/grammar/lexer.re',
  output: 'lexer.cc',
  command: [re2c, '-o', '@OUTPUT@', '@INPUT@'],
  build_by_default: true,
)

executable('zane',
  'src/main.cpp',
  parser_gen[0], # parser.cc
  lexer_gen,     # lexer.cc
  include_directories: include_directories('src'),
  dependencies: [elkhound_runtime],
)

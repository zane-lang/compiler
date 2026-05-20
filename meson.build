project('zane', 'cpp',
  version: '0.1.0',
  default_options: ['cpp_std=c++20', 'warning_level=3'])

re2c = find_program('re2c', required: true)
bison = find_program('bison', required: true)

parser_gen = custom_target('parser',
  input: 'src/grammar/parser.y',
  output: ['parser.cc', 'parser.tab.h'],
  command: [bison, '-d', '-o', '@OUTPUT0@', '--defines=@OUTPUT1@', '@INPUT@'],
  build_by_default: true,
)

lexer_gen = custom_target('lexer',
  input: 'src/grammar/lexer.re',
  output: 'lexer.cc',
  command: [re2c, '-o', '@OUTPUT@', '@INPUT@'],
  build_by_default: true,
  depends: [parser_gen],
)

executable('zane',
  'src/main.cpp',
  parser_gen[0],
  lexer_gen,
  include_directories: include_directories('src', '.'),
  cpp_args: ['-Wall', '-Wextra'],
)

#!/usr/bin/env python3
# From binarytrees' LLVM IR (zanec --ll, with the switches the README
# names): make.ll, `make` alone as @zmake for rh.c, and global.ll, the whole
# program with `make` reaching its pool through a global, the handle copied
# in before each call and back after.
#
#   python3 rewrite.py zane.ll
import re, sys
s = open(sys.argv[1]).read()
name = '@"binarytrees$make(core$Int)"'
i = s.index(f'define internal fastcc i64 {name}')
j = s.index('\n}\n', i)
f = s[i:j + 3].replace(f'define internal fastcc i64 {name}', 'define i64 @zmake')
f = f.replace(f'tail call fastcc i64 {name}', 'tail call i64 @zmake')
open('make.ll', 'w').write(re.sub(r'\) unnamed_addr #\d+ \{', ') {', f))

head, rest = s[i:j].split('\n', 1)
rest = re.sub(r'ptr (nonnull )?%1\b', r'ptr \1@zp', rest)
g = s[:i] + head + '\n' + rest + s[j:]
call = r'^(\s+)%[\w.]+ = call fastcc i64 @"binarytrees\$make\(core\$Int\)"\(i64 [%\w.]+, ptr nonnull (%[\w.]+)\)$'
copy = '{0}call void @llvm.memcpy.p0.p0.i64(ptr {1}, ptr {2}, i64 24, i1 false)'
g = re.sub(call, lambda m: '\n'.join([copy.format(m[1], '@zp', m[2]), m[0], copy.format(m[1], m[2], '@zp')]), g, flags=re.M)
g += '\n@zp = internal global [3 x i64] zeroinitializer, align 16\n'
if 'declare void @llvm.memcpy.p0.p0.i64' not in g:
    g += 'declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\n'
open('global.ll', 'w').write(g)

#!/usr/bin/env python3
"""gen.py KERNELS DIR: a large program of KERNELS distinct kernels, each run from main."""
import sys, os, random
k, out = int(sys.argv[1]), sys.argv[2]
random.seed(7)
A = "@operators$add"; M = "@operators$multiply"; N = "@operators$negate"; D = "@operators$divide"; L = "@operators$lessThan"
head = '''/// A generated program of many distinct kernels, which says it started first.
package {pkg};

alias Int = @primitives$I64
alias Float = @primitives$F64
alias Bool = @primitives$Bool
alias Unit = @primitives$Unit
alias String = @primitives$String
alias List<T Type> = @primitives$List<T>

Unit to(this Int, end Int, body @concepts$Block) mut {
	@controlflow$repeat(@operators$add(@operators$add(end, @operators$negate(this)), Int(1)), {
		@controlflow$branch(true, body);
		this = @operators$add(this, Int(1));
	});
	return Unit();
}

Int size(fallback Int) {
	args List<String> = @program$runtime:arguments();
	@controlflow$branch(@operators$lessThan(args:size(), Int(1)), {
		return fallback;
	});
	return args[Int(1)]:parseI64() ?? fallback;
}

Unit say(text String) {
	@program$console!print(@operators$concat(text, String("\\n")));
	return Unit();
}

Int mask(v Int) => @math$bitAnd(v, Int(1048575))
Float real(v Int) => @primitives$F64.round(v)
Int whole(v Float) => @primitives$I64.truncate(v)

type Acc = struct {
	a Int;
	b Int;
}

Acc(a Int, b Int) => init{ a; b; }
'''
def ints(i):
    a, b, c = random.randint(3, 97), random.randint(1, 999), random.randint(2, 9)
    return f'''
/// Kernel {i}: integer mixing.
Int k{i}(n Int, seed Int) {{
	acc Int = seed;
	x Int(1);
	x!to(n) {{
		acc = mask({A}({M}(acc, Int({a})), {A}(x, Int({b}))));
		@controlflow$branch({L}(@math$bitAnd(acc, Int(7)), Int({c % 8})), {{
			acc = mask({A}(acc, {D}(acc, Int({c}))));
		}});
	}}
	return acc;
}}
'''
def floats(i):
    a, b = random.uniform(0.1, 0.9), random.uniform(1.0, 3.0)
    return f'''
/// Kernel {i}: a float recurrence.
Int k{i}(n Int, seed Int) {{
	z Float = {M}(real(mask(seed)), Float(0.000001));
	s Float(0.0);
	x Int(1);
	x!to(n) {{
		z = {A}({M}({M}(Float({a:.4f}), z), {A}(Float(1.0), {N}(z))), Float(0.{i % 7 + 1}));
		s = {A}(s, {M}(z, Float({b:.4f})));
	}}
	return mask({A}(whole(s), seed));
}}
'''
def lists(i):
    a = random.randint(2, 50)
    return f'''
/// Kernel {i}: a list built, then read back.
Int k{i}(n Int, seed Int) {{
	items List<Int> = @primitives$List(Int);
	x Int(1);
	x!to(Int(16)) {{
		items!push({A}({M}(x, Int({a})), seed));
	}}
	acc Int = seed;
	r Int(1);
	r!to(n) {{
		acc = mask({A}(acc, items[{A}(@math$bitAnd(r, Int(15)), Int(1))]));
	}}
	return acc;
}}
'''
def structs(i):
    a, b = random.randint(2, 40), random.randint(2, 40)
    return f'''
/// Kernel {i}: a pair of values stepped through a struct.
Acc step{i}(p Acc, x Int) => Acc(mask({A}({M}(p.a, Int({a})), x)), mask({A}(p.b, {M}(p.a, Int({b})))))

Int k{i}(n Int, seed Int) {{
	p Acc(seed, Int({i}));
	x Int(1);
	x!to(n) {{
		p = step{i}(p, x);
	}}
	return mask({A}(p.a, p.b));
}}
'''
kinds = [ints, floats, lists, structs]
body = [head.replace('{pkg}', os.path.basename(os.path.normpath(out)))]
for i in range(k):
    body.append(kinds[i % len(kinds)](i))
calls = "\n".join(f"\t\tacc = mask({A}(acc, k{i}(n, acc)));" for i in range(k))
body.append(f'''
Unit main() {{
	say(String("big: started"));
	n Int = size(Int(1000));
	acc Int(1);
	round Int(1);
	round!to(Int(20)) {{
{calls}
	}}
	say(String(acc));
	return Unit();
}}
''')
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "main.zn"), "w").write("".join(body))

(* Stage 5's C evaluator (docs/design/ffi.md F16, F19), checked against
   the same IR compiled and run: each function of [agreeing] is compiled by
   the linked clang, evaluated, and the bitcode linked into a program that
   prints what the target computes, and the two must agree. Then each of
   [stopping] must stop the evaluator rather than fold: undefined behavior,
   `volatile` and atomic accesses, a fast-math flag, a thread-local
   variable, an integer wider than 64 bits, an address's number, an
   address moved further than any allocation spans, a C function with no
   body, a zero-sized allocation, and a spent budget; and the sign-only result of `memcmp`.
   Then C reading the views F18 passes it, which fold, and comparing,
   subtracting or writing them, which stop; and a constructor that stops,
   which stops every call. *)

open Support
module Value = Optimize__Value
module C_ir = Optimize__C_ir
module C_memory = Optimize__C_memory
module C_eval = Optimize__C_eval
module C_cross = Optimize__C_cross

(* Each function takes two `long long` and returns one. *)
let agreeing =
  {|
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

typedef long long ll;

ll t_add(ll a, ll b) { return a + b; }
ll t_sub(ll a, ll b) { return a - b; }
ll t_mul(ll a, ll b) { return a * b; }
ll t_div(ll a, ll b) { return a / b + a % b * 1000; }
ll t_udiv(ll a, ll b) { return (ll)((unsigned long long)a / (unsigned long long)b) ^ (ll)((unsigned long long)a % (unsigned long long)b); }
ll t_shifts(ll a, ll b) { return (a << (b & 63)) ^ (a >> (b & 63)) ^ (ll)((unsigned long long)a >> (b & 63)); }
ll t_narrow(ll a, ll b) { int8_t x = (int8_t)a; uint16_t y = (uint16_t)b; int32_t z = (int32_t)(a * b); return x * 100000 + y + (ll)z * 7; }
ll t_unsigned_wrap(ll a, ll b) { unsigned int x = (unsigned int)a; x -= (unsigned int)b; x *= 2654435761u; return x; }
ll t_bits(ll a, ll b) { return (a & b) | ((a ^ b) << 3) | (~a & 0xff); }
ll t_compare(ll a, ll b) { return (a < b) + 2 * (a == b) + 4 * ((unsigned long long)a < (unsigned long long)b) + 8 * (a >= b); }
ll t_loop(ll a, ll b) { ll s = 0; for (ll i = 0; i < a; i++) s += i * b; return s; }
ll t_switch(ll a, ll b) {
  switch (a) { case 0: return b; case 1: return b * 2; case 5: return -b; case 100: return 42; default: return a + b; }
}
ll t_ternary(ll a, ll b) { return a > b ? a - b : b - a; }
ll t_while(ll a, ll b) { ll n = 0; while (a > 1) { a = a % 2 ? 3 * a + 1 : a / 2; n++; } return n + b; }
static ll fib(ll n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
ll t_recursion(ll a, ll b) { return fib(a) + b; }
static ll seeded;
__attribute__((constructor)) static void seed(void) { seeded = 41; }
ll t_constructor(ll a, ll b) { return seeded + a + b; }

ll t_double(ll a, ll b) { double x = (double)a / 3.0, y = (double)b * 0.1; double r = x * y + x / (y + 1.0) - x; ll bits; memcpy(&bits, &r, 8); return bits; }
ll t_float(ll a, ll b) { float x = (float)a / 7.0f, y = (float)b * 0.3f; float r = x * y - x / (y + 1.0f); int32_t bits; memcpy(&bits, &r, 4); return bits; }
ll t_float_convert(ll a, ll b) { float f = (float)(unsigned long long)a; double d = (double)(unsigned long long)b; int32_t fb; ll db; memcpy(&fb, &f, 4); memcpy(&db, &d, 8); return fb ^ db; }
ll t_float_to_int(ll a, ll b) { double d = (double)a * 1.5 + 0.25; float f = (float)d; return (ll)d + (int)f + (ll)(unsigned)(d > 0 ? d : -d) + b; }
ll t_float_compare(ll a, ll b) { double x = (double)a, y = (double)b / 2; return (x < y) + 2 * (x == y) + 4 * (x >= y) + 8 * (x != y); }
ll t_float_builtins(ll a, ll b) {
  double x = (double)a / 4.0;
  double r = __builtin_elementwise_floor(x) + __builtin_elementwise_ceil(x) * 3 + __builtin_elementwise_trunc(-x) * 5 + __builtin_elementwise_abs(-x) * 7
    + __builtin_elementwise_copysign(2.0, -x) + __builtin_elementwise_rint(x) * 11 + __builtin_elementwise_roundeven(x) * 13
    + __builtin_elementwise_round(x) * 17 + __builtin_elementwise_max(x, (double)b) * 19 + __builtin_elementwise_min(x, (double)b) * 23;
  ll bits; memcpy(&bits, &r, 8); return bits;
}
ll t_array(ll a, ll b) { ll xs[16]; for (int i = 0; i < 16; i++) xs[i] = i * a + b; ll s = 0; for (int i = 0; i < 16; i += 3) s += xs[i]; return s; }
struct point { int32_t x; int64_t y; char tag; };
static struct point make(ll a, ll b) { struct point p = { (int32_t)a, b, 'q' }; return p; }
ll t_struct(ll a, ll b) { struct point p = make(a, b); struct point q = p; q.x += 1; return q.x + q.y * 3 + q.tag; }
static const int16_t table[] = { 3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 };
ll t_table(ll a, ll b) { return table[a % 11] * 10 + table[b % 11]; }
static ll counter = 10;
ll t_global(ll a, ll b) { counter += a; counter *= b; return counter; }
ll t_memory(ll a, ll b) { char buf[32]; memset(buf, 'a', 32); buf[31] = 0; memcpy(buf + 4, "hello", 5); buf[(a & 15) + 10] = 0; return (ll)strlen(buf) * 100 + (strcmp(buf, "aaaahello") < 0) + 2 * (memcmp(buf, "aaaa", 4) == 0) + b; }
ll t_strings(ll a, ll b) { const char *s = "zane"; const char *p = memchr(s, 'n', 4); return (p - s) + (strncmp(s, "zany", 3) == 0) * 10 + b + a; }
struct node { ll v; struct node *next; };
ll t_heap(ll a, ll b) {
  struct node *list = 0;
  for (ll i = 0; i < a; i++) { struct node *n = malloc(sizeof *n); n->v = i * b; n->next = list; list = n; }
  ll s = 0;
  while (list) { struct node *n = list; s += n->v; list = n->next; free(n); }
  return s;
}
ll t_realloc(ll a, ll b) {
  ll *xs = calloc(4, sizeof(ll));
  for (int i = 0; i < 4; i++) xs[i] += i + b;
  xs = realloc(xs, 8 * sizeof(ll));
  for (int i = 4; i < 8; i++) xs[i] = i * a;
  ll s = 0; for (int i = 0; i < 8; i++) s += xs[i];
  free(xs); return s;
}
ll t_pointers(ll a, ll b) { ll xs[8] = {0}; ll *p = xs + 2, *q = xs + 6; *p = a; *q = b; return (q - p) * 1000 + (p < q) * 100 + *p + *q + (p == xs + 2); }
ll t_address_bits(ll a, ll b) { ll x[2]; uintptr_t u = (uintptr_t)&x[1], v = (uintptr_t)&x[0]; ll *back = (ll *)u; *back = a; x[0] = b; return (ll)(u - v) + x[1] * 3 + x[0]; }
static int cmp(const void *x, const void *y) { ll a = *(const ll *)x, b = *(const ll *)y; return (a > b) - (a < b); }
static void sort(ll *xs, int n, int (*f)(const void *, const void *)) {
  for (int i = 1; i < n; i++) for (int j = i; j > 0 && f(&xs[j - 1], &xs[j]) > 0; j--) { ll t = xs[j]; xs[j] = xs[j - 1]; xs[j - 1] = t; }
}
ll t_function_pointer(ll a, ll b) { ll xs[6] = { 5, a, 3, b, 9, 1 }; sort(xs, 6, cmp); return xs[0] + xs[1] * 10 + xs[2] * 100 + xs[5] * 1000; }
ll t_bit_builtins(ll a, ll b) {
  unsigned long long u = (unsigned long long)a | 1;
  return __builtin_popcountll(u) + __builtin_clzll(u) * 100 + __builtin_ctzll((unsigned long long)b | 256) * 10000 + (ll)(__builtin_bswap32((unsigned)a) & 0xffff) * 1000000;
}
ll t_rotate(ll a, ll b) { unsigned x = (unsigned)a; unsigned r = (x << (b & 31)) | (x >> ((32 - (b & 31)) & 31)); return r; }
ll t_overflow(ll a, ll b) { int r; int over = __builtin_add_overflow((int)a, (int)b, &r); unsigned long long m; int over2 = __builtin_mul_overflow((unsigned long long)a, (unsigned long long)b, &m); return over + 2 * over2 + (ll)r * 4; }
ll t_abs(ll a, ll b) { return llabs(a) + abs((int)b) * 3; }
ll t_bool(ll a, ll b) { _Bool x = a, y = b; return (x && !y) + 2 * (x || y) + 4 * (x == y); }
union pun { double d; uint64_t u; };
ll t_union(ll a, ll b) { union pun p; p.d = (double)a + 0.5; return (ll)(p.u >> 32) + b; }
ll t_vla(ll a, ll b) { int n = (int)(a & 7) + 1; ll xs[n]; for (int i = 0; i < n; i++) xs[i] = b + i; ll s = 0; for (int i = 0; i < n; i++) s += xs[i]; return s; }
|}

let cases =
  [
    ("t_add", [ (3L, 4L); (Int64.max_int, -1L); (-7L, 2L) ]);
    ("t_sub", [ (3L, 4L); (Int64.min_int, -1L) ]);
    ("t_mul", [ (123456789L, 987654321L); (-3L, 5L); (0x7fffffffL, 0x10001L) ]);
    ("t_div", [ (17L, 5L); (-17L, 5L); (17L, -5L) ]);
    ("t_udiv", [ (-1L, 7L); (100L, 3L) ]);
    ("t_shifts", [ (-12345L, 3L); (1L, 63L); (0x123456789L, 70L) ]);
    ("t_narrow", [ (200L, 70000L); (-129L, 65535L); (100000L, 100000L) ]);
    ("t_unsigned_wrap", [ (1L, 5L); (-1L, 0L) ]);
    ("t_bits", [ (0xf0f0L, 0x0ff0L); (-1L, 12345L) ]);
    ("t_compare", [ (1L, 2L); (-1L, 2L); (5L, 5L) ]);
    ("t_loop", [ (100L, 3L); (0L, 9L) ]);
    ("t_switch", [ (0L, 7L); (1L, 7L); (5L, 7L); (100L, 7L); (42L, 7L) ]);
    ("t_ternary", [ (3L, 10L); (10L, 3L) ]);
    ("t_while", [ (27L, 0L); (97L, 1L) ]);
    ("t_recursion", [ (15L, 1L) ]);
    ("t_constructor", [ (1L, 0L) ]);
    ("t_double", [ (10L, 3L); (-7L, 22L); (1L, -10L) ]);
    ("t_float", [ (10L, 3L); (-7L, 22L); (123456L, 789L) ]);
    ("t_float_convert", [ (-1L, -1L); (0x7fffff7fffffffffL, 0x20000000000001L); (16777217L, 9007199254740993L); (-0x7fffffffffffffffL, 3L) ]);
    ("t_float_to_int", [ (11L, 1L); (-11L, 2L); (1000000000L, 3L) ]);
    ("t_float_compare", [ (3L, 6L); (2L, 6L); (5L, 6L) ]);
    ("t_float_builtins", [ (7L, 2L); (-9L, 81L); (10L, 3L); (6L, 5L) ]);
    ("t_array", [ (3L, 4L) ]);
    ("t_struct", [ (5L, 6L) ]);
    ("t_table", [ (3L, 15L) ]);
    ("t_global", [ (5L, 3L) ]);
    ("t_memory", [ (0L, 1L); (7L, 2L); (15L, 3L) ]);
    ("t_strings", [ (1L, 2L) ]);
    ("t_heap", [ (10L, 3L); (0L, 3L) ]);
    ("t_realloc", [ (3L, 5L) ]);
    ("t_pointers", [ (4L, 9L) ]);
    ("t_address_bits", [ (4L, 9L) ]);
    ("t_function_pointer", [ (7L, -2L) ]);
    ("t_bit_builtins", [ (0x12345678L, 0L); (-1L, 1024L) ]);
    ("t_rotate", [ (0x80000001L, 1L); (0x12345678L, 0L); (0x12345678L, 13L) ]);
    ("t_overflow", [ (0x7fffffffL, 1L); (5L, 6L); (-1L, 2L) ]);
    ("t_abs", [ (-5L, -7L); (5L, 7L) ]);
    ("t_bool", [ (0L, 0L); (3L, 0L); (0L, 2L); (1L, 1L) ]);
    ("t_union", [ (3L, 1L); (-1000L, 0L) ]);
    ("t_vla", [ (5L, 10L); (0L, 1L) ]);
  ]

(* Each must stop the evaluator, by the message's start. *)
let stopping_source =
  {|
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

typedef long long ll;

ll s_uninitialized(ll a, ll b) { ll x; if (a) x = b; return x; }
ll s_signed_overflow(ll a, ll b) { return a + b; }
ll s_divide_by_zero(ll a, ll b) { return a / b; }
ll s_out_of_bounds(ll a, ll b) { ll xs[4] = {0}; return xs[a] + b; }
ll s_use_after_free(ll a, ll b) { ll *p = malloc(8); *p = a; free(p); return *p + b; }
ll s_misaligned(ll a, ll b) { ll xs[2] = { a, b }; int *p = (int *)((char *)xs + 1); return *p; }
ll s_unreachable(ll a, ll b) { if (a) __builtin_unreachable(); return b; }
ll s_volatile(ll a, ll b) { volatile ll x = a; return x + b; }
ll s_atomic(ll a, ll b) { ll x = a; return __atomic_load_n(&x, __ATOMIC_SEQ_CST) + b; }
ll s_address_number(ll a, ll b) { ll x = a; return (ll)(uintptr_t)&x + b; }
ll s_address_order(ll a, ll b) { ll x = a, y = b; return &x < &y; }
ll s_address_mask(ll a, ll b) { ll x = a; return ((uintptr_t)&x & 7) + b; }
ll s_address_truncated(ll a, ll b) { ll x = a; return (int)(uintptr_t)&x + b; }
ll s_no_body(ll a, ll b) { double r = sin((double)a); return (ll)r + b; }
ll s_zero_malloc(ll a, ll b) { void *p = malloc((size_t)a); free(p); return b; }
ll s_spin(ll a, ll b) { ll s = 0; while (a >= 0) s += b; return s; }
ll s_shift_too_far(ll a, ll b) { return a << b; }
ll s_store_string(ll a, ll b) { char *s = (char *)"abc"; s[0] = (char)a; return b; }
ll s_poison_branch(ll a, ll b) { int x = (int)a + 1; if (x > (int)a) return b; return 0; }
ll s_compare_literals(ll a, ll b) { const char *x = "same", *y = "other"; return (x == y) + a + b; }
ll s_one_past(ll a, ll b) { ll x = a, y = b; return &x + 1 == &y; }
ll s_fast(ll a, ll b) {
#pragma clang fp reassociate(on)
  double x = (double)a + (double)b + 1.0;
  return (ll)x;
}
static _Thread_local ll counted;
ll s_thread_local(ll a, ll b) { counted += a; return counted + b; }
ll s_index_wraps(ll a, ll b) { ll x = a; ll *p = &x; return (p + ((ll)1 << 61) == p) + b; }
ll s_address_far(ll a, ll b) { ll x = a; uintptr_t p = (uintptr_t)&x; return (p == p + ((uintptr_t)1 << 63)) + b; }
ll s_wide(ll a, ll b) { return (__uint128_t)(uint64_t)a + (uint64_t)b > (uint64_t)a; }
int s_memcmp(ll a, ll b) { char x[2] = { (char)a, 0 }, y[2] = { (char)b, 0 }; return memcmp(x, y, 2); }
|}

let stopping =
  [
    ("s_uninitialized", (0L, 1L), "a read of a byte never written");
    ("s_signed_overflow", (Int64.max_int, 1L), "poison");
    ("s_divide_by_zero", (1L, 0L), "a division by zero");
    ("s_out_of_bounds", (4L, 0L), "an access outside an allocation");
    ("s_use_after_free", (1L, 0L), "an access through a freed allocation");
    ("s_misaligned", (1L, 2L), "a misaligned access");
    ("s_unreachable", (1L, 0L), "unreachable code reached");
    ("s_volatile", (1L, 0L), "a volatile access");
    ("s_atomic", (1L, 0L), "an atomic access");
    ("s_address_number", (1L, 0L), "the numeric value of an address");
    ("s_address_order", (1L, 2L), "a comparison of addresses whose order");
    ("s_address_mask", (1L, 0L), "the numeric value of an address");
    ("s_address_truncated", (1L, 0L), "an address truncated");
    ("s_no_body", (1L, 0L), "a call to `sin`");
    ("s_zero_malloc", (0L, 1L), "an allocation of zero bytes");
    ("s_spin", (1L, 1L), "the step budget ran out");
    ("s_shift_too_far", (1L, 64L), "poison");
    ("s_store_string", (1L, 0L), "a store into memory C may not write");
    ("s_poison_branch", (0x7fffffffL, 1L), "poison");
    ("s_compare_literals", (1L, 1L), "a comparison of addresses whose storage may be shared");
    ("s_one_past", (1L, 1L), "a comparison of an address one past");
    ("s_index_wraps", (1L, 0L), "an instruction the evaluator does not model: getelementptr");
    ("s_address_far", (1L, 0L), "an address moved further than any allocation spans");
    ("s_wide", (-1L, 1L), "an integer wider than 64 bits");
    ("s_fast", (1L, 1L), "a float operation with a fast-math flag");
    ("s_thread_local", (1L, 1L), "a thread-local variable");
  ]

let compile base name source =
  let dir = Filename.concat base name in
  Sys.mkdir dir 0o755;
  write_all (Filename.concat dir "a.c") source;
  let cc = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC") in
  match Foreign.compile_packages ~cache:None ~cc ~cpu:"" ~target:None [ dir ] with
  | Ok [ { Foreign.sources = [ s ]; _ } ] -> Some s.Foreign.Compile.bitcode
  | _ -> None

(* [f] run on the module [bitcode] holds, in a context of its own. *)
let with_module bitcode f =
  let ctx = Llvm.create_context () in
  Fun.protect
    ~finally:(fun () -> Llvm.dispose_context ctx)
    (fun () ->
      let buffer = Llvm.MemoryBuffer.of_string bitcode in
      let m = Llvm_bitreader.parse_bitcode ctx buffer in
      Llvm.MemoryBuffer.dispose buffer;
      Fun.protect ~finally:(fun () -> Llvm.dispose_module m) (fun () -> f m))

let budget = 2_000_000

(* What evaluating [name] on [a] and [b] gives: its value, or why it
   stopped. *)
let evaluate_on m name args =
  let left = ref budget in
  let hooks =
    {
      C_eval.spend =
        (fun n ->
          left := !left - n;
          if !left <= 0 then Value.stop "the step budget ran out");
      declared = (fun _ _ -> None);
    }
  in
  match C_eval.call (C_eval.create (C_ir.make [ m ]) hooks) name (args ()) with
  | C_memory.Poison -> Error "poison returned"
  | C_memory.Addr _ -> Error "the numeric value of an address returned"
  | v -> Ok v
  | exception Value.Stop why -> Error why

let evaluate m name a b = evaluate_on m name (fun () -> [ C_memory.Int (64, a); C_memory.Int (64, b) ])

(* What the target prints for each case: the bitcode linked into a
   program calling each case. *)
let natively base bitcode =
  let bc = Filename.concat base "cases.bc" and harness = Filename.concat base "main.c" in
  let exe = Filename.concat base "cases" in
  write_all bc bitcode;
  let decls = String.concat "" (List.map (fun (n, _) -> Printf.sprintf "long long %s(long long, long long);\n" n) cases) in
  let calls =
    String.concat ""
      (List.concat_map
         (fun (n, args) -> List.map (fun (a, b) -> Printf.sprintf "  printf(\"%%lld\\n\", %s(%LdLL, %LdLL));\n" n a b) args)
         cases)
  in
  write_all harness (Printf.sprintf "#include <stdio.h>\n%sint main(void) {\n%s  return 0;\n}\n" decls calls);
  let cc = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC") in
  let out = Filename.concat base "out.txt" in
  if Sys.command (Printf.sprintf "%s -w %s %s -o %s -lm && %s > %s" cc (Filename.quote harness) (Filename.quote bc) (Filename.quote exe) (Filename.quote exe) (Filename.quote out)) <> 0
  then None
  else Option.map (String.split_on_char '\n') (read_all out)

let agree base =
  match compile base "agree" agreeing with
  | None -> check "the C evaluator's cases compile" false
  | Some bitcode -> (
      match natively base bitcode with
      | None -> check "the C evaluator's cases run natively" false
      | Some lines ->
          with_module bitcode (fun m ->
              let expected = ref lines in
              List.iter
                (fun (name, args) ->
                  List.iter
                    (fun (a, b) ->
                      let want = match !expected with x :: rest -> expected := rest; x | [] -> "" in
                      let got =
                        match evaluate m name a b with
                        | Ok (C_memory.Int (_, x)) -> Int64.to_string x
                        | Ok _ -> "not an integer"
                        | Error why -> "stopped: " ^ why
                      in
                      if got <> want then Printf.printf "  %s(%Ld, %Ld): evaluated %s, ran %s\n" name a b got want;
                      check (Printf.sprintf "C evaluated as it runs: %s(%Ld, %Ld)" name a b) (got = want))
                    args)
                cases))

let stop base =
  match compile base "stop" stopping_source with
  | None -> check "the C evaluator's stopping cases compile" false
  | Some bitcode ->
      with_module bitcode (fun m ->
          List.iter
            (fun (name, (a, b), why) ->
              match evaluate m name a b with
              | Error w when String.starts_with ~prefix:why w -> ()
              | r ->
                  Printf.printf "  %s: %s\n" name (match r with Ok _ -> "folded" | Error w -> "stopped: " ^ w);
                  check (Printf.sprintf "C evaluation stops at %s: %s" name why) false)
            stopping;
          check "memcmp's result is only its sign"
            (match evaluate m "s_memcmp" 1L 2L with Ok (C_memory.Sign (32, -1)) -> true | _ -> false))

(* C given the views F18 makes of a string's bytes: read-only copies
   standing for storage whose identity is unknown. *)
let views_source =
  {|
#include <stddef.h>
#include <stdlib.h>

typedef long long ll;

ll v_sum(const unsigned char *x, ll n) { ll s = 0; for (ll i = 0; i < n; i++) s += x[i]; return s; }
ll v_same(const char *x, const char *y) { return x == y; }
ll v_heap(const char *x) { char *p = malloc(1); ll r = x == p; free(p); return r; }
ll v_distance(const char *x, const char *y) { return x - y; }
ll v_null(const char *x) { return x == NULL; }
ll v_store(char *x) { x[0] = 'z'; return 0; }
|}

let text s =
  C_cross.view ~size:(String.length s) ~align:1 (fun a ->
      String.iteri (fun i c -> C_memory.put_bytes a i 1 (Int64.of_int (Char.code c))) s)

let views base =
  match compile base "views" views_source with
  | None -> check "the C evaluator's view cases compile" false
  | Some bitcode ->
      with_module bitcode (fun m ->
          check "C reads a view's bytes"
            (evaluate_on m "v_sum" (fun () -> [ text "zane"; C_memory.Int (64, 4L) ]) = Ok (C_memory.Int (64, 430L)));
          List.iter
            (fun (name, args, why) ->
              match evaluate_on m name args with
              | Error w when String.starts_with ~prefix:why w -> ()
              | r ->
                  Printf.printf "  %s: %s\n" name (match r with Ok _ -> "folded" | Error w -> "stopped: " ^ w);
                  check (Printf.sprintf "C evaluation stops at %s: %s" name why) false)
            [
              ("v_same", (fun () -> [ text "zane"; text "zane" ]), "a comparison of addresses whose storage may be shared");
              ("v_heap", (fun () -> [ text "zane" ]), "a comparison of addresses whose storage may be shared");
              ("v_distance", (fun () -> [ text "ab"; text "ab" ]), "the numeric value of an address");
              ("v_null", (fun () -> [ text "" ]), "a comparison of an empty view's address with null");
              ("v_store", (fun () -> [ text "zane" ]), "a store into memory C may not write");
            ];
          check "a view that is not empty is not null" (evaluate_on m "v_null" (fun () -> [ text "z" ]) = Ok (C_memory.Int (64, 0L))))

(* A constructor that stops leaves no state the running program has. *)
let constructed_source =
  {|
typedef long long ll;
static volatile int touched;
__attribute__((constructor)) static void touch(void) { touched = 1; }
ll c_add(ll a, ll b) { return a + b; }
|}

let constructed base =
  match compile base "constructed" constructed_source with
  | None -> check "the C evaluator's constructor case compiles" false
  | Some bitcode ->
      with_module bitcode (fun m ->
          check "a constructor that stops stops every call"
            (match evaluate m "c_add" 1L 2L with Error w -> String.starts_with ~prefix:"a volatile access" w | Ok _ -> false))

let run () =
  let base = Filename.temp_dir "zane-c-eval-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
      agree base;
      stop base;
      views base;
      constructed base)

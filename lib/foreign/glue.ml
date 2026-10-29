(* The glue: the C that does every call into a package's C code, so the
   compiler implements no C ABI of its own (docs/design/ffi.md F8).

   For each interface header that declares a function a foreign verb
   calls, one C file includes that header alone, `#undef`s each such
   function's name so that a macro of the same name never stands in for
   it, and defines one thunk per foreign verb. A thunk takes the addresses
   of slots holding its arguments, each laid out as C lays out its type,
   and of a slot for the result, and does the call with the conversions
   of spec ffi.md §3.3 as C casts. It is named by an `__asm__` label, its
   foreign verb's symbol, which is no C identifier. Every identifier the
   glue declares itself begins `__zane_`, which C reserves to the
   implementation, so none hides a function of the header, as a parameter
   named `result` would hide a C function `result`. Each file is compiled
   as the package's sources are, with its settings, and kept in the cache
   alike. *)

(* How a value crosses, as the slot holding it is read: a scalar of the
   Zane type whose C type is given, which C converts to its own, a `Bool`
   as a byte, `Unit` as no value, and any other as the C type itself. *)
type kind = Scalar of string | Bool | Unit | Same

(* A thunk: its label, which is its symbol after the target's global
   prefix, the C function it calls, and how each argument and the result
   cross. *)
type entry = { label : string; c_function : string; params : kind list; result : kind }

(* [s] as a C string literal's contents. *)
let escaped s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | c when Char.code c < 0x20 || Char.code c >= 0x7f -> Buffer.add_string b (Printf.sprintf "\\%03o" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(* One thunk, the [n]th of its file, calling [f] whose parameters and
   result the header spells as [spelled] and [spelled_result]. *)
let thunk n (e : entry) (f : C_interface.func) =
  let b = Buffer.create 256 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  let name = Printf.sprintf "__zane_thunk_%d" n in
  line "void %s(void *const *__zane_args, void *__zane_result) __asm__(\"%s\");" name (escaped e.label);
  line "void %s(void *const *__zane_args, void *__zane_result) {" name;
  List.iteri (fun i s -> line "  typedef __typeof__(%s) __zane_p%d;" s i) f.C_interface.spelled;
  let arg i = function
    | Scalar c -> Printf.sprintf "(__zane_p%d)*(const %s *)__zane_args[%d]" i c i
    | Bool -> Printf.sprintf "(__zane_p%d)(*(const unsigned char *)__zane_args[%d] & 1)" i i
    | Same | Unit -> Printf.sprintf "*(const __zane_p%d *)__zane_args[%d]" i i
  in
  let call = Printf.sprintf "%s(%s)" e.c_function (String.concat ", " (List.mapi arg e.params)) in
  (match e.result with
  | Unit -> line "  (void)__zane_result;"
  | _ -> ());
  if e.params = [] then line "  (void)__zane_args;";
  (match e.result with
  | Unit -> line "  %s;" call
  | Scalar c -> line "  *(%s *)__zane_result = (%s)%s;" c c call
  | Bool -> line "  *(unsigned char *)__zane_result = (unsigned char)(%s != 0);" call
  | Same ->
      line "  typedef __typeof__(%s) __zane_r;" f.C_interface.spelled_result;
      line "  __zane_r __zane_value = %s;" call;
      line "  __builtin_memcpy(__zane_result, &__zane_value, sizeof __zane_value);");
  line "}";
  Buffer.contents b

(* The glue file that includes [header], an absolute path, and defines
   [entries], each with its C function's declaration. `<stdint.h>` comes
   first, since a scalar slot is read as a fixed-width type, which a
   header declaring only `int` or `long long` need not include. *)
let file ~header (entries : (entry * C_interface.func) list) =
  let b = Buffer.create 1024 in
  Buffer.add_string b "#include <stdint.h>\n";
  Buffer.add_string b (Printf.sprintf "#include \"%s\"\n" (escaped header));
  let called = List.sort_uniq compare (List.map (fun ((e : entry), _) -> e.c_function) entries) in
  List.iter (fun c -> Buffer.add_string b (Printf.sprintf "#undef %s\n" c)) called;
  List.iteri (fun n (e, f) -> Buffer.add_string b (thunk n e f)) entries;
  Buffer.contents b

(* The interface header among [tables], in the order they are read, that
   declares [name], with its declaration: the first, as the merged table
   takes it. *)
let declaring tables name =
  List.find_map
    (fun (header, (t : C_interface.t)) -> Option.map (fun f -> (header, f)) (List.assoc_opt name t.C_interface.functions))
    tables

(* [entries] grouped into the files of the headers that declare their C
   functions, in the order the headers are read. *)
let files tables entries =
  let placed = List.map (fun (e : entry) -> (e, declaring tables e.c_function)) entries in
  List.filter_map
    (fun (header, _) ->
      match List.filter_map (function e, Some (h, f) when h = header -> Some (e, f) | _ -> None) placed with
      | [] -> None
      | mine -> Some (header, file ~header mine))
    tables

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
   header declaring only `int` or `long long` need not include. A quoted
   header name is read as it is written, escapes and all, so the path goes
   in unescaped; Foreign refuses one holding a double quote or a line break. *)
let file ~header (entries : (entry * C_interface.func) list) =
  let b = Buffer.create 1024 in
  Buffer.add_string b "#include <stdint.h>\n";
  Buffer.add_string b (Printf.sprintf "#include \"%s\"\n" header);
  let called = List.sort_uniq compare (List.map (fun ((e : entry), _) -> e.c_function) entries) in
  List.iter (fun c -> Buffer.add_string b (Printf.sprintf "#undef %s\n" c)) called;
  List.iteri (fun n (e, f) -> Buffer.add_string b (thunk n e f)) entries;
  Buffer.contents b

(* The interface header among [tables], in the order they are read, that
   declares [name], with its declaration, as the merged table takes it:
   the first to give it a prototype, else the first. *)
let declaring tables name =
  let declared =
    List.filter_map
      (fun (header, (t : C_interface.t)) -> Option.map (fun f -> (header, f)) (List.assoc_opt name t.C_interface.functions))
      tables
  in
  match List.find_opt (fun (_, (f : C_interface.func)) -> match f.ty with C_interface.Function _ -> true | _ -> false) declared with
  | Some d -> Some d
  | None -> List.nth_opt declared 0

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

(* What a function value's C entry and invoker pass (docs/design/ffi.md
   F11): a scalar of the C type given, a `Bool` as `_Bool`, no value, or a
   struct of scalars, arrays of them and such structs, laid out as the
   Zane value type is. *)
type shape = Value of string | Truth | Nothing | Record of (shape * int option) list

(* A lambda's C entry, under [label], calling its adapter [adapter]; and
   an invoker, under [label], calling the function value its first slot
   holds. *)
type callback = { label : string; adapter : string; params : shape list; result : shape }
type invoker = { at : string; takes : shape list; gives : shape }

(* The file of the C entries [callbacks] and the invokers [invokers]: it
   includes nothing, so it needs no C library's headers, and declares a
   struct for each record shape. *)
let callbacks_file (callbacks : callback list) (invokers : invoker list) =
  let b = Buffer.create 1024 in
  let structs = Buffer.create 256 in
  let named = Hashtbl.create 8 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  let rec c_type = function
    | Value c -> c
    | Truth -> "_Bool"
    | Nothing -> "void"
    | Record members as r -> (
        match Hashtbl.find_opt named r with
        | Some n -> n
        | None ->
            let fields =
              List.mapi
                (fun i (m, count) ->
                  let t = c_type m in
                  match count with
                  | Some n -> Printf.sprintf "%s __zane_f%d[%d];" t i n
                  | None -> Printf.sprintf "%s __zane_f%d;" t i)
                members
            in
            let n = Printf.sprintf "struct __zane_s%d" (Hashtbl.length named) in
            Hashtbl.replace named r n;
            Buffer.add_string structs (Printf.sprintf "%s { %s };\n" n (String.concat " " fields));
            n)
  in
  List.iteri
    (fun n (c : callback) ->
      let name = Printf.sprintf "__zane_entry_%d" n and adapter = Printf.sprintf "__zane_adapter_%d" n in
      let params = List.mapi (fun i p -> Printf.sprintf "%s __zane_a%d" (c_type p) i) c.params in
      let params = if params = [] then "void" else String.concat ", " params in
      let result = c_type c.result in
      line "void %s(void *const *__zane_args, void *__zane_result) __asm__(\"%s\");" adapter (escaped c.adapter);
      line "%s %s(%s) __asm__(\"%s\");" result name params (escaped c.label);
      line "__attribute__((no_stack_protector)) %s %s(%s) {" result name params;
      List.iteri (fun i p -> if p = Truth then line "  unsigned char __zane_b%d = __zane_a%d;" i i) c.params;
      let slot i p = if p = Truth then Printf.sprintf "&__zane_b%d" i else Printf.sprintf "&__zane_a%d" i in
      (match c.params with
      | [] -> line "  void *__zane_args[1] = { 0 };"
      | ps -> line "  void *__zane_args[] = { %s };" (String.concat ", " (List.mapi slot ps)));
      (match c.result with
      | Nothing -> line "  %s(__zane_args, 0);" adapter
      | Truth ->
          line "  unsigned char __zane_r = 0;";
          line "  %s(__zane_args, &__zane_r);" adapter;
          line "  return __zane_r != 0;"
      | _ ->
          line "  %s __zane_r;" result;
          line "  __builtin_memset(&__zane_r, 0, sizeof __zane_r);";
          line "  %s(__zane_args, &__zane_r);" adapter;
          line "  return __zane_r;");
      line "}")
    callbacks;
  List.iteri
    (fun n (i : invoker) ->
      let name = Printf.sprintf "__zane_invoke_%d" n in
      let params = if i.takes = [] then "void" else String.concat ", " (List.map c_type i.takes) in
      let result = c_type i.gives in
      line "void %s(void *const *__zane_args, void *__zane_result) __asm__(\"%s\");" name (escaped i.at);
      line "void %s(void *const *__zane_args, void *__zane_result) {" name;
      line "  typedef %s (*__zane_fn)(%s);" result params;
      line "  __zane_fn __zane_f = *(__zane_fn const *)__zane_args[0];";
      let arg k p =
        if p = Truth then Printf.sprintf "(_Bool)(*(const unsigned char *)__zane_args[%d] & 1)" (k + 1)
        else Printf.sprintf "*(const %s *)__zane_args[%d]" (c_type p) (k + 1)
      in
      let call = Printf.sprintf "__zane_f(%s)" (String.concat ", " (List.mapi arg i.takes)) in
      (match i.gives with
      | Nothing -> line "  (void)__zane_result;"; line "  %s;" call
      | Truth -> line "  *(unsigned char *)__zane_result = (unsigned char)(%s != 0);" call
      | _ ->
          line "  %s __zane_v = %s;" result call;
          line "  __builtin_memcpy(__zane_result, &__zane_v, sizeof __zane_v);");
      line "}")
    invokers;
  Buffer.contents structs ^ Buffer.contents b

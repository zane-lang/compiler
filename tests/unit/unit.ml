module Ty = Tst.Ty
module S = Tst.Signature
module T = Tst.Nodes
module Overloads = Tst__Overloads
module Borrows = Tst__Borrows
module Fixpoint = Tst__Fixpoint
module Abi = Codegen__Abi
module State = Cgt__State
module Type_layout = Cgt__Type_layout
module TIntrinsics = Tst.Intrinsics

open Support
open Cgt_terms

let span = Source.Span.of_loc (Lexing.dummy_pos, Lexing.dummy_pos)
let prim name = Ty.Intrinsic { namespace = "primitives"; name; args = [] }
let int = prim "I64"
let float = prim "F64"
let named ?(args = []) name = Ty.Named ({ Ty.package = "app"; name }, args)
let param name = Ty.fresh_param ~name ~kind:Ty.Type_kind

(* ---------------------------------------------------------------------- *)
(* Ty                                                                     *)
(* ---------------------------------------------------------------------- *)

let ty () =
  let t = param "T" and u = param "U" in
  check "equal keeps a guest apart" (not (Ty.equal (Ty.Reference int) int));
  check "assignable looks through a guest" (Ty.assignable ~dst:int ~src:(Ty.Reference int));
  check "equal tells primitives apart" (not (Ty.equal int float));
  check "Error equals anything" (Ty.equal Ty.Error (named "Point"));
  check "parameters are equal by id, not name"
    (not (Ty.equal (Ty.Param t) (Ty.Param { t with Ty.id = t.Ty.id + 1000 })));
  check "strip_mode" (Ty.strip_mode (Ty.Reference int) = int);
  check "is_ref" (Ty.is_ref (Ty.Reference int) && not (Ty.is_ref int));
  let pair = named "Pair" ~args:[ Ty.Type (Ty.Param t); Ty.Type (Ty.Param u) ] in
  check "subst replaces every parameter"
    (Ty.equal
       (Ty.subst [ (t.Ty.id, Ty.Type int); (u.Ty.id, Ty.Type float) ] pair)
       (named "Pair" ~args:[ Ty.Type int; Ty.Type float ]));
  check "subst leaves other parameters"
    (Ty.equal (Ty.subst [ (t.Ty.id, Ty.Type int) ] (Ty.Param u)) (Ty.Param u));
  check "bindings pairs parameters with arguments in order"
    (Ty.bindings [ t; u ] [ Ty.Type int; Ty.Type float ]
    = [ (t.Ty.id, Ty.Type int); (u.Ty.id, Ty.Type float) ]);
  check "instantiate"
    (Ty.equal (Ty.instantiate [ t ] [ Ty.Type int ] (Ty.Reference (Ty.Param t))) (Ty.Reference int));
  raises_bug "instantiate with too few arguments is a bug" (fun () ->
      Ty.instantiate [ t; u ] [ Ty.Type int ] (Ty.Param t));
  raises_bug "instantiate with too many arguments is a bug" (fun () ->
      Ty.instantiate [] [ Ty.Type int ] int);
  check "unify binds an open parameter"
    (Ty.unify ~open_:[ t ] [] (Ty.Param t) int = Some [ (t.Ty.id, Ty.Type int) ]);
  check "unify keeps a binding it already has"
    (Ty.unify ~open_:[ t ] [ (t.Ty.id, Ty.Type int) ] (Ty.Param t) float = None);
  check "a bare literal drives no inference"
    (Ty.unify ~open_:[ t ] [] (Ty.Param t) (Ty.Concept Ty.Integer_lit) = None);
  let fn is_mut = Ty.Verb { this_ = None; params = [ int ]; ret = int; abort = None; is_mut } in
  check "a `mut` function type holds a lambda that is not" (Ty.assignable ~dst:(fn true) ~src:(fn false));
  check "a plain function type does not hold a `mut` one" (not (Ty.assignable ~dst:(fn false) ~src:(fn true)))

(* ---------------------------------------------------------------------- *)
(* Signature                                                              *)
(* ---------------------------------------------------------------------- *)

let signature ?(kind = S.Function) ?(generics = []) name params ret =
  {
    S.owner = S.Intrinsic name;
    name;
    home = S.Package "app";
    kind;
    generics;
    params =
      List.map (fun (name, ty) -> { S.name; ty; binds = None; has_default = false }) params;
    ret;
    abort = None;
    is_mut = false;
  }

let signatures () =
  let f = signature "f" [ ("x", int) ] float in
  check "a function prints as it is declared"
    (S.to_string f = "@primitives$F64 f(@primitives$I64)");
  let m = signature ~kind:S.Method "size" [ ("this", named "Bag"); ("n", int) ] int in
  check "a method prints its subject" (S.to_string m = "@primitives$I64 size(this app$Bag, @primitives$I64)");
  check "is_method" (S.is_method m && not (S.is_method f));
  check "has_block_param" (S.has_block_param (signature "g" [ ("b", Ty.Concept Ty.Block) ] int))

(* ---------------------------------------------------------------------- *)
(* Overload ranking                                                       *)
(* ---------------------------------------------------------------------- *)

let actual ty =
  {
    Overloads.arg = T.Arg.Value { T.Expr.node = T.Expr.Invalid; ty; span };
    aty = ty;
    aspan = span;
    subject = false;
  }

let resolve candidates args =
  Overloads.resolve (Tst__Env.create ()) candidates (fun s -> Overloads.positional (List.map actual args) s)

let name_of = function
  | Overloads.Resolved o -> o.Overloads.sig_.S.name
  | Overloads.No_match -> "no match"
  | Overloads.Ambiguous _ -> "ambiguous"

let overloads () =
  let t = param "T" in
  let on_int = signature "onInt" [ ("x", int) ] int
  and on_float = signature "onFloat" [ ("x", float) ] int
  and generic = signature ~generics:[ t ] "generic" [ ("x", Ty.Param t) ] int
  and twice = signature "twice" [ ("x", int); ("y", int) ] int in
  check "the candidate whose parameter matches" (name_of (resolve [ on_int; on_float ] [ float ]) = "onFloat");
  check "an exact candidate before a generic one" (name_of (resolve [ generic; on_int ] [ int ]) = "onInt");
  check "a generic candidate when no exact one matches"
    (match resolve [ generic; on_int ] [ float ] with
    | Overloads.Resolved o -> o.Overloads.sig_.S.name = "generic" && o.Overloads.subst = [ (t.Ty.id, Ty.Type float) ]
    | _ -> false);
  check "two exact candidates are ambiguous"
    (name_of (resolve [ on_int; { on_int with S.name = "again" } ] [ int ]) = "ambiguous");
  check "the wrong number of arguments matches nothing" (name_of (resolve [ twice ] [ int ]) = "no match");
  check "all_some" (Overloads.all_some [ Some 1; Some 2 ] = Some [ 1; 2 ]);
  check "all_some with one missing" (Overloads.all_some [ Some 1; None ] = None)

let string_constructors () =
  let params =
    List.filter_map
      (fun ((namespace, name), (signature : S.t)) ->
        if namespace = "primitives" && name = "String" then
          match signature.S.params with [ p ] -> Some p.S.ty | _ -> None
        else None)
      TIntrinsics.constructors
  in
  List.iter
    (fun (name, scalar) ->
      check
        ("String has a constructor from " ^ name)
        (List.exists (Ty.equal scalar) params))
    [ ("I32", prim "I32"); ("I64", prim "I64"); ("F32", prim "F32"); ("F64", prim "F64") ]

(* Every name a program writes in an intrinsic namespace, and every
   spelling a call to an intrinsic resolves to, has a description for the
   language server, and the table describes nothing else. *)
let intrinsic_descriptions () =
  let spellings =
    List.map (fun ns -> "@" ^ ns ^ "$") TIntrinsics.namespaces
    @ List.map TIntrinsics.spelling_of TIntrinsics.entries
    @ List.filter_map
        (fun (s : S.t) -> match s.S.owner with S.Intrinsic spelling -> Some spelling | S.Declared _ -> None)
        TIntrinsics.every_verb
  in
  List.iter
    (fun spelling -> check (spelling ^ " has a description") (Tst.Intrinsic_docs.find spelling <> None))
    spellings;
  List.iter
    (fun (spelling, _) -> check (spelling ^ " is an intrinsic") (List.mem spelling spellings))
    Tst.Intrinsic_docs.all;
  (* A hover shows the parameters a call writes, not those the checker
     supplies. *)
  let texts spelling = List.map TIntrinsics.signature_text (TIntrinsics.signatures spelling) in
  let has_param name text =
    let needle = name ^ " " in
    let rec at i = i + String.length needle <= String.length text && (String.sub text i (String.length needle) = needle || at (i + 1)) in
    at 0
  in
  List.iter
    (fun (spelling, hidden) ->
      check (spelling ^ " is listed") (texts spelling <> []);
      List.iter (fun t -> check (spelling ^ " hides " ^ hidden) (not (has_param hidden t))) (texts spelling))
    [
      ("@controlflow$work", "test");
      ("@controlflow$register", "test");
      ("@primitives$start", "publish");
      ("@primitives$startAlone", "test");
      ("@primitives$ArrayRef.fill", "index");
    ];
  check "fill shows make" (List.for_all (has_param "make") (texts "@primitives$ArrayRef.fill"))

(* ---------------------------------------------------------------------- *)
(* Type layout                                                            *)
(* ---------------------------------------------------------------------- *)

let type_layout () =
  let st = State.create ~region:Cgt.Runtime.default_fixed_region ~import_bodies:false ~library:false ~exclusive:false ~exports:(fun _ -> false) ~stamp:(fun _ -> "") ~stamped:(fun _ -> false) in
  let t = param "T" in
  Hashtbl.replace st.State.types ("app", "Box")
    ([ t ], T.Decl.Struct [ ("item", Ty.Param t); ("count", int) ], false);
  let box = named "Box" ~args:[ Ty.Type float ] in
  let array =
    Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type int; Ty.Number (Ty.Known 3) ] }
  in
  let module N = Cgt.Nodes.Ty in
  check "Int is an i64" (Type_layout.ty st span int = N.I64);
  check "Float is an f64" (Type_layout.ty st span float = N.F64);
  check "Unit is void" (Type_layout.ty st span (prim "Unit") = N.Void);
  check "an array is an LLVM array" (Type_layout.ty st span array = N.Array (N.I64, 3));
  check "array_of" (Type_layout.array_of array = Some (int, 3));
  check "a struct's members are instantiated"
    (match Type_layout.definition st box with
    | Some (T.Decl.Struct [ ("item", item); ("count", _) ], false) -> Ty.equal item float
    | _ -> false);
  check "a struct is a struct of its members" (Type_layout.ty st span box = N.Struct [ N.F64; N.I64 ]);
  check "a value type is not a reference" (not (Type_layout.reference st box));
  raises_bug "a declared type with the wrong number of arguments is a bug" (fun () ->
      Type_layout.definition st (named "Box"));
  (* An array of owning elements is one position, which names its
     element's layout, however long it is. *)
  let strings n =
    Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type (prim "String"); Ty.Number (Ty.Known n) ] }
  in
  let module L = Cgt.Nodes.Layout in
  check "an array of 100,000 strings is one position"
    (match Type_layout.positions st span (strings 100_000) 0 [] with
    | [ { L.kind = L.Array { count = 100_000; stride = 24; elements }; offset = 0; _ } ] ->
        (match Hashtbl.find st.State.layouts elements with
        | [ { L.kind = L.Text; offset = 0; tags = []; _ } ] -> true
        | _ -> false)
    | _ -> false);
  check "an array of arrays of strings is one position"
    (match Type_layout.positions st span (Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type (strings 10); Ty.Number (Ty.Known 1000) ] }) 0 [] with
    | [ { L.kind = L.Array { count = 1000; stride = 240; elements }; _ } ] -> (
        match Hashtbl.find st.State.layouts elements with
        | [ { L.kind = L.Array { count = 10; stride = 24; _ }; _ } ] -> true
        | _ -> false)
    | _ -> false);
  check "an array of what owns nothing has no positions" (Type_layout.positions st span array 0 [] = [])

(* A type that holds itself at a growing argument (generics.md §2.4), which
   semantics rejects, reaches lowering only by a bug; the walks over its
   members then stop at their depth limit instead of running forever. *)
let growing_types () =
  let st = State.create ~region:Cgt.Runtime.default_fixed_region ~import_bodies:false ~library:false ~exclusive:false ~exports:(fun _ -> false) ~stamp:(fun _ -> "") ~stamped:(fun _ -> false) in
  let t = param "T" in
  let pair e = Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type e; Ty.Number (Ty.Known 2) ] } in
  Hashtbl.replace st.State.types ("app", "Grow")
    ([ t ], T.Decl.Variant [ ("done", prim "Unit"); ("more", named "Grow" ~args:[ Ty.Type (pair (Ty.Param t)) ]) ], false);
  let grow = named "Grow" ~args:[ Ty.Type int ] in
  let more = named "Grow" ~args:[ Ty.Type (pair int) ] in
  raises_bug "boxing a growing type stops once it keeps growing" (fun () -> Type_layout.boxed st grow more);
  raises_bug "laying out a growing type stops once it keeps growing" (fun () -> Type_layout.layout st span grow);
  let deeper = function
    | Ty.Named (_, [ Ty.Type e ]) -> [ Ty.Reference (named "Node" ~args:[ Ty.Type (pair e) ]) ]
    | _ -> []
  in
  raises_bug "following references through a growing type stops once it keeps growing" (fun () ->
      Borrows.reached_through_references ~members:deeper (named "Node" ~args:[ Ty.Type int ]))

(* A chain of 2,000 verbs, each calling the next, listed caller first, so
   that the fact the last one starts gets back to the first one link by link.
   Walking every body until no summary grows takes a round per link, so about
   n * n walks; the worklist walks each body once and each caller once more
   (Fixpoint, F25). The round-robin count is taken here too, so the chain is
   known to be the worst case for it. *)
let fixpoint_chain () =
  let n = 2000 in
  let walk t i =
    Fixpoint.add t i (if i = n - 1 then true else Fixpoint.read t (i + 1))
  in
  let t = Fixpoint.create ~empty:false ~union:( || ) ~equal:Bool.equal in
  let reported = ref 0 in
  Fixpoint.settle t (List.init n Fun.id) (fun ~report i ->
      if report then incr reported;
      walk t i);
  check "the fixed point reaches the head of the chain" (Fixpoint.read t 0);
  check "every body is walked once more to report" (!reported = n);
  check "a worst-first chain settles in a walk per body and one per caller"
    (Fixpoint.walks t = (2 * n) - 1);
  let rounds = Fixpoint.create ~empty:false ~union:( || ) ~equal:Bool.equal in
  let walks = ref 0 and changed = ref true in
  while !changed do
    changed := false;
    for i = 0 to n - 1 do
      incr walks;
      let before = Fixpoint.read rounds i in
      walk rounds i;
      if Fixpoint.read rounds i <> before then changed := true
    done
  done;
  check "walking every body until nothing grows is quadratic on the chain" (!walks = n * (n + 1))

(* ---------------------------------------------------------------------- *)
(* The runtime's ABI                                                      *)
(* ---------------------------------------------------------------------- *)

(* runtime/zane.h without its comments and preprocessor lines. *)
let header () =
  let text = In_channel.with_open_text "../../runtime/zane.h" In_channel.input_all in
  let b = Buffer.create (String.length text) in
  let n = String.length text in
  let rec go i =
    if i >= n then ()
    else if i + 1 < n && text.[i] = '/' && text.[i + 1] = '*' then
      let rec close j = if j + 1 >= n || (text.[j] = '*' && text.[j + 1] = '/') then j + 2 else close (j + 1) in
      go (close (i + 2))
    else if text.[i] = '#' && (i = 0 || text.[i - 1] = '\n') then
      go (match String.index_from_opt text i '\n' with Some j -> j | None -> n)
    else begin
      Buffer.add_char b text.[i];
      go (i + 1)
    end
  in
  go 0;
  Buffer.contents b

(* Each prototype the header declares: its name, the C type it returns and
   the C types of its parameters, by the text that spells them. *)
let prototypes () =
  let declarations = String.split_on_char ';' (header ()) in
  List.filter_map
    (fun d ->
      let d = String.trim (String.map (function '\n' | '\t' -> ' ' | c -> c) d) in
      match String.index_opt d '(' with
      | None -> None
      | Some open_ ->
          let before = String.trim (String.sub d 0 open_) in
          let cut = match String.rindex_opt before ' ' with Some i -> i + 1 | None -> 0 in
          let cut = match String.rindex_opt before '*' with Some i when i + 1 > cut -> i + 1 | _ -> cut in
          let name = String.sub before cut (String.length before - cut) in
          if not (String.starts_with ~prefix:"zane_" name) then None
          else
            let ret = String.trim (String.sub before 0 cut) in
            (* The parameters: up to the parenthesis that closes the list,
               split at the commas outside a function pointer's own. *)
            let params = Buffer.create 64 and parts = ref [] and depth = ref 0 in
            String.iteri
              (fun i c ->
                if i > open_ then
                  match c with
                  | '(' -> incr depth; Buffer.add_char params c
                  | ')' when !depth = 0 -> depth := -1
                  | ')' -> decr depth; Buffer.add_char params c
                  | ',' when !depth = 0 ->
                      parts := Buffer.contents params :: !parts;
                      Buffer.clear params
                  | c -> if !depth >= 0 then Buffer.add_char params c)
              d;
            parts := Buffer.contents params :: !parts;
            let params = List.rev_map String.trim !parts in
            let params = match params with [ "void" ] | [ "" ] -> [] | ps -> ps in
            Some (name, ret, params))
    declarations

(* How the C ABI passes a type the header spells. *)
let abi c =
  let module R = Cgt.Runtime in
  if String.contains c '*' then Some R.Ptr
  else
    let words = List.filter (fun w -> w <> "" && w <> "const") (String.split_on_char ' ' c) in
    match words with
    | [ "void" ] -> Some R.Void
    | ("zane_thunk" :: _) -> Some R.Ptr
    | ("int64_t" :: _) -> Some R.I64
    | (("uint32_t" | "int32_t") :: _) -> Some R.I32
    | ("float" :: _) -> Some R.F32
    | ("double" :: _) -> Some R.F64
    | _ -> None

let runtime_abi () =
  let module R = Cgt.Runtime in
  let declared = prototypes () in
  check "the header declares functions" (List.length declared > 20);
  List.iter
    (fun fn ->
      let name = R.name fn in
      match List.find_opt (fun (n, _, _) -> n = name) declared with
      | None -> check (name ^ " is declared in zane.h") false
      | Some (_, ret, params) ->
          let ret', params' = R.signature fn in
          check (name ^ " returns what zane.h says") (abi ret = Some ret');
          check
            (name ^ " takes what zane.h says")
            (List.length params = List.length params'
            && List.for_all2 (fun c t -> abi c = Some t) params params'))
    R.all;
  (* `zane_main` is the one function the program defines rather than calls,
     `zane_tier_up` the function codegen calls without a node of the tree:
     tier 0 of a tiered build calls it first (docs/design/tiers.md), and
     `zane_workers_free` a worker pool's free thunk, which a drain calls
     through the pool's layout (Type_layout.pool_free). *)
  List.iter
    (fun (name, _, _) ->
      check (name ^ " in zane.h is a function the compiler knows")
        (name = "zane_main" || name = "zane_tier_up" || name = Cgt__Type_layout.pool_free
        || List.exists (fun fn -> R.name fn = name) R.all))
    declared

(* What LLVM is told about each runtime function (Codegen__Runtime_facts):
   every function's attributes are ones LLVM's parser reads for its
   signature, none names a parameter it lacks, and the facts the optimized
   builds lean on are there. A declaration given them prints them. *)
let runtime_facts () =
  let module R = Cgt.Runtime in
  let module F = Codegen__Runtime_facts in
  let contains text part =
    let n = String.length part in
    let rec at i = i + n <= String.length text && (String.sub text i n = part || at (i + 1)) in
    at 0
  in
  let ctx = Llvm.create_context () in
  let printed fn =
    let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string (F.text fn)) in
    let text = Llvm.string_of_llvalue (Option.get (Llvm.lookup_function "f" m)) in
    Llvm.dispose_module m;
    text
  in
  List.iter
    (fun fn ->
      let f = F.facts fn in
      check (R.name fn ^ "'s facts name no parameter it lacks")
        (List.length f.F.params <= List.length (snd (R.signature fn)));
      check (R.name fn ^ "'s facts parse") (try ignore (F.parsed ctx fn); true with _ -> false))
    R.all;
  let has fn part = check (R.name fn ^ " says " ^ part) (contains (printed fn) part) in
  let handle = "@f(ptr captures(address), i64" in
  List.iter (fun fn -> has fn handle) [ R.List_push; R.List_reserve; R.List_room ];
  let read = "ptr readonly captures(none)" in
  has R.Text_equal ("@f(" ^ read ^ ", " ^ read ^ ")");
  List.iter (fun fn -> has fn "noreturn") [ R.Out_of_range; R.Too_deep; R.Main_aborted ];
  Llvm.dispose_context ctx

(* What the runtime's structs measure, as tests/runtime/abi/probe.c prints
   it on this platform, against the numbers the compiler emits code with,
   which Abi reads from runtime/zane_abi.h. Every number is measured but the
   four nothing but the header defines. *)
let probed_abi () =
  let probed =
    In_channel.with_open_text "../runtime/abi/probe.out" In_channel.input_lines
    |> List.filter_map (fun line ->
           match String.split_on_char ' ' line with
           | [ name; value ] -> Some (name, int_of_string value)
           | _ -> None)
  in
  check "the probe measures something" (probed <> []);
  List.iter
    (fun (name, value) ->
      check
        (Printf.sprintf "%s is %d in the runtime and in Abi" name value)
        (List.assoc_opt name Abi.values = Some value))
    probed;
  check "every number in Abi is measured but ZANE_CHUNK, ZANE_LINE, the list block sizes, ZANE_STRETCH, ZANE_STRETCHED and ZANE_GUARD"
    (List.sort compare
       (List.filter (fun (name, _) -> not (List.mem_assoc name probed)) Abi.values |> List.map fst)
    = [ "ZANE_CHUNK"; "ZANE_GUARD"; "ZANE_LINE"; "ZANE_LIST_ALIGN"; "ZANE_LIST_FIRST"; "ZANE_LIST_LEAST"; "ZANE_STRETCH"; "ZANE_STRETCHED" ]);
  check "lowering lays a handle out as the runtime does"
    (Cgt.Nodes.Ty.size_align Cgt.Nodes.Ty.Handle = (Abi.handle_size, 8))

(* Many programs built in one process, each with functions that take no
   parameters and one that returns an empty struct: LLVM's bindings give an
   empty array as a block of no size in the minor heap, which corrupts it,
   so codegen reads those arrays through stubs of its own (llvm_stubs.c). *)
let repeated_builds () =
  let module C = Cgt.Nodes in
  let f i =
    { C.Func.symbol = "f" ^ string_of_int i; linkage = C.Linkage.Exported; params = []; places = []; ret = C.Ty.I64;
      body = [ C.Stat.Return { C.Expr.node = C.Expr.Int 1L; ty = C.Ty.I64 } ]; values = [] }
  in
  let empty =
    { C.Func.symbol = "empty"; linkage = C.Linkage.Exported; params = []; places = []; ret = C.Ty.Struct [];
      body = [ C.Stat.Return { C.Expr.node = C.Expr.Record []; ty = C.Ty.Struct [] } ];
      values = [] }
  in
  let p = { C.Program.funcs = empty :: List.init 2000 f; entry = None; comptime = []; layouts = []; globals = []; foreign = []; callbacks = []; exclusive = true; exports = []; plugin = false } in
  let built = ref 0 in
  for _ = 1 to 60 do
    match Driver.ir ~optimize:false p with Ok _ -> incr built | Error _ -> ()
  done;
  check "sixty builds of zero-parameter functions in one process" (!built = 60)

(* A build's LLVM context and module are disposed however it ends: built,
   refused before codegen starts (an unknown target), failed after (an
   object it cannot write), or raised out of. *)
let disposed_modules () =
  let module C = Cgt.Nodes in
  let f =
    { C.Func.symbol = "f"; linkage = C.Linkage.Exported; params = []; places = []; ret = C.Ty.I64;
      body = [ C.Stat.Return { C.Expr.node = C.Expr.Int 1L; ty = C.Ty.I64 } ]; values = [] }
  in
  let p = { C.Program.funcs = [ f ]; entry = None; comptime = []; layouts = []; globals = []; foreign = []; callbacks = []; exclusive = true; exports = []; plugin = false } in
  let dir = Filename.temp_dir "zane-unit" "" in
  let none () = Codegen.live_contexts () = 0 in
  check "a built object leaves no context"
    (Result.is_ok (Driver.object_file ~optimize:false p (Filename.concat dir "f.o")) && none ());
  check "an unknown target leaves no context"
    (Result.is_error (Driver.object_file ~target:"nowhere-at-all" ~optimize:false p (Filename.concat dir "g.o")) && none ());
  check "an object that cannot be written leaves no context"
    (Result.is_error (Driver.object_file ~optimize:false p (Filename.concat dir "missing/f.o")) && none ());
  let inside = ref 0 in
  (match Codegen.with_program p (fun _ -> inside := Codegen.live_contexts (); failwith "raised") with
  | _ -> ()
  | exception Failure _ -> ());
  check "a build that raises leaves no context, and had one while it ran" (!inside = 1 && none ());
  Sys.remove (Filename.concat dir "f.o");
  Sys.rmdir dir

(* ---------------------------------------------------------------------- *)
(* Semantics twice                                                        *)
(* ---------------------------------------------------------------------- *)

(* The fixture's typed tree, when it assembles and checks cleanly. *)
let tree () =
  match Tst.Assembly.assemble [ "../codegen/fixtures/lambdas" ] with
  | Error _ -> None
  | Ok packages -> (
      match Tst.check packages with
      | { Tst.Semantics.diagnostics = []; program } ->
          Some (Tree_graph.render (Tst.to_node ~bodies:true program))
      | _ -> None)

let twice () =
  match (tree (), tree ()) with
  | Some first, Some second ->
      check "semantics run twice gives the same tree" (String.equal first second)
  | _ -> check "the fixture checked twice assembles and checks cleanly" false

(* Each check has tables of its own, so two can run at once and give what
   one gives alone. *)
let at_once () =
  let a = Domain.spawn tree and b = Domain.spawn tree in
  match (tree (), Domain.join a, Domain.join b) with
  | Some alone, Some first, Some second ->
      check "two checks at once give what one gives alone"
        (String.equal alone first && String.equal alone second)
  | _ -> check "the fixture checked at once assembles and checks cleanly" false

(* A snapshot of an 8-byte value aligned to 8 is a single load: acquire when
   it holds an address, so what the address names is seen with it, and
   unordered otherwise. Anything narrower, wider, or aligned below its size,
   is read by the runtime. *)
let snapshot_reads () =
  let module T = Cgt.Nodes.Ty in
  let read = Codegen__Emit.snapshot_read in
  check "an I64 is one unordered load" (read T.I64 = `Unordered);
  check "an F64 is one unordered load" (read T.F64 = `Unordered);
  check "a Bool is read by the runtime" (read T.I1 = `Runtime);
  check "an I32 is read by the runtime" (read T.I32 = `Runtime);
  check "an F32 is read by the runtime" (read T.F32 = `Runtime);
  check "an address is one acquire load" (read T.Ptr = `Acquire);
  check "a struct holding only a box is one acquire load" (read (T.Struct [ T.Ptr ]) = `Acquire);
  check "two I32s, aligned below their size, are read by the runtime"
    (read (T.Struct [ T.I32; T.I32 ]) = `Runtime);
  check "a handle is read by the runtime" (read T.Handle = `Runtime);
  check "two I64s are read by the runtime" (read (T.Struct [ T.I64; T.I64 ]) = `Runtime)

(* A counted loop that returns early is marked to be unrolled twice only
   when it calls nothing (Emit.unrolled): a call by name, through a value,
   into C or into the runtime keeps it unmarked, and so do an approximate
   math function, a box, a snapshot, an overwrite and a hold of a value
   whose layout lists anything, each of which emits a call; an element's
   index check, emitted in line, an LLVM intrinsic such as `sqrt` and a
   hold of a layout that lists nothing do not; a loop that never leaves
   early is not marked. *)
let unroll_marks () =
  let open Cgt.Nodes in
  let unrolled = Codegen__Emit.unrolled ~listed:(fun l -> l = "Listed") in
  let e node ty = { Expr.node; ty } in
  let int n = e (Expr.Int (Int64.of_int n)) Ty.I64 in
  let leave = Stat.If { cond = e (Expr.Bool true) Ty.I1; body = [ Stat.Return (int 0) ] } in
  let with_ node = [ Stat.Eval (e node Ty.I64); leave ] in
  check "a loop of arithmetic that returns early is marked" (unrolled [ leave ]);
  check "a loop that never leaves early is not marked" (not (unrolled [ Stat.Eval (int 1) ]));
  check "a call by name keeps it unmarked" (not (unrolled (with_ (Expr.Call { fn = "f"; args = [] }))));
  check "a call through a value keeps it unmarked"
    (not (unrolled (with_ (Expr.Call_value { fn = e (Expr.Local 1) Ty.Ptr; args = [] }))));
  check "a call into C keeps it unmarked" (not (unrolled (with_ (Expr.Foreign_call { thunk = "t"; args = [] }))));
  check "a call into the runtime keeps it unmarked"
    (not (unrolled (with_ (Expr.Runtime { fn = Cgt.Runtime.Text_i64; args = [ int 1 ] }))));
  let float = e (Expr.Float 1.0) Ty.F64 in
  check "an approximate math function keeps it unmarked"
    (not (unrolled (with_ (Expr.Math { fn = Cgt.Math.Sin; args = [ float ] }))));
  check "an intrinsic math function leaves it marked" (unrolled (with_ (Expr.Math { fn = Cgt.Math.Sqrt; args = [ float ] })));
  check "a box keeps it unmarked" (not (unrolled (with_ (Expr.Box { value = int 1; layout = "Plain" }))));
  check "a snapshot keeps it unmarked" (not (unrolled (with_ (Expr.Snapshot (e (Expr.Local 1) Ty.Ptr)))));
  let at = e (Expr.Local 1) Ty.Ptr in
  check "an overwrite keeps it unmarked"
    (not (unrolled [ Stat.Overwrite { address = at; value = int 1; layout = "Plain"; setters = false }; leave ]));
  let hold layout = [ Stat.Hold { id = 2; scope = 3; value = int 1; layout }; leave ] in
  check "a hold of a listed layout keeps it unmarked" (not (unrolled (hold "Listed")));
  check "a hold of a layout that lists nothing leaves it marked" (unrolled (hold "Plain"));
  check "an element's index check leaves it marked"
    (unrolled (with_ (Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ e (Expr.Local 1) Ty.Ptr; int 1; int 8 ] })))

(* Layouts share their walks when their positions are alike and what each
   nests is walked alike: two lists of strings under different names, and
   two boxed lists that name themselves, share; a list of a differently
   laid-out record, or a box of a different size, does not. *)
let shared_walks () =
  let module L = Cgt.Nodes.Layout in
  let at kind = { L.kind; offset = 0; size = 24; tags = [] } in
  let positions = Hashtbl.create 8 in
  List.iter
    (fun (l, ps) -> Hashtbl.replace positions l ps)
    [
      ("Strings", [ at L.Text ]);
      ("Names", [ at L.Text ]);
      ("Pair", [ at L.Text; { (at L.Text) with L.offset = 24 } ]);
      ("A", [ at (L.List { stride = 24; elements = "Strings" }) ]);
      ("B", [ at (L.List { stride = 24; elements = "Names" }) ]);
      ("C", [ at (L.List { stride = 24; elements = "Pair" }) ]);
      ("Node", [ at (L.Box { size = 8; payload = "Node" }) ]);
      ("Link", [ at (L.Box { size = 8; payload = "Link" }) ]);
      ("Wide", [ at (L.Box { size = 16; payload = "Wide" }) ]);
    ];
  let alike = Codegen__Walks.alike positions in
  let shares a b = Hashtbl.find alike a = Hashtbl.find alike b in
  check "two layouts of one string share their walks" (shares "Strings" "Names");
  check "so do lists of them under different names" (shares "A" "B");
  check "a list of another layout has its own" (not (shares "A" "C"));
  check "two boxes that name themselves share theirs" (shares "Node" "Link");
  check "a box of another size has its own" (not (shares "Node" "Wide"));
  check "a shared walk is named for the first layout"
    (Hashtbl.find alike "Names" = "Names" && Hashtbl.find alike "Strings" = "Names")

(* Code for x86-64 is tuned as clang tunes it, for the baseline `x86-64`
   processor whatever spelling the triple has, and for Haswell on `x86_64h`;
   other targets keep LLVM's default. *)
let target_cpus () =
  let cpu target = Codegen.target_cpu ~target () in
  check "an x86-64 Linux target is tuned for x86-64" (cpu "x86_64-unknown-linux-gnu" = Ok "x86-64");
  check "a short x86-64 Windows triple is tuned for x86-64" (cpu "x86_64-windows-gnu" = Ok "x86-64");
  check "an amd64 triple is tuned for x86-64" (cpu "amd64-unknown-freebsd" = Ok "x86-64");
  check "an x86_64h target is tuned for Haswell" (cpu "x86_64h-apple-darwin" = Ok "core-avx2");
  check "an AArch64 target keeps LLVM's default" (cpu "aarch64-unknown-linux-gnu" = Ok "")

(* A type's size is built with checked arithmetic, and one of 2^48 bytes or
   more is refused rather than wrapping (docs/design/lowering.md §9). *)
let checked_sizes () =
  let module T = Cgt.Nodes.Ty in
  let refused t = match T.size_align t with _ -> false | exception T.Too_large -> true in
  check "2^32 I64s take 32 GiB" (T.size_align (T.Array (T.I64, 1 lsl 32)) = (1 lsl 35, 8));
  check "an array of arrays multiplies both lengths"
    (T.size_align (T.Array (T.Array (T.I64, 65536), 65536)) = (1 lsl 35, 8));
  check "just under 2^48 bytes is a size" (T.size_align (T.Array (T.I64, (1 lsl 45) - 1)) = ((1 lsl 48) - 8, 8));
  check "2^48 bytes is refused" (refused (T.Array (T.I64, 1 lsl 45)));
  check "2^60 I64s, which wrap to 0 unchecked, are refused" (refused (T.Array (T.I64, 1 lsl 60)));
  check "a length past max_int / 8 is refused" (refused (T.Array (T.I64, max_int)));
  check "two members that together reach the limit are refused"
    (refused (T.Struct [ T.Array (T.I64, 1 lsl 44); T.Array (T.I64, 1 lsl 44) ]));
  check "a sum whose payload reaches the limit is refused" (refused (T.Sum [ T.Array (T.I64, 1 lsl 45) ]));
  check "nothing many times over takes nothing" (T.size_align (T.Array (T.Void, max_int)) = (0, 1))

(* An LLVM array type keeps all 64 bits of its length, which the bindings'
   own `array_type` truncates to 32 (llvm_stubs.c). *)
(* What Emit builds a module with, for [triple] and with or without
   packing, in a context and module of its own. *)
let emit_env ?(pack = false) ?(triple = "x86_64-unknown-linux-gnu") () =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "unit" in
  let tags = Codegen__Emit.tags ctx in
  {
    Codegen__Emit.ctx;
    m;
    ptr = Llvm.pointer_type ctx;
    i64 = Llvm.i64_type ctx;
    funcs = Hashtbl.create 1;
    abis = Hashtbl.create 1;
    entries = Hashtbl.create 1;
    registers = Codegen__Call_pieces.registers triple;
    pack;
    passings = Hashtbl.create 1;
    results = Codegen__Call_pieces.results triple;
    returnings = Hashtbl.create 1;
    globals = Hashtbl.create 1;
    walks = None;
    handle_tag = fst tags;
    value_tag = snd tags;
    version = false;
  }

let dispose (env : Codegen__Emit.env) =
  Llvm.dispose_module env.m;
  Llvm.dispose_context env.ctx

let long_arrays () =
  let env = emit_env () in
  let t = Codegen__Emit.lltype env (Cgt.Nodes.Ty.Array (Cgt.Nodes.Ty.I1, 4294967297)) in
  check "an array of 2^32 + 1 elements keeps its length" (Codegen__Llvm_extra.array_length t = 4294967297);
  check "its parts saturate past LLVM's limit"
    (Codegen__Big_moves.parts t = Codegen__Big_moves.most_parts + 1);
  check "a sum's payload room keeps its length"
    (Codegen__Llvm_extra.array_length
       (Codegen__Llvm_extra.struct_element_types
          (Codegen__Emit.lltype env (Cgt.Nodes.Ty.Sum [ Cgt.Nodes.Ty.Array (Cgt.Nodes.Ty.I64, 1 lsl 33) ]))).(1)
    = 1 lsl 33);
  dispose env

(* How many registers a value takes as itself: one per scalar piece, on the
   CGT type (docs/design/lowering.md §9). *)
let counted_pieces () =
  let module T = Cgt.Nodes.Ty in
  let count = Codegen__Call_pieces.pieces in
  check "Unit takes none" (count T.Void = 0);
  check "a scalar takes one" (List.for_all (fun t -> count t = 1) [ T.I1; T.I32; T.I64; T.F32; T.F64; T.Ptr ]);
  check "a handle takes three" (count T.Handle = 3);
  check "a struct takes its members'" (count (T.Struct [ T.I32; T.I32; T.I32; T.I32 ]) = 4);
  check "a struct's Unit member takes none" (count (T.Struct [ T.I64; T.Void ]) = 1);
  check "an empty struct takes none" (count (T.Struct []) = 0);
  check "a nested struct takes its members' members'" (count (T.Struct [ T.Struct [ T.I64; T.F64 ]; T.Handle ]) = 5);
  check "an enum takes its tag" (count (T.Sum [ T.Void; T.Void ]) = 1);
  check "a variant takes its tag and each payload word"
    (count (T.Sum [ T.I64; T.Struct [ T.I64; T.I64 ]; T.Void ]) = 3);
  check "an array takes its element's times its length" (count (T.Array (T.Struct [ T.I64; T.I32 ], 5)) = 10);
  check "an array of Unit takes none" (count (T.Array (T.Void, 7)) = 0);
  check "65,536 I64s take 65,536" (count (T.Array (T.I64, 65536)) = 65536);
  let floats = Codegen__Call_pieces.floats in
  check "a handle has no floating-point piece" (floats T.Handle = 0);
  check "a struct has its members' floating-point pieces" (floats (T.Struct [ T.F64; T.I64; T.F32 ]) = 2);
  check "an array has its element's times its length" (floats (T.Array (T.Struct [ T.F64; T.I32 ], 3)) = 3);
  check "a variant's payload words are not floating-point" (floats (T.Sum [ T.F64; T.Void ]) = 0)

(* Which way each type crosses, per target and with packing. *)
let passings () =
  let module T = Cgt.Nodes.Ty in
  let module E = Codegen__Emit in
  check "x86-64 Linux gives two registers" (Codegen__Call_pieces.registers "x86_64-unknown-linux-gnu" = 2);
  check "AArch64 macOS gives two" (Codegen__Call_pieces.registers "aarch64-apple-darwin" = 2);
  check "x86-64 Windows gives one" (Codegen__Call_pieces.registers "x86_64-unknown-windows-gnu" = 1);
  check "AArch64 Windows gives two" (Codegen__Call_pieces.registers "aarch64-unknown-windows-msvc" = 2);
  let pair = T.Struct [ T.I64; T.I64 ] and small = T.Struct [ T.I32; T.I32; T.I32 ] in
  let linux = emit_env () and windows = emit_env ~triple:"x86_64-unknown-windows-gnu" () in
  let packed = emit_env ~pack:true () and packed_windows = emit_env ~pack:true ~triple:"x86_64-pc-windows-msvc" () in
  check "a scalar passes as itself" (E.passing windows T.I64 = E.Itself);
  check "two pieces pass as themselves on Linux" (E.passing linux pair = E.Itself);
  check "two pieces pass by address on Windows" (E.passing windows pair = E.Address);
  check "three pieces pass by address" (E.passing linux small = E.Address);
  check "a handle passes by address" (E.passing linux T.Handle = E.Address);
  check "65,536 I64s pass by address" (E.passing linux (T.Array (T.I64, 65536)) = E.Address);
  check "packed, three I32s are two words" (E.passing packed small = E.Words 2);
  check "packed, three bytes are one word" (E.passing packed (T.Struct [ T.I1; T.I1; T.I1 ]) = E.Words 1);
  check "packed, a scalar is itself" (E.passing packed T.F64 = E.Itself);
  check "packed, three words go by address" (E.passing packed T.Handle = E.Address);
  check "packed on Windows, one word fits" (E.passing packed_windows (T.Sum [ T.Void; T.Void ]) = E.Words 1);
  check "packed on Windows, two words go by address" (E.passing packed_windows small = E.Address);
  List.iter dispose [ linux; windows; packed; packed_windows ]

(* Which way each type comes back as a result: within three pieces, at
   most two of them floating-point, on x86-64 and AArch64, and within the
   argument limit elsewhere. *)
let returnings () =
  let module T = Cgt.Nodes.Ty in
  let module E = Codegen__Emit in
  check "x86-64 Linux returns three pieces, two floating" (Codegen__Call_pieces.results "x86_64-unknown-linux-gnu" = (3, 2));
  check "x86-64 Windows returns as many" (Codegen__Call_pieces.results "x86_64-unknown-windows-gnu" = (3, 2));
  check "AArch64 macOS returns as many" (Codegen__Call_pieces.results "arm64-apple-macosx" = (3, 2));
  check "Haswell x86-64 returns as many" (Codegen__Call_pieces.results "x86_64h-apple-darwin" = (3, 2));
  check "arm64e returns as many" (Codegen__Call_pieces.results "arm64e-apple-macosx" = (3, 2));
  check "RISC-V returns what it passes" (Codegen__Call_pieces.results "riscv64-unknown-linux-gnu" = (2, 2));
  let linux = emit_env () and windows = emit_env ~triple:"x86_64-unknown-windows-gnu" () in
  let packed = emit_env ~pack:true () in
  check "a handle comes back as itself" (E.returning linux T.Handle = E.Itself);
  check "a handle comes back as itself on Windows" (E.returning windows T.Handle = E.Itself);
  check "a two-word variant comes back as itself"
    (E.returning linux (T.Sum [ T.I64; T.Struct [ T.I64; T.I64 ] ]) = E.Itself);
  check "four pieces come back by address"
    (E.returning linux (T.Struct [ T.I32; T.I32; T.I32; T.I32 ]) = E.Address);
  check "two floats come back as themselves" (E.returning linux (T.Struct [ T.F64; T.F64; T.I64 ]) = E.Itself);
  check "three floats come back by address" (E.returning linux (T.Struct [ T.F64; T.F64; T.F64 ]) = E.Address);
  check "65,536 I64s come back by address" (E.returning linux (T.Array (T.I64, 65536)) = E.Address);
  check "packed, a handle comes back as three words" (E.returning packed T.Handle = E.Words 3);
  check "packed, four words come back by address" (E.returning packed (T.Array (T.I64, 4)) = E.Address);
  List.iter dispose [ linux; windows; packed ]

(* The backstop: a function whose own type still passes or returns an
   aggregate too large to move as one value is a broken invariant. *)
let backstop () =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "backstop" in
  let i64 = Llvm.i64_type ctx in
  let big = Codegen__Llvm_extra.array_type i64 65536 in
  let layout = Llvm_target.DataLayout.of_string "e-m:e-i64:64-n8:16:32:64-S128" in
  ignore (Llvm.declare_function "small" (Llvm.function_type i64 [| Codegen__Llvm_extra.array_type i64 3 |]) m);
  check "a signature of small aggregates passes" (Codegen__Big_moves.rewrite layout m = Ok ());
  ignore (Llvm.declare_function "takes" (Llvm.function_type i64 [| big |]) m);
  raises_bug "a parameter of 65,536 parts is a bug" (fun () -> Codegen__Big_moves.rewrite layout m);
  Llvm.dispose_module m;
  let m = Llvm.create_module ctx "backstop" in
  ignore (Llvm.declare_function "gives" (Llvm.function_type big [||]) m);
  raises_bug "a result of 65,536 parts is a bug" (fun () -> Codegen__Big_moves.rewrite layout m);
  Llvm.dispose_module m;
  Llvm.dispose_context ctx

(* A value too large to move as one LLVM value is moved a part at a time
   when it is only read for its parts or only built from them and stored,
   each part as aligned as its offset allows. *)
let parts_apart () =
  let ctx = Llvm.create_context () in
  let i32 = Llvm.i32_type ctx and i64 = Llvm.i64_type ctx and ptr = Llvm.pointer_type ctx in
  let rooms = Codegen__Llvm_extra.array_type i64 65536 in
  let big = Llvm.struct_type ctx [| i32; i32; rooms |] in
  let layout = Llvm_target.DataLayout.of_string "e-m:e-i64:64-n8:16:32:64-S128" in
  let instrs f =
    let all = ref [] in
    Llvm.iter_blocks (Llvm.iter_instrs (fun i -> all := i :: !all)) f;
    List.rev !all
  in
  let whole i = List.exists (fun t -> t == big) (Llvm.type_of i :: Array.to_list (Array.init (Llvm.num_operands i) (fun n -> Llvm.type_of (Llvm.operand i n)))) in
  let fn m name ret params =
    let f = Llvm.define_function name (Llvm.function_type ret params) m in
    (f, Llvm.builder_at_end ctx (Llvm.entry_block f))
  in
  (* Built from parts and stored. *)
  let m = Llvm.create_module ctx "parts" in
  let f, b = fn m "build" (Llvm.void_type ctx) [| ptr; ptr; i32; i32 |] in
  let inner = Llvm.build_load rooms (Llvm.param f 1) "" b in
  let v = Llvm.build_insertvalue (Llvm.undef big) (Llvm.param f 2) 0 "" b in
  let v = Llvm.build_insertvalue v (Llvm.param f 3) 1 "" b in
  let v = Llvm.build_insertvalue v inner 2 "" b in
  Llvm.set_alignment 8 (Llvm.build_store v (Llvm.param f 0) b);
  ignore (Llvm.build_ret_void b);
  (* Read for one part. *)
  let g, b = fn m "read" i32 [| ptr |] in
  let whole_load = Llvm.build_load big (Llvm.param g 0) "" b in
  Llvm.set_alignment 8 whole_load;
  ignore (Llvm.build_ret (Llvm.build_extractvalue whole_load 1 "" b) b);
  check "a value built of parts and one read for a part move apart" (Codegen__Big_moves.rewrite layout m = Ok ());
  check "nothing moves the whole value" (not (List.exists whole (instrs f @ instrs g)));
  let aligns f op = List.filter_map (fun i -> if Llvm.instr_opcode i = op then Some (Llvm.alignment i) else None) (instrs f) in
  check "each part stored as aligned as its offset" (aligns f Llvm.Opcode.Store = [ 8; 4 ]);
  check "the large part is copied" (List.exists (fun i -> Llvm.instr_opcode i = Llvm.Opcode.Call) (instrs f));
  check "the part read is as aligned as its offset" (aligns g Llvm.Opcode.Load = [ 4 ]);
  Llvm.dispose_module m;
  (* A part put in that is also used elsewhere: the value is still whole. *)
  let m = Llvm.create_module ctx "parts" in
  let f, b = fn m "shared" (Llvm.void_type ctx) [| ptr; ptr; i32 |] in
  let first = Llvm.build_insertvalue (Llvm.undef big) (Llvm.param f 2) 0 "" b in
  ignore (Llvm.build_store first (Llvm.param f 1) b);
  let v = Llvm.build_insertvalue first (Llvm.param f 2) 1 "" b in
  ignore (Llvm.build_store v (Llvm.param f 0) b);
  ignore (Llvm.build_ret_void b);
  check "a value shared before it is stored is still a limit" (Result.is_error (Codegen__Big_moves.rewrite layout m));
  Llvm.dispose_module m;
  (* A constant put in first: the builder folds it into a constant base. *)
  let m = Llvm.create_module ctx "parts" in
  let f, b = fn m "constant" (Llvm.void_type ctx) [| ptr; i32 |] in
  let v = Llvm.build_insertvalue (Llvm.undef big) (Llvm.const_int i32 1) 0 "" b in
  check "the first constant part folds into a constant" (Llvm.is_constant v);
  let v = Llvm.build_insertvalue v (Llvm.param f 1) 1 "" b in
  Llvm.set_alignment 8 (Llvm.build_store v (Llvm.param f 0) b);
  let g, b = fn m "zeros" (Llvm.void_type ctx) [| ptr |] in
  ignore (Llvm.build_store (Llvm.const_null big) (Llvm.param g 0) b);
  ignore (Llvm.build_ret_void b);
  let b = Llvm.builder_at_end ctx (Llvm.entry_block f) in
  ignore (Llvm.build_ret_void b);
  check "a constant base moves apart" (Codegen__Big_moves.rewrite layout m = Ok ());
  check "nor is the constant stored whole" (not (List.exists whole (instrs f @ instrs g)));
  check "the constant's defined part and the part put in are stored, each as aligned as its offset"
    (aligns f Llvm.Opcode.Store = [ 8; 4 ]);
  check "a value of zeros is set to zeros" (List.exists (fun i -> Llvm.instr_opcode i = Llvm.Opcode.Call) (instrs g));
  Llvm.dispose_module m;
  (* An array index of 2^31 or more stays whole in its address. *)
  let i8 = Llvm.i8_type ctx in
  let far = (1 lsl 31) + 1 in
  let bytes = Codegen__Llvm_extra.array_type i8 (far + 7) in
  let m = Llvm.create_module ctx "parts" in
  let f, b = fn m "read_far" i8 [| ptr |] in
  let whole_bytes = Llvm.build_load bytes (Llvm.param f 0) "" b in
  ignore (Llvm.build_ret (Llvm.build_extractvalue whole_bytes far "" b) b);
  let g, b = fn m "write_far" (Llvm.void_type ctx) [| ptr; i8 |] in
  ignore (Llvm.build_store (Llvm.build_insertvalue (Llvm.undef bytes) (Llvm.param g 1) far "" b) (Llvm.param g 0) b);
  ignore (Llvm.build_ret_void b);
  check "parts past 2^31 move apart" (Codegen__Big_moves.rewrite layout m = Ok ());
  let indices f =
    List.concat_map
      (fun i ->
        if Llvm.instr_opcode i = Llvm.Opcode.GetElementPtr then
          List.init (Llvm.num_operands i - 1) (fun n -> Llvm.int64_of_const (Llvm.operand i (n + 1)))
        else [])
      (instrs f)
  in
  let reaches f = List.mem (Some (Int64.of_int far)) (indices f) in
  check "the part read is found at index 2^31 + 1" (reaches f);
  check "the part stored is put at index 2^31 + 1" (reaches g);
  Llvm.dispose_module m;
  Llvm.dispose_context ctx

(* Each load and store is as aligned as its address is known to be
   (Codegen.Alignment): every rule of it, on one module, read back by the
   name each access's value or address carries. *)
let alignment () =
  let ctx = Llvm.create_context () in
  let ir =
    {|target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
@g = external global i32
declare ptr @zane_scope_enter(i64)
declare ptr @zane_list_push(ptr, i64)
declare ptr @zane_alloc(ptr, i64, i64)
declare ptr @other()
define void @f(ptr align 16 %arg, ptr %bare, i64 %i, i1 %c) {
entry:
  %slot = alloca i64, align 8
  store i64 1, ptr %slot, align 8
  %local = load i64, ptr %slot, align 8
  %glob = load i32, ptr @g, align 4
  %at4 = getelementptr i8, ptr %slot, i64 4
  %odd = load i32, ptr %at4, align 4
  %fromarg = load i64, ptr %arg, align 8
  %frombare = load i64, ptr %bare, align 8
  %blk = load ptr, ptr %arg, align 8, !align !0
  %viamd = load i64, ptr %blk, align 8
  %i8 = mul i64 %i, 8
  %scaled = getelementptr i8, ptr %blk, i64 %i8
  %stride8 = load i64, ptr %scaled, align 8
  %i3 = mul i64 %i, 3
  %scaled3 = getelementptr i8, ptr %blk, i64 %i3
  %stride3 = load i64, ptr %scaled3, align 8
  %sl = getelementptr <{ i8, i64 }>, ptr %blk, i64 0, i32 1
  %packed = load i64, ptr %sl, align 8
  %frame = call ptr @zane_scope_enter(i64 64)
  %inframe = load i64, ptr %frame, align 8
  %pushed = call ptr @zane_list_push(ptr %bare, i64 12)
  %inslot = load i64, ptr %pushed, align 8
  %alloced = call ptr @zane_alloc(ptr %bare, i64 32, i64 16)
  %inblock = load i64, ptr %alloced, align 8
  %unknown = call ptr @other()
  %inunknown = load i64, ptr %unknown, align 8
  %either = select i1 %c, ptr %slot, ptr %bare
  %inselect = load i64, ptr %either, align 8
  %held = alloca ptr, align 8
  store ptr %blk, ptr %held, align 8
  %back = load ptr, ptr %held, align 8
  %readback = load i64, ptr %back, align 8
  %atomic = load atomic i64, ptr %bare unordered, align 8
  store i64 %atomic, ptr %bare, align 8
  ret void
}
!0 = !{i64 8}
|}
  in
  let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string ir) in
  Codegen__Alignment.mark m;
  let f = Option.get (Llvm.lookup_function "f" m) in
  let loads = Hashtbl.create 16 and stores = Hashtbl.create 4 in
  Llvm.iter_blocks
    (Llvm.iter_instrs (fun i ->
         match Llvm.instr_opcode i with
         | Llvm.Opcode.Load -> Hashtbl.replace loads (Llvm.value_name i) (Llvm.alignment i)
         | Llvm.Opcode.Store -> Hashtbl.replace stores (Llvm.value_name (Llvm.operand i 1)) (Llvm.alignment i)
         | _ -> ()))
    f;
  let at name = Hashtbl.find loads name in
  check "a read from a stack slot keeps the slot's alignment" (at "local" = 8);
  check "a global declared without one is at its type's alignment" (at "glob" = 4);
  check "a constant offset keeps what divides it" (at "odd" = 4);
  check "a parameter is as aligned as its attribute says" (at "fromarg" = 8);
  check "a parameter with no attribute is at any byte" (at "frombare" = 1);
  check "a pointer read with !align is that aligned" (at "viamd" = 8);
  check "an index times 8 keeps 8" (at "stride8" = 8);
  check "an index times 3 is at any byte" (at "stride3" = 1);
  check "a member of a packed struct is at its byte" (at "packed" = 1);
  check "a frame is on 16 bytes, a type's 8 at most" (at "inframe" = 8);
  check "a pushed slot of a 12-byte stride is on 4" (at "inslot" = 4);
  check "a block is on its alignment" (at "inblock" = 8);
  check "another call's result is at any byte" (at "inunknown" = 1);
  check "a select is the least of its two" (at "inselect" = 1);
  check "a pointer read back from a slot is as aligned as what was stored" (at "readback" = 8);
  check "an atomic access keeps its alignment" (at "atomic" = 8);
  check "a store follows the same rules" (Hashtbl.find stores "slot" = 8 && Hashtbl.find stores "bare" = 1);
  let open Codegen__Alignment in
  check "a negative number's low bit is its magnitude's" (low_bit (-24L) = 8);
  check "a wrapped 2^63 is past the cap" (low_bit Int64.min_int = most);
  check "a greatest common divisor is never negative" (gcd (-12L) 8L = 4L && gcd 12L (-8L) = 4L);
  Llvm.dispose_module m;
  Llvm.dispose_context ctx

(* Non-trivial loop unswitching runs for AArch64 alone (Passes.unswitch). *)
let unswitching () =
  let on = "simple-loop-unswitch<nontrivial;trivial>" in
  let has triple =
    let p = Codegen__Passes.pipeline ~triple ~optimize:true ~tier1:false in
    let n = String.length on in
    let rec go i = i + n <= String.length p && (String.sub p i n = on || go (i + 1)) in
    go 0
  in
  check "the optimized pipeline names the pass it replaces"
    (let off = "simple-loop-unswitch<no-nontrivial;trivial>" in
     let p = Codegen__Passes.optimized in
     let n = String.length off in
     let rec go i = i + n <= String.length p && (String.sub p i n = off || go (i + 1)) in
     go 0);
  check "an AArch64 target unswitches loops"
    (has "aarch64-unknown-linux-gnu" && has "arm64-apple-macosx14.0.0" && has "arm64e-apple-macosx14.0.0");
  check "an x86-64 target does not" (not (has "x86_64-unknown-linux-gnu") && not (has "x86_64-pc-windows-gnu"));
  check "an unoptimized build does not"
    (not
       (let p = Codegen__Passes.pipeline ~triple:"aarch64-unknown-linux-gnu" ~optimize:false ~tier1:false in
        let n = String.length on in
        let rec go i = i + n <= String.length p && (String.sub p i n = on || go (i + 1)) in
        go 0))

(* A target is refused unless its pointers are 8 bytes and it aligns `i64`
   and `double` to 8 (docs/design/platforms.md). No 64-bit LLVM target
   aligns either below that, so the layouts are written out here. *)
let sixty_four_bit () =
  let accepts layout =
    Codegen__Build.sixty_four_bit "t" (Llvm_target.DataLayout.of_string layout)
  in
  check "8-byte pointers with i64 and double aligned to 8 are accepted"
    (accepts "e-m:e-p:64:64-i64:64-f64:64" = Ok ());
  check "4-byte pointers are refused"
    (accepts "e-p:32:32-i64:64-f64:64"
    = Error "the target `t` has 4-byte pointers; this compiler builds for 64-bit targets only");
  check "an i64 aligned to 4 is refused"
    (accepts "e-p:64:64-i64:32-f64:64"
    = Error "the target `t` aligns `i64` to 4 bytes; this compiler builds for 64-bit targets only");
  check "a double aligned to 4 is refused"
    (accepts "e-p:64:64-i64:64-f64:32"
    = Error "the target `t` aligns `double` to 4 bytes; this compiler builds for 64-bit targets only")

(* The runtime is compiled without clearing registers on return, and without
   frame pointers but on Apple's targets, whatever the C compiler adds by
   itself; a compiler that refuses either compiles it without them, quietly. *)
let runtime_tuning () =
  let unhardened = [ "-fzero-call-used-regs=skip"; "-fno-stack-protector"; "-fno-stack-clash-protection"; "-fno-wrapv" ] in
  check "a Linux runtime keeps no frame pointers, is not hardened, and reads its threads' variables directly"
    (Codegen__Build.tuning ~triple:"x86_64-unknown-linux-gnu" []
    = unhardened @ [ "-fomit-frame-pointer"; "-ftls-model=local-exec" ]);
  check "a Linux dynamic library's runtime keeps the initial-exec model its library flags give"
    (Codegen__Build.tuning ~triple:"x86_64-unknown-linux-gnu" (Codegen__Build.library_flags ~triple:"x86_64-unknown-linux-gnu")
    = unhardened @ [ "-fomit-frame-pointer" ]);
  check "an Apple runtime keeps its frame pointers"
    (Codegen__Build.tuning ~triple:"arm64-apple-macosx14.0.0" [] = unhardened);
  check "a Windows one keeps its threads' variables as COFF has them"
    (Codegen__Build.tuning ~triple:"x86_64-pc-windows-gnu" [] = unhardened @ [ "-fomit-frame-pointer" ]);
  if not Sys.win32 then begin
    let dir = Filename.temp_dir "zane-tuning" "" in
    let cc = Filename.concat dir "cc" and output = Filename.concat dir "zane.o" in
    (* A C compiler that refuses the tuning, and otherwise writes its output. *)
    Out_channel.with_open_text cc (fun oc ->
        output_string oc
          "#!/bin/sh\nfor a; do [ \"$a\" = -fzero-call-used-regs=skip ] && exit 1; done\n\
           while [ \"$1\" != -o ]; do shift; done; : > \"$2\"\n");
    Unix.chmod cc 0o755;
    check "a C compiler that refuses the tuning compiles the runtime without it"
      (Codegen__Build.compile ~cc ~triple:"x86_64-unknown-linux-gnu" [ "-O2" ] dir output = Ok output
      && Sys.file_exists output);
    List.iter Sys.remove [ cc; output ];
    Sys.rmdir dir
  end

(* ---------------------------------------------------------------------- *)
(* The driver                                                             *)
(* ---------------------------------------------------------------------- *)

(* A release's thunk label names its package before the verb and in each
   of the package's own types the verb names (docs/design/ffi.md F13). *)
let respelled_labels () =
  check "a package respelled throughout a symbol"
    (Rewrite.respell ~from:"v1%00%lib$" ~into:"!lib$" "v1%00%lib$next(this v1%00%lib$State).ffi"
    = "!lib$next(this !lib$State).ffi");
  check "a symbol naming no package is as it was" (Rewrite.respell ~from:"v1%00%lib$" ~into:"!lib$" "app$main()" = "app$main()");
  check "a package whose name ends another's is that other's"
    (Rewrite.respell ~from:"lib$" ~into:"!lib$" "lib$f(mylib$T)" = "!lib$f(mylib$T)")

(* Rewriting writes beside its output under a name it creates exclusively.
   A name that is already there is someone else's file: it is kept, and the
   object goes out under the next name drawn. *)

let rewriting_keeps_others_files () =
  let seed = [| 17 |] in
  let names output count =
    let random = Random.State.make seed in
    List.init count (fun _ -> Driver.temporary_name random output)
  in
  let rewrite contents = Ok (contents ^ " rewritten", 0) in
  let in_directory f =
    let directory = Filename.temp_dir "zane-rewrite" "" in
    Fun.protect ~finally:(fun () -> remove_tree directory) (fun () -> f directory)
  in
  in_directory (fun directory ->
      let input = Filename.concat directory "in.o" and output = Filename.concat directory "out.o" in
      write_all input "object";
      let first, second =
        match names output 2 with [ first; second ] -> (first, second) | _ -> assert false
      in
      write_all first "someone else's";
      let random = Random.State.make seed in
      let result = Driver.rewrite_object ~random ~stamps:[] ~rewrite ~input ~output in
      check "a rewrite whose first name is taken succeeds" (Result.is_ok result);
      check "the file at the taken name survives" (read_all first = Some "someone else's");
      check "the output is written" (read_all output = Some "object rewritten");
      check "the output went out under the next name, renamed away" (not (Sys.file_exists second));
      check "exactly two names were drawn"
        (Random.State.bits random
        = Random.State.bits
            (let r = Random.State.make seed in
             ignore (Random.State.bits r);
             ignore (Random.State.bits r);
             r)));
  in_directory (fun directory ->
      let input = Filename.concat directory "in.o" and output = Filename.concat directory "out.o" in
      write_all input "object";
      let first = List.hd (names output 1) in
      (* A symlink needs a privilege on Windows; without one there is nothing
         to test. *)
      match Unix.symlink (Filename.concat directory "nowhere") first with
      | exception Unix.Unix_error _ -> ()
      | () ->
          let result =
            Driver.rewrite_object ~random:(Random.State.make seed) ~stamps:[] ~rewrite ~input ~output
          in
          check "a rewrite whose first name is a dangling symlink succeeds" (Result.is_ok result);
          check "the dangling symlink survives"
            (match Unix.readlink first with _ -> true | exception Unix.Unix_error _ -> false);
          check "the output is written past the symlink" (read_all output = Some "object rewritten");
          Sys.remove first);
  in_directory (fun directory ->
      let input = Filename.concat directory "in.o" and output = Filename.concat directory "out.o" in
      write_all input "object";
      let taken = names output 8 in
      List.iteri (fun i name -> write_all name (string_of_int i)) taken;
      let result =
        Driver.rewrite_object ~random:(Random.State.make seed) ~stamps:[] ~rewrite ~input ~output
      in
      check "a rewrite whose eight names are all taken fails" (Result.is_error result);
      check "every taken name survives"
        (List.for_all Fun.id (List.mapi (fun i name -> read_all name = Some (string_of_int i)) taken));
      check "no output is written" (not (Sys.file_exists output)))

let contains text part =
  let n = String.length part in
  let rec go i = i + n <= String.length text && (String.sub text i n = part || go (i + 1)) in
  go 0

(* A stamp given by package name is checked as `--rewrite`'s is, so a caller
   that is not `zanec` cannot name a package's symbols with something
   lowering would not read as a stamp. *)
let stamps_are_checked () =
  let request = { Tst.Assembly.manifest_name = Some "geometry"; directory = "nowhere"; stamp = None } in
  match Driver.assemble ~root:false ~stamps:[ ("geometry", "garbage") ] [ request ] with
  | Ok _ -> check "a malformed stamp is refused" false
  | Error failure ->
      check "a malformed stamp is named as no stamp"
        (List.exists (fun line -> contains line "`garbage` is not a stamp") (Driver.render failure))

(* A control character in a file name or a message reaches the terminal as an
   escape, in every location form and in an internal error, never as itself. *)
let escaped_locations () =
  let name = "dir\027]0;title\007/a\226\128\174\t.zn" in
  let message = "unknown name `x\027[2J\t`" in
  let pos = { Lexing.pos_fname = name; pos_lnum = 1; pos_bol = 0; pos_cnum = 0 } in
  let at = Source.Span.of_loc (pos, { pos with Lexing.pos_cnum = 1 }) in
  let shown = "dir\\x1b]0;title\\x07/a\\u202e\\x09.zn" in
  let quiet text =
    String.for_all (fun c -> c = '\n' || Char.code c >= 0x20 && Char.code c < 0x7F) text
  in
  List.iter
    (fun (form, names_file, text) ->
      check (form ^ " escapes its controls") (quiet text);
      check (form ^ " shows the escaped message") (contains text "unknown name `x\\x1b[2J\\x09`");
      if names_file then check (form ^ " escapes the file name") (contains text shown))
    [
      ("a span", true, Diagnostic.render ~source:"x\n" (Diagnostic.error at message));
      ("a file", true, Diagnostic.render ~source:"" (Diagnostic.in_file name message));
      ("a directory", true, Diagnostic.render ~source:"" (Diagnostic.in_directory name message));
      ("an invocation", false, Diagnostic.render ~source:"" (Diagnostic.about_invocation message));
      ("an internal error", true, Diagnostic.render_internal ~span:at message);
    ]

(* A link that fails on a foreign verb's C function, which nothing linked
   defines, names the verb and the function, read from what GNU `ld`,
   `ld.lld` and `ld64` each write. *)
let undefined_foreign () =
  let module Build = Codegen__Build in
  let thunk = "fs$_exists(this fs$Fs, %primitives$String).ffi" in
  let expected = Some [ ("fs$_exists", "zfs_exists") ] in
  let read text =
    Option.map
      (List.filter_map (fun (s, f) ->
           if String.ends_with ~suffix:".ffi" f then Some (String.sub f 0 (String.index f '('), s) else None))
      (Some (Build.undefined_symbols text))
  in
  check "GNU ld's undefined reference names the verb"
    (read
       (Printf.sprintf
          "/usr/bin/ld: /cache/x.c.o: in function `%s':\nfs.c:(.text+0x3f6): undefined reference to `zfs_exists'\nclang: error: linker command failed with exit code 1"
          thunk)
    = expected);
  check "ld.lld's undefined symbol names the verb"
    (read
       (Printf.sprintf "ld.lld: error: undefined symbol: zfs_exists\n>>> referenced by fs.c\n>>>               /cache/x.c.o:(%s)\n" thunk)
    = expected);
  check "ld64's undefined symbol names the verb, without Mach-O's `_`"
    (match
       Build.undefined_error ~underscored:true
         (Printf.sprintf "Undefined symbols for architecture arm64:\n  \"_zfs_exists\", referenced from:\n      _%s in x.c.o\nld: symbol(s) not found for architecture arm64\n" thunk)
     with
    | Some (e, every) -> contains e "`fs$_exists` calls the C function `zfs_exists`" && every
    | None -> false);
  check "a symbol only Zane's own code references is not a foreign verb's"
    (Build.undefined_error "ld.lld: error: undefined symbol: zane_gone\n>>> referenced by program.o:(main)\n" = None);
  check "the error names the verb and its C function, which are all the link misses"
    (match Build.undefined_error (Printf.sprintf "ld.lld: error: undefined symbol: zfs_exists\n>>> referenced by x.o:(%s)\n" thunk) with
    | Some (e, every) -> contains e "`fs$_exists` calls the C function `zfs_exists`" && every
    | None -> false);
  check "a link that misses another symbol too says the verb is not all"
    (match
       Build.undefined_error
         (Printf.sprintf
            "ld.lld: error: undefined symbol: zfs_exists\n>>> referenced by x.o:(%s)\nld.lld: error: undefined symbol: other\n>>> referenced by y.o:(helper)\n"
            thunk)
     with
    | Some (_, every) -> not every
    | None -> false);
  check "ld64.lld's Mach-O names lose their `_`"
    (match
       Build.undefined_error ~underscored:true
         (Printf.sprintf "ld64.lld: error: undefined symbol: _zfs_exists\n>>> referenced by x.o:(symbol _%s+0x10)\n" thunk)
     with
    | Some (e, _) -> contains e "`fs$_exists` calls the C function `zfs_exists`"
    | None -> false);
  check "an ELF name keeps its `_`"
    (match Build.undefined_error "ld.lld: error: undefined symbol: _api\n>>> referenced by x.o:(_pkg$call.ffi)\n" with
    | Some (e, _) -> contains e "`_pkg$call` calls the C function `_api`"
    | None -> false);
  check "a parenthesis in the object's path is not the function's"
    (read
       (Printf.sprintf "ld.lld: error: undefined symbol: zfs_exists\n>>> referenced by fs.c\n>>>               /work/build(debug)/lib.a(x.c.o):(%s)\n" thunk)
    = expected);
  check "GNU ld's reference from data is not the last function's"
    (match
       Build.undefined_error
         (Printf.sprintf
            "/usr/bin/ld: x.c.o: in function `%s':\nfs.c:(.text+0x3f6): undefined reference to `zfs_exists'\n/usr/bin/ld: x.c.o:(.data.rel+0x0): undefined reference to `table'\n"
            thunk)
     with
    | Some (e, every) -> contains e "`zfs_exists`" && (not (contains e "`table`")) && not every
    | None -> false);
  check "GNU ld's reference from a function's own section is the function's"
    (read
       (Printf.sprintf "/usr/bin/ld: x.c.o: in function `%s':\nfs.c:(.text.thunk+0x3): undefined reference to `zfs_exists'\n" thunk)
    = expected);
  check "a symbol defined twice is another error"
    (Build.other_link_errors "ld.lld: error: duplicate symbol: f\n>>> defined at a.o\n");
  check "an undefined symbol and the driver's summary are no other error"
    (not
       (Build.other_link_errors
          "ld.lld: error: undefined symbol: zfs_exists\n>>> referenced by x.o:(f)\nclang: error: linker command failed with exit code 1\n"))

(* A message names a dependency's types without the stamp that distinguishes
   its versions, unless it names two versions of one package. *)
let unstamped_messages () =
  let shown message = Diagnostic.render ~source:"" (Diagnostic.about_invocation message) in
  check "a stamp is left out"
    (contains (shown "`v0.8%f35c10ff8d86c042%core$String` crosses into C as no C type")
       "Error: `core$String` crosses into C");
  check "every stamp of one version is left out"
    (shown "no `f` accepts (v1.2-rc.1%0123456789abcdef%core$Int, v1.2-rc.1%0123456789abcdef%core$Float)"
    = "Error: no `f` accepts (core$Int, core$Float)\n");
  check "two versions of one package keep their stamps"
    (contains (shown "v1%0123456789abcdef%core$Int is not v2%fedcba9876543210%core$Int")
       "v1%0123456789abcdef%core$Int is not v2%fedcba9876543210%core$Int");
  check "text that only looks like a stamp is kept"
    (contains (shown "50%0123456789abcdef% done; %primitives$String") "50%0123456789abcdef% done; %primitives$String")

(* tests/gen/gen_rules.ml stops at a fixture with no golden file and at a
   golden file whose fixture is gone, naming each, so neither leaves a
   program silently untested. *)
let fixture_pairing () =
  let module P = Fixture_pairing in
  let check_pairs ?hand_written name suite ~fixtures ~goldens expected =
    let errors = P.check ?hand_written suite ~fixtures ~goldens in
    check name (errors = expected);
    if errors <> expected then List.iter (Printf.printf "  got: %s\n") errors
  in
  check_pairs "paired codegen fixtures pass" P.Codegen
    ~fixtures:[ "fixtures/hello"; "fixtures/reject/flow" ]
    ~goldens:[ "hello.cgt"; "hello.optimized.cgt"; "hello.out"; "reject.flow.err" ]
    [];
  check_pairs "an orphan fixture and an orphan golden are both named" P.Codegen
    ~fixtures:[ "fixtures/hello"; "fixtures/untested" ]
    ~goldens:[ "hello.out"; "gone.out" ]
    [ "golden/gone.out is for fixtures/gone, which does not exist"; "fixtures/untested has no golden file" ];
  check_pairs "a golden file no rule makes is named" P.Codegen ~fixtures:[ "fixtures/hello" ]
    ~goldens:[ "hello.out"; "hello.txt" ]
    [ "no rule makes golden/hello.txt" ];
  check_pairs "a parser rejection pairs with its source" P.Parser
    ~fixtures:[ "fixtures/main.zn"; "fixtures/reject/lexing.zn"; "fixtures/reject/lost.zn" ]
    ~goldens:[ "main.cst.spans"; "reject.lexing.err"; "reject.syntax.err" ]
    [
      "golden/reject.syntax.err is for fixtures/reject/syntax.zn, which does not exist";
      "fixtures/reject/lost.zn has no golden file";
    ];
  check_pairs "a C interface package codegen refuses pairs with its error" P.Ffi
    ~fixtures:[ "fixtures/reject/sharedState" ]
    ~goldens:[ "reject.sharedState.ll.err" ] [];
  check_pairs "a C interface build linked against releases pairs with its fixture" P.Ffi
    ~fixtures:[ "fixtures/archives" ]
    ~goldens:[ "archives.out"; "archives.released.out"; "gone.released.out" ]
    [ "golden/gone.released.out is for fixtures/gone, which does not exist" ];
  check_pairs "a runtime test pairs with its output" P.Runtime ~fixtures:[ "arenas.c"; "texts.c" ]
    ~goldens:[ "arenas.out" ] [ "texts.c has no golden file" ];
  check_pairs "hand-written semantics rules are left alone" P.Semantics
    ~hand_written:[ "assembly.accept.packages"; "project.app.check" ]
    ~fixtures:[ "fixtures/typing/accept" ]
    ~goldens:[ "assembly.accept.packages"; "project.app.check"; "typing.accept.tst.spans" ]
    [];
  check_pairs "a golden file no hand-written rule compares against is named" P.Semantics
    ~hand_written:[ "project.app.check" ]
    ~fixtures:[] ~goldens:[ "project.app.check"; "project.app.chek" ]
    [ "no rule makes golden/project.app.chek" ]

(* Statements leave when one returns or leaves an expansion they are not
   inside (Cgt.Traverse.leaves). *)
let traverse_leaves () =
  let module C = Cgt.Nodes in
  let e node ty = { C.Expr.node; ty } in
  let expand label body = C.Stat.Eval (e (C.Expr.Expand { label; body; result = None }) C.Ty.Void) in
  check "a leave of an expansion inside does not leave" (not (Cgt.Traverse.leaves [ expand 5 [ C.Stat.Leave 5 ] ]));
  check "a leave of an expansion around them does" (Cgt.Traverse.leaves [ expand 5 [ C.Stat.Leave 6 ] ]);
  check "a return does" (Cgt.Traverse.leaves [ expand 5 [ C.Stat.Return (e C.Expr.Unit C.Ty.Void) ] ])

(* A scope whose body stores an address as a 32-bit reference is not light:
   with frame references, a slot on the machine stack is out of the
   reference's reach. *)
let light_references () =
  let module C = Cgt.Nodes in
  let e node ty = { C.Expr.node; ty } in
  let stored = C.Stat.Let { id = 3; value = e (C.Expr.Convert (e (C.Expr.Address 2) C.Ty.Ptr)) C.Ty.Ref } in
  let scalar = C.Stat.Let { id = 3; value = e (C.Expr.Int 1L) C.Ty.I64 } in
  let on = Sys.getenv_opt "ZANE_LIGHT_SCOPES" <> Some "0" in
  check "a scope of scalars is light, unless switched off" (Codegen__Loop_shapes.light 1 [ scalar ] = on);
  check "not when it stores a reference" (Codegen__Loop_shapes.light 1 [ stored ] = (on && not (Cgt.Ref32.frames ())))

(* Range checks' exit rule reads a counter's incoming values only once the
   counter is known to be a phi: an exit-shaped test of a function's
   argument, `(a + 1) == n >> 3` ending a block, is left as it is. *)
let range_checks_non_phi () =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "exits" in
  let i64 = Llvm.i64_type ctx in
  let f = Llvm.define_function "f" (Llvm.function_type (Llvm.void_type ctx) [| i64; i64 |]) m in
  let entry = Llvm.entry_block f in
  let stop = Llvm.append_block ctx "stop" f and go = Llvm.append_block ctx "go" f in
  let b = Llvm.builder_at_end ctx entry in
  let x = Llvm.build_add (Llvm.param f 0) (Llvm.const_int i64 1) "" b in
  let e = Llvm.build_lshr (Llvm.param f 1) (Llvm.const_int i64 3) "" b in
  let c = Llvm.build_icmp Llvm.Icmp.Eq x e "" b in
  ignore (Llvm.build_cond_br c stop go b);
  Llvm.position_at_end stop b;
  ignore (Llvm.build_ret_void b);
  Llvm.position_at_end go b;
  ignore (Llvm.build_ret_void b);
  let ran = match Codegen__Range_checks.run m with () -> true | exception _ -> false in
  check "range checks leave an exit-shaped test of an argument alone"
    (ran && Llvm.operand (Option.get (Llvm.block_terminator entry)) 0 == c);
  Llvm.dispose_module m;
  Llvm.dispose_context ctx

(* The OCaml sources under [dir], at any depth. *)
let rec sources dir =
  Array.fold_left
    (fun acc name ->
      let path = Filename.concat dir name in
      if Sys.is_directory path then sources path @ acc
      else if Filename.check_suffix name ".ml" then path :: acc
      else acc)
    [] (Sys.readdir dir)

(* An empty array codegen reads from LLVM (a function's attributes at a
   parameter that has none, an empty struct's element types) is OCaml's
   own empty array, so a minor collection, which moves young blocks, leaves
   it and the blocks made around it as they were. The bindings' own
   readers make a zero-sized young block, which each collection moves as
   if it had a field, overwriting the word after it (llvm_stubs.c), so
   codegen calls only Llvm_extra's: frame shadow once read every call's
   parameters' attributes through the bindings, and tier 1 of `byteSets`
   crashed in CI. *)
let empty_binding_arrays () =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "empty" in
  let i64 = Llvm.i64_type ctx in
  let f = Llvm.define_function "f" (Llvm.function_type (Llvm.void_type ctx) [| i64; i64 |]) m in
  let empty = Llvm.struct_type ctx [||] in
  let made = ref [] in
  for k = 1 to 20_000 do
    let attrs = Codegen__Llvm_extra.function_attrs f (Llvm.AttrIndex.Param (k mod 2)) in
    let types = Codegen__Llvm_extra.struct_element_types empty in
    let params = Codegen__Llvm_extra.param_types (Llvm.function_type (Llvm.void_type ctx) [||]) in
    made := (attrs, types, params, ref k) :: !made
  done;
  Gc.minor ();
  Gc.full_major ();
  let intact =
    List.for_all
      (fun (attrs, types, params, k) ->
        Array.length attrs = 0 && Array.length types = 0 && Array.length params = 0 && !k >= 1 && !k <= 20_000)
      !made
  in
  check "empty arrays read from LLVM survive a collection" intact;
  Llvm.dispose_module m;
  Llvm.dispose_context ctx;
  (* No compiler source reads them through the bindings. *)
  let raw = [ "Llvm.function_attrs"; "Llvm.struct_element_types"; "Llvm.param_types" ] in
  List.iter
    (fun path ->
      match read_all path with
      | Some text ->
          List.iter
            (fun word -> check (Printf.sprintf "%s calls %s, not Llvm_extra's" path word) (not (contains text word)))
            raw
      | None -> ())
    (sources "../../lib")

(* No compiler source disposes an LLVM context except through
   Contexts.dispose, which collects the heap first, so a builder made at an
   instruction with a debug location is finalized while the context that
   owns the location lives (lib/codegen/contexts.ml).
   tests/runtime/valgrind_test.py runs builder_after_context.ml under
   Valgrind to show the collection does that. *)
let contexts_disposed_after_collection () =
  List.iter
    (fun path ->
      match read_all path with
      | Some text when Filename.basename path <> "contexts.ml" ->
          check (Printf.sprintf "%s calls Llvm.dispose_context, not Contexts.dispose" path)
            (not (contains text "Llvm.dispose_context"))
      | _ -> ())
    (sources "../../lib")

let () =
  ty ();
  Traversals.run check;
  signatures ();
  overloads ();
  string_constructors ();
  intrinsic_descriptions ();
  type_layout ();
  Member_order.run ();
  alignment ();
  unswitching ();
  growing_types ();
  fixpoint_chain ();
  runtime_abi ();
  runtime_facts ();
  probed_abi ();
  Evaluation.run ();
  twice ();
  at_once ();
  snapshot_reads ();
  unroll_marks ();
  shared_walks ();
  target_cpus ();
  sixty_four_bit ();
  runtime_tuning ();
  checked_sizes ();
  long_arrays ();
  counted_pieces ();
  passings ();
  returnings ();
  backstop ();
  parts_apart ();
  fixture_pairing ();
  escaped_locations ();
  unstamped_messages ();
  undefined_foreign ();
  Builds.cached_runtime ();
  Builds.linked_in_process ();
  Builds.bundled_runtime ();
  Builds.host_spelling ();
  Builds.released_toolchain ();
  Builds.runtime_bodies ();
  Builds.fatal_link ();
  Builds.assembled_beside ();
  Foreign_c.run ();
  C_eval.run ();
  respelled_labels ();
  rewriting_keeps_others_files ();
  stamps_are_checked ();
  disposed_modules ();
  repeated_builds ();
  Loops.looped_pushes ();
  Loops.list_pure ();
  Loops.invariant_lists ();
  Loops.searches ();
  Loops.leaf_peel ();
  Loops.strip_steps ();
  traverse_leaves ();
  light_references ();
  empty_binding_arrays ();
  contexts_disposed_after_collection ();
  range_checks_non_phi ();
  if !failures > 0 then begin
    Printf.printf "%d failed\n" !failures;
    exit 1
  end

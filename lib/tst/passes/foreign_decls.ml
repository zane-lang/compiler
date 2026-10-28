(* The C interface's declarations, checked once every signature is known
   (spec ffi.md §3, §4, docs/design/ffi.md F7): each foreign handle's C type
   and C functions, each handle type's kind, and each foreign verb against
   the declaration of its C function in its package's interface headers, as
   the build's target sees them.

   Pass 4 runs this last, since a handle's kind is read from the foreign
   verbs that return it, and a verb's handles are checked against their
   kinds. What it learns goes into pass 4's tables: each handle type's kind,
   and each foreign verb's C function and what it reads and writes outside
   the program (§5.2). A foreign variable, which is a value, is checked in
   pass 5 through [global]. *)

open Env
module N = Sst.Nodes
module S = Signature
module C = C_interface
module F = Nodes.Foreign

let interface env pkg = Option.value ~default:C.empty (Hashtbl.find_opt env.interfaces pkg)

(* ---------------------------------------------------------------------- *)
(* Handles                                                                *)
(* ---------------------------------------------------------------------- *)

(* The foreign handle a type names, as written in a foreign verb: bare,
   or the `^` of a result. *)
let handle_of env (t : Ty.t) =
  match Ty.strip_mode t with
  | Ty.Named (tid, []) -> (
      match Type_decls.type_info_of_id env tid with
      | Some { definition = Some (Handle h); _ } -> Some (tid, h)
      | _ -> None)
  | _ -> None

let is_capability (h : Nodes.Handle.t) = h.Nodes.Handle.free = None

(* The struct a handle's `cType` names in [iface]: a typedef of a struct, or
   a struct an interface header declares, completely or not (§4.1). *)
let record_of iface c_type =
  match List.assoc_opt c_type iface.C.typedefs with
  | Some (C.Record { union = false; name }) -> Some name
  | Some _ -> None
  | None -> (
      match List.assoc_opt c_type iface.C.records with
      | Some { C.union = false; declared = true; _ } -> Some c_type
      | _ -> None)

(* A pointer to [record], `const` or not. *)
let pointer_to ~const record = C.Pointer { const; pointee = C.Record { union = false; name = record } }

(* ---------------------------------------------------------------------- *)
(* The foreign verbs of the build                                         *)
(* ---------------------------------------------------------------------- *)

(* A foreign verb: its declaration, its C symbol, where its parameters and
   result are written, and its signature. *)
type verb = {
  decl : decl;
  symbol : N.Name.t;
  this_span : Span.t option;
  param_spans : Span.t list;
  ret : N.Ret_type.t;
  signature : S.t;
}

let foreign_verbs env =
  List.concat_map
    (fun pkg_name ->
      List.filter_map
        (fun (d : decl) ->
          let found symbol this_span params ret =
            Option.map
              (fun signature ->
                {
                  decl = d;
                  symbol;
                  this_span;
                  param_spans = List.map (fun (p : N.Param.t) -> p.N.Param.type_.N.Param_type.span) params;
                  ret;
                  signature;
                })
              (Verbs.signature env.verbs d.id)
          in
          match d.kind with
          | Verb { N.Verb_decl.node = N.Verb_decl.Func { foreign = Some symbol; params; ret_type; _ }; _ } ->
              found symbol None params ret_type
          | Verb { N.Verb_decl.node = N.Verb_decl.Meth { foreign = Some symbol; this_type; params; ret_type; _ }; _ } ->
              found symbol (Some this_type.N.Type_expr.span) params ret_type
          | _ -> None)
        (List.rev (package env pkg_name).decls))
    (Names.package_order env.names)

(* The verb's subject's handle, when it is a method on one. *)
let subject_handle env (v : verb) =
  match (v.signature.S.kind, v.signature.S.params) with
  | S.Method, this_ :: _ -> handle_of env this_.S.ty
  | _ -> None

let on_capability env v =
  match subject_handle env v with Some (_, h) -> is_capability h | None -> false

(* ---------------------------------------------------------------------- *)
(* Kinds                                                                  *)
(* ---------------------------------------------------------------------- *)

(* Each handle type's kind (§4.1, §4.2): a capability when it has no free
   function; otherwise outside state when the foreign verbs that make it
   are methods on a foreign capability, and program state when none are. A
   type some of whose makers are and some are not is both, and refused. *)
let kinds env (tables : verbs) verbs =
  Types.fold_type_infos
    (fun _ (info : type_info) () ->
      match info.definition with
      | Some (Handle h) when is_capability h -> Hashtbl.replace tables.handle_kinds info.tid Nodes.Decl.Capability
      | Some (Handle _) ->
          let makers =
            List.filter
              (fun v -> match handle_of env v.signature.S.ret with Some (tid, _) -> tid = info.tid | None -> false)
              verbs
          in
          let outside, data = List.partition (on_capability env) makers in
          let kind =
            match (outside, data) with
            | _ :: _, [] -> Nodes.Decl.Outside
            | [], _ -> Nodes.Decl.Data
            | o :: _, d :: _ ->
                error env info.decl.span
                  (Printf.sprintf
                     "%s is made by %s, a method on a foreign capability, and by %s, which is not one: \
                      the handle would be outside state and program state at once (ffi.md §4.2)"
                     (quote info.tid.Ty.name) (quote o.signature.S.name) (quote d.signature.S.name));
                Nodes.Decl.Data
          in
          Hashtbl.replace tables.handle_kinds info.tid kind
      | _ -> ())
    env.types ()

(* ---------------------------------------------------------------------- *)
(* A handle's C type and C functions                                      *)
(* ---------------------------------------------------------------------- *)

(* `cType` names a struct an interface header declares, and `free` and
   `set` C functions of the interface headers that take non-`const`
   pointers to it and return nothing (§4.1). *)
let check_handle env (info : type_info) (h : Nodes.Handle.t) =
  let iface = interface env info.decl.package in
  let at = info.decl.span in
  match record_of iface h.Nodes.Handle.c_type with
  | None ->
      (* A `cType` that is no C name is reported where it is written. *)
      if Type_decls.is_c_identifier h.Nodes.Handle.c_type then
        error env at
          (Printf.sprintf
             "no interface header of %s declares %s as a struct, or as a typedef of one, which a handle's \
              `cType` names (ffi.md §4.1)"
             (quote info.decl.package) (quote h.Nodes.Handle.c_type))
  | Some record ->
      let check role name arity =
        let writable = pointer_to ~const:false record in
        let expected = C.Function { params = List.init arity (fun _ -> writable); result = C.Void; variadic = false } in
        match List.assoc_opt name iface.C.functions with
        | None ->
            error env at
              (Printf.sprintf "no interface header of %s declares the %s %s as a function (ffi.md §4.1)"
                 (quote info.decl.package) role (quote name))
        | Some f when f.C.ty <> expected ->
            error env at
              (Printf.sprintf "the %s %s is %s; it takes %s and returns `void` (ffi.md §4.1)" role (quote name)
                 (quote (C.to_string f.C.ty))
                 (if arity = 1 then "one non-`const` pointer to the handle's C type"
                  else "two non-`const` pointers to the handle's C type"))
        | Some _ -> ()
      in
      Option.iter (fun f -> check "free function" f 1) h.Nodes.Handle.free;
      Option.iter (fun s -> check "setter" s 2) h.Nodes.Handle.set

(* ---------------------------------------------------------------------- *)
(* Types at the boundary                                                  *)
(* ---------------------------------------------------------------------- *)

type scalar = I32 | I64 | F32 | F64

(* What a Zane type crosses into C as (§3.3). *)
type crossing =
  | Scalar of scalar
  | Bool
  | Unit
  | Bytes
  | Array of scalar * int
  | Span of scalar
  | Value of Ty.type_id * (string * Ty.t) list
  | Handle of Ty.type_id * Nodes.Handle.t
  | Function of Ty.verb

let scalar_of = function
  | Ty.Intrinsic { namespace = "primitives"; name = "I32"; args = [] } -> Some I32
  | Ty.Intrinsic { namespace = "primitives"; name = "I64"; args = [] } -> Some I64
  | Ty.Intrinsic { namespace = "primitives"; name = "F32"; args = [] } -> Some F32
  | Ty.Intrinsic { namespace = "primitives"; name = "F64"; args = [] } -> Some F64
  | _ -> None

let scalar_name = function I32 -> "@primitives$I32" | I64 -> "@primitives$I64" | F32 -> "@primitives$F32" | F64 -> "@primitives$F64"

(* A value type declared with `struct` whose fields are scalars, arrays of
   them, or such structs in turn: a C-compatible value type (§3.3), with its
   fields' types. *)
let rec value_struct env ?(depth = 0) (t : Ty.t) =
  match t with
  | Ty.Named (tid, args) when depth < 16 -> (
      match Type_decls.type_info_of_id env tid with
      | Some ({ definition = Some (Struct fields); reference = Some false; _ } as info) ->
          let s = Ty.bindings info.params args in
          let fields = List.map (fun (n, f) -> (n, Ty.subst s f)) fields in
          if List.for_all (fun (_, f) -> field_compatible env ~depth f) fields then Some (tid, fields) else None
      | _ -> None)
  | _ -> None

and field_compatible env ~depth t =
  Option.is_some (scalar_of t) || Option.is_some (array_of t) || Option.is_some (value_struct env ~depth:(depth + 1) t)

and array_of = function
  | Ty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Ty.Type e; Ty.Number (Ty.Known n) ] } ->
      Option.map (fun s -> (s, n)) (scalar_of e)
  | _ -> None

let list_of = function
  | Ty.Intrinsic { namespace = "primitives"; name = "List"; args = [ Ty.Type e ] } -> scalar_of e
  | _ -> None

let crossing env (t : Ty.t) =
  match t with
  | Ty.Intrinsic { namespace = "primitives"; name = "Bool"; args = [] } -> Some Bool
  | Ty.Intrinsic { namespace = "primitives"; name = "Unit"; args = [] } -> Some Unit
  | Ty.Intrinsic { namespace = "primitives"; name = "String"; args = [] } -> Some Bytes
  | Ty.Verb v -> Some (Function v)
  | t -> (
      match (scalar_of t, array_of t, list_of t, value_struct env t, handle_of env t) with
      | Some s, _, _, _, _ -> Some (Scalar s)
      | _, Some (s, n), _, _, _ -> Some (Array (s, n))
      | _, _, Some s, _, _ -> Some (Span s)
      | _, _, _, Some (tid, fields), _ -> Some (Value (tid, fields))
      | _, _, _, _, Some (tid, h) -> Some (Handle (tid, h))
      | _ -> None)

(* Whether [c] is one of a scalar's full-width C types (§3.3): those of its
   own size, which alone lay out as it does. A standard typedef is matched
   by its name, so `int64_t` is one where it is a `long`. *)
let full_width scalar (c : C.ctype) =
  let named standard_names names standard name = (match standard with Some s -> List.mem s standard_names | None -> false) || List.mem name names in
  match (scalar, c) with
  | I32, C.Int { size = 32; width = 32; name; standard; _ } ->
      named [ "int32_t"; "uint32_t" ] [ "int"; "unsigned int" ] standard name
  | I64, C.Int { size = 64; width = 64; name; standard; _ } ->
      named
        [ "int64_t"; "uint64_t"; "size_t"; "ptrdiff_t"; "intptr_t"; "uintptr_t" ]
        [ "long long"; "unsigned long long" ] standard name
  | F32, C.Float { size = 32; ieee = true; name = "float" } | F64, C.Float { size = 64; ieee = true; name = "double" } -> true
  | _ -> false

(* A C type narrower than 32 bits that `@primitives$I32` crosses as: its
   low bits when passed, widened by the C type's sign when returned. *)
let narrow_i32 (c : C.ctype) =
  match c with
  | C.Int { size; width; name; standard; _ } when size <= 32 && width = size ->
      (match standard with Some s -> List.mem s [ "int8_t"; "uint8_t"; "int16_t"; "uint16_t" ] | None -> false)
      || List.mem name [ "char"; "signed char"; "unsigned char"; "short"; "unsigned short" ]
  | _ -> false

(* The layout of a C-compatible value type as lowering lays it out: each
   field at the next offset its alignment allows, the whole rounded up to
   its largest alignment ([value_struct] has already found every field
   crosses). Sizes in bytes. *)
let scalar_layout = function I32 | F32 -> (4, 4) | I64 | F64 -> (8, 8)

let rec layout env (t : Ty.t) =
  match (scalar_of t, array_of t, value_struct env t) with
  | Some s, _, _ -> scalar_layout s
  | _, Some (s, n), _ ->
      let size, align = scalar_layout s in
      (size * n, align)
  | _, _, Some (_, fields) ->
      let _, size, align = field_offsets env fields in
      (size, align)
  | _ -> (0, 1)

and field_offsets env fields =
  let round n a = (n + a - 1) / a * a in
  let offsets, next, align =
    List.fold_left
      (fun (offsets, next, align) (_, t) ->
        let size, a = layout env t in
        let at = round next a in
        (at :: offsets, at + size, max align a))
      ([], 0, 1) fields
  in
  (List.rev offsets, round next align, align)

(* Whether a C-compatible value type's fields lay out as [record]'s do:
   the same number, in order, each of a full-width C type of the Zane
   field's scalar, an array of one, or a struct corresponding in turn, at
   the same offset, and the two the same size. A struct with a bit-field
   corresponds to none (docs/design/ffi.md F6). *)
let rec struct_matches env iface fields record =
  match List.assoc_opt record iface.C.records with
  | Some { C.union = false; layout = Some l; _ } ->
      let offsets, size, _ = field_offsets env fields in
      List.length fields = List.length l.C.fields
      && size * 8 = l.C.size
      && List.for_all2
           (fun ((_, t), offset) (cf : C.field) ->
             cf.C.bit_width = None && cf.C.offset = offset * 8 && field_matches env iface t cf.C.ty)
           (List.combine fields offsets) l.C.fields
  | _ -> false

and field_matches env iface t (c : C.ctype) =
  match (scalar_of t, array_of t, value_struct env t, c) with
  | Some s, _, _, c -> full_width s c
  | _, Some (s, n), _, C.Array { count; element } -> count = n && full_width s element
  | _, _, Some (_, fields), C.Record { union = false; name } -> struct_matches env iface fields name
  | _ -> false

(* ---------------------------------------------------------------------- *)
(* Checking one foreign verb                                              *)
(* ---------------------------------------------------------------------- *)

(* Where a type stands in a foreign verb, which decides what crosses there
   and how C may use a handle (§3.5, §4.4). *)
type position = Subject | Param | Result

(* A C type with no Zane type at all (§3.3): one whose size differs
   between targets, a variadic, and every other the table leaves out. *)
let unsupported_hint (c : C.ctype) =
  match c with
  | C.Int { name = "long" | "unsigned long" | "wchar_t"; standard = None; _ } | C.Float { ieee = false; _ } ->
      Printf.sprintf "; %s has a size that differs between targets, so it corresponds to no Zane type: reach it through a C function of the package that converts it"
        (quote (C.to_string c))
  | _ -> ""

(* What C receives for a handle at [position] (§4.2, §4.4): a writable
   pointer or a `const` one, or [Error] when the handle may not stand
   there. *)
let handle_pointer env (v : verb) kind position =
  let mut = v.signature.S.is_mut in
  match (kind, position) with
  | Nodes.Decl.Capability, Subject -> Ok (not mut)
  (* Returning one is refused on its own ([check_maker]). *)
  | Nodes.Decl.Capability, Result -> Ok false
  | Nodes.Decl.Capability, Param ->
      Error "a foreign capability stands in a foreign verb only as the subject of a method (ffi.md §4.4)"
  | Nodes.Decl.Outside, Subject ->
      Error "an outside handle is no subject of a foreign verb; it is passed to a method on the foreign capability that reaches its state (ffi.md §4.4)"
  | Nodes.Decl.Outside, Param when not (on_capability env v) ->
      Error "an outside handle is passed only to a method on a foreign capability, which reaches its state (ffi.md §4.4)"
  | Nodes.Decl.Outside, Param -> Ok (not mut)
  | (Nodes.Decl.Outside | Nodes.Decl.Data), Result -> Ok false
  | Nodes.Decl.Data, Subject -> Ok (not mut)
  | Nodes.Decl.Data, Param -> Ok true

(* Whether the Zane type [t] at [position] corresponds to the C type [c],
   as [Error] with why when it does not. *)
let rec corresponds env iface (v : verb) position (t : Ty.t) (c : C.ctype) =
  let differ what = Error (Printf.sprintf "C declares %s here, and %s%s" (quote (C.to_string c)) what (unsupported_hint c)) in
  match crossing env t with
  | None ->
      Error
        (Printf.sprintf "%s crosses into C as no C type: the types a foreign verb takes and gives are listed in ffi.md §3.3"
           (quote (Ty.to_string t)))
  | Some (Scalar s) ->
      if full_width s c || (s = I32 && narrow_i32 c) then Ok ()
      else
        Error
          (Printf.sprintf "C declares %s here, which is not one of %s's C types (ffi.md §3.3)%s" (quote (C.to_string c))
             (quote (scalar_name s)) (unsupported_hint c))
  | Some Bool -> if c = C.Bool then Ok () else differ "`@primitives$Bool` crosses as `bool`"
  | Some Unit when position = Result -> if c = C.Void then Ok () else differ "`@primitives$Unit` crosses as `void`"
  | Some Unit -> Error "`@primitives$Unit` crosses into C only as a result, `void`"
  | Some Bytes -> (
      match c with
      | C.Record { union = false; name = "zane_bytes" } -> Ok ()
      | _ -> differ "`@primitives$String` crosses as a `zane_bytes`")
  | Some (Array (s, n)) when position = Param -> (
      match c with
      | C.Pointer { const = true; pointee } when full_width s pointee -> Ok ()
      | _ ->
          differ
            (Printf.sprintf "`@primitives$Array<%s, %d>` crosses as a `const` pointer to a full-width C type of its element"
               (scalar_name s) n))
  | Some (Span _) when position = Param -> (
      match c with
      | C.Record { union = false; name = "zane_span" } -> Ok ()
      | _ -> differ "a `@primitives$List` crosses as a `zane_span`")
  | Some (Array _ | Span _) -> Error "an array and a list cross into C only as parameters (ffi.md §3.5)"
  | Some (Value (_, fields)) -> (
      match c with
      | C.Record { union = false; name } when struct_matches env iface fields name -> Ok ()
      | C.Record { union = false; name } ->
          Error
            (Printf.sprintf "%s and the C struct %s are laid out differently: a C-compatible value type's C struct has the same fields, in order, each of a full-width C type of the Zane field's, at the same offsets (ffi.md §3.3)"
               (quote (Ty.to_string t)) (quote name))
      | _ -> differ (Printf.sprintf "%s crosses as a C struct of the same layout" (quote (Ty.to_string t))))
  | Some (Handle (tid, h)) -> handle_corresponds env iface v position tid h c
  | Some (Function f) when position = Param -> function_corresponds env iface v f c
  | Some (Function _) -> Error "a function value crosses into C only as a parameter (ffi.md §3.5)"

and handle_corresponds env iface v position tid (h : Nodes.Handle.t) c =
  let kind = Option.value ~default:Nodes.Decl.Data (Verbs.handle_kind env.verbs tid) in
  match handle_pointer env v kind position with
  | Error why -> Error why
  | Ok const -> (
      let record = record_of (interface env tid.Ty.package) h.Nodes.Handle.c_type in
      let names_it pointee = match (pointee, record) with C.Record { union = false; name }, Some r -> name = r | _ -> false in
      ignore iface;
      match c with
      | C.Pointer { const = c_const; pointee } when names_it pointee ->
          if c_const = const then Ok ()
          else if const then
            Error
              (Printf.sprintf "C receives a `const` pointer to %s here, since a foreign verb writes the object only as the subject of a `mut` method (ffi.md §4.4), and C declares %s"
                 (quote h.Nodes.Handle.c_type) (quote (C.to_string c)))
          else
            Error
              (Printf.sprintf "C receives a writable pointer to %s here (ffi.md §4.2, §4.4), and C declares %s"
                 (quote h.Nodes.Handle.c_type) (quote (C.to_string c)))
      | _ ->
          Error
            (Printf.sprintf "%s crosses as a pointer to its C type %s, and C declares %s"
               (quote tid.Ty.name) (quote h.Nodes.Handle.c_type) (quote (C.to_string c))))

(* A function value crosses as a C function pointer (§3.6) when it has no
   subject and no abort type, and its parameters are scalars, `Bool` or
   C-compatible value types, and its result one of those or `Unit`. *)
and function_corresponds env iface v (f : Ty.verb) c =
  let plain t = match crossing env t with Some (Scalar _ | Bool | Value _) -> true | _ -> false in
  let result t = plain t || crossing env t = Some Unit in
  if f.Ty.this_ <> None || f.Ty.abort <> None || not (List.for_all plain f.Ty.params && result f.Ty.ret) then
    Error
      "a function value crosses into C when it has no subject and no abort type, and takes scalars, `@primitives$Bool` or C-compatible value types, and gives one of those or `@primitives$Unit` (ffi.md §3.6)"
  else
    match c with
    | C.Pointer { pointee = C.Function { params; result = r; variadic = false }; _ }
      when List.length params = List.length f.Ty.params -> (
        let checks =
          List.map2 (fun t p -> corresponds env iface v Param t p) f.Ty.params params @ [ corresponds env iface v Result f.Ty.ret r ]
        in
        match List.find_opt Result.is_error checks with Some e -> e | None -> Ok ())
    | _ ->
        Error
          (Printf.sprintf "a function value crosses as a pointer to a C function of the same parameters and result, and C declares %s"
             (quote (C.to_string c)))

let ret_span (v : verb) =
  match v.ret.N.Ret_type.node with N.Ret_type.Safe t | N.Ret_type.Abort { ok = t; _ } -> t.N.Type_expr.span

(* §3.1, §3.5: a foreign verb takes no type or number parameter, no
   concept-typed parameter and no block; a `^` result is the only one a
   reference type is given as, and only a handle result declares an abort
   type, `@primitives$Unit`. *)
let check_form env (v : verb) =
  let s = v.signature in
  let at = v.decl.span in
  if s.S.generics <> [] then error env at "a foreign verb takes no type or number parameter (ffi.md §3.1)";
  List.iter2
    (fun (p : S.param) span ->
      match p.S.ty with
      | Ty.Concept _ -> error env span "a foreign verb takes no concept-typed parameter and no block (ffi.md §3.1)"
      | Ty.Reference _ | Ty.Roaming _ ->
          error env span "a foreign verb's parameter is written bare: C borrows what it is passed (ffi.md §3.4, §4.4)"
      | _ -> ())
    (match s.S.kind with S.Method -> List.tl s.S.params | _ -> s.S.params)
    v.param_spans;
  let handle_result = Option.is_some (handle_of env s.S.ret) in
  (match (s.S.ret, handle_result) with
  | Ty.Reference _, _ -> error env (ret_span v) "a foreign verb returns a handle as a new roaming owner, written `^` (ffi.md §3.5)"
  | _ -> ());
  match s.S.abort with
  | None -> ()
  | Some (Ty.Intrinsic { namespace = "primitives"; name = "Unit"; args = [] }) when handle_result -> ()
  | Some _ when handle_result ->
      error env (ret_span v) "a foreign verb that returns a handle aborts with `@primitives$Unit`, when the C function returns a null pointer (ffi.md §3.5)"
  | Some _ ->
      error env (ret_span v)
        "only a foreign verb that returns a handle declares an abort type: a C function signals failure through its result, and the package's Zane code turns that into an abort (ffi.md §3.5)"

(* §4.2, §5.3: no foreign verb returns a foreign capability, and one that
   returns an outside handle is a `mut` method on a foreign capability. *)
let check_maker env (v : verb) =
  match handle_of env v.signature.S.ret with
  | Some (_, h) when is_capability h ->
      error env (ret_span v) "no foreign verb returns a foreign capability: one is made only by a foreign variable (ffi.md §4.2)"
  | Some (tid, _) -> (
      match Verbs.handle_kind env.verbs tid with
      | Some Nodes.Decl.Outside when not (on_capability env v && v.signature.S.is_mut) ->
          error env v.decl.span
            (Printf.sprintf "%s is an outside handle, which only a `mut` method on a foreign capability makes: opening one is a write to outside state (ffi.md §5.3)"
               (quote tid.Ty.name))
      | _ -> ())
  | None -> ()

(* The verb against its C function's declaration (§3.7). *)
let check_against_c env (v : verb) =
  let iface = interface env v.decl.package in
  let s = v.signature in
  let symbol = v.symbol.N.Name.text in
  let at = v.symbol.N.Name.span in
  if not (Type_decls.is_c_identifier symbol) then begin
    error env at (Printf.sprintf "%s is not a C name: a foreign verb names its C function's symbol" (quote symbol));
    None
  end
  else
    match List.assoc_opt symbol iface.C.functions with
    | None ->
        error env at
          (Printf.sprintf "no interface header of %s declares %s as a function: a foreign verb names a C function its package's `.h` files declare (ffi.md §3.7)"
             (quote v.decl.package) (quote symbol));
        None
    | Some { C.ty = C.Unprototyped _; _ } ->
        error env at
          (Printf.sprintf "%s is declared without a prototype, which gives no parameter types to check; declare it as `(void)` or with its parameters"
             (quote symbol));
        None
    | Some { C.ty = C.Function { variadic = true; _ }; _ } ->
        error env at
          (Printf.sprintf "%s is variadic: reach it through a C function of the package that takes its arguments (ffi.md §3.3)" (quote symbol));
        None
    | Some { C.ty = C.Function { params; result; _ } as c_function; _ } ->
        if List.length params <> List.length s.S.params then begin
          error env at
            (Printf.sprintf "%s takes %d parameters, and the foreign verb passes %d (ffi.md §3.2)" (quote symbol)
               (List.length params) (List.length s.S.params));
          None
        end
        else begin
          let spans =
            match (s.S.kind, v.this_span) with S.Method, Some this_span -> this_span :: v.param_spans | _ -> v.param_spans
          in
          let positions = List.mapi (fun i _ -> if i = 0 && s.S.kind = S.Method then Subject else Param) s.S.params in
          let report span = function Ok () -> () | Error why -> error env span why in
          List.iteri
            (fun i ((p : S.param), c) ->
              report (List.nth spans i) (corresponds env iface v (List.nth positions i) p.S.ty c))
            (List.combine s.S.params params);
          report (ret_span v) (corresponds env iface v Result s.S.ret result);
          Some c_function
        end
    | Some { C.ty; _ } ->
        error env at (Printf.sprintf "%s is declared as %s, not as a function" (quote symbol) (quote (C.to_string ty)));
        None

(* What the verb reads and writes outside the program (§5.2). *)
let access env v =
  if not (on_capability env v) then F.Pure else if v.signature.S.is_mut then F.Writes else F.Reads

(* A handle is made only by a foreign verb that returns it, and a capability
   only by a foreign variable (§4.1, §4.2), so no constructor builds one. *)
let check_constructors env =
  Names.fold_decls
    (fun _ (d : decl) () ->
      match (d.kind, Verbs.signature env.verbs d.id) with
      | Verb { N.Verb_decl.node = N.Verb_decl.Constructor _; _ }, Some s when Option.is_some (handle_of env s.S.ret) ->
          error env d.span
            "a foreign handle has no constructor: one is made only by a foreign verb that returns it, and a \
             capability by a foreign variable (ffi.md §4.1, §4.2)"
      | _ -> ())
    env.names ()

let run env (tables : verbs) =
  check_constructors env;
  let verbs = foreign_verbs env in
  kinds env tables verbs;
  Types.fold_type_infos
    (fun _ (info : type_info) () -> match info.definition with Some (Handle h) -> check_handle env info h | _ -> ())
    env.types ();
  List.iter
    (fun v ->
      check_form env v;
      check_maker env v;
      match check_against_c env v with
      | Some c_function ->
          Hashtbl.replace tables.foreign_verbs v.decl.id
            { F.symbol = v.symbol.N.Name.text; package = v.decl.package; access = access env v; c_function }
      | None -> ())
    verbs

(* ---------------------------------------------------------------------- *)
(* Foreign variables                                                      *)
(* ---------------------------------------------------------------------- *)

(* A foreign variable's value (§5.1): declared only in the root package,
   of a foreign capability's type, naming a global the package that
   declares the type defines with external linkage and declares in an
   interface header with the type's C type, not thread-local. *)
let global env ~package ~span ~declared (symbol : N.Name.t) : Nodes.Expr.t =
  let name = symbol.N.Name.text in
  let fail message =
    error env span message;
    { Nodes.Expr.node = Nodes.Expr.Invalid; ty = Ty.Error; span }
  in
  if not (Env.package env package).is_root then
    fail
      "only the root package declares a foreign variable; every other package reaches a foreign capability through one passed to it (ffi.md §5.1)"
  else
    match handle_of env declared with
    | None ->
        fail
          (Printf.sprintf "a foreign variable's type is a foreign capability, a `#handle` without a free function, and %s is not one (ffi.md §5.1)"
             (quote (Ty.to_string declared)))
    | Some (_, h) when not (is_capability h) ->
        fail
          (Printf.sprintf "a foreign variable's type is a foreign capability, and %s has a free function, so it owns what it refers to (ffi.md §5.1)"
             (quote (Ty.to_string declared)))
    | Some (tid, h) -> (
        let owner = tid.Ty.package in
        let iface = interface env owner in
        let record = record_of iface h.Nodes.Handle.c_type in
        let missing () =
          fail
            (Printf.sprintf "no interface header of %s declares a global %s with external linkage (ffi.md §5.1)"
               (quote owner) (quote name))
        in
        match List.assoc_opt name iface.C.variables with
        | None -> missing ()
        | Some { C.external_ = false; _ } -> missing ()
        | Some _ when not (List.mem name iface.C.defined) ->
            fail
              (Printf.sprintf "no C source of %s defines %s, which its interface header declares: a foreign variable names a global the package's C code defines (ffi.md §5.1)"
                 (quote owner) (quote name))
        | Some { C.thread_local = true; _ } ->
            fail
              (Printf.sprintf "%s is thread-local, a separate object on each thread, and a call that reaches it may run on any thread (ffi.md §5.1)"
                 (quote name))
        | Some { C.ty = C.Record { union = false; name = r }; _ } when Some r = record ->
            { Nodes.Expr.node = Nodes.Expr.Foreign_global { symbol = name; package = owner }; ty = declared; span }
        | Some { C.ty; _ } ->
            fail
              (Printf.sprintf "%s is a %s, and %s's objects are %s (ffi.md §5.1)" (quote name) (quote (C.to_string ty))
                 (quote tid.Ty.name) (quote h.Nodes.Handle.c_type)))

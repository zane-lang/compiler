(* Everything the passes share about one build: the declarations of every
   package, each file's import map, and the tables each later pass fills in.
   [start] makes one per check, and every pass takes it as an argument, so
   two checks share nothing and a function's parameters say what it reads.

   The passes run in order (docs/design/semantics.md §3) and each reads only what the
   ones before it wrote. The tables are grouped by the pass that fills them:
   [names], [types], [verbs] and [instances], with the counters apart. A pass
   is given empty tables for its group, fills them, and hands on a view of
   them ([Names], [Types], [Verbs]) that has no way to write; [t] holds one
   slot per group, so a pass's type says which groups it reads and that the
   passes before it have run. The tables are mutable because a pass fills
   them as it runs, revising some entries on the way (a subscript's result is
   [None] while it is computed, and a verb's promoted parameters grow until a
   fixed point settles). *)

module N = Sst.Nodes
module Span = Source.Span

(* ---------------------------------------------------------------------- *)
(* Diagnostics                                                            *)
(* ---------------------------------------------------------------------- *)

(* Where something is, for a message that points at a second place: the file
   and line. *)
let where (span : Span.t) =
  Printf.sprintf "%s:%d" span.Span.start_.Lexing.pos_fname
    span.Span.start_.Lexing.pos_lnum

let quote s = "`" ^ s ^ "`"

(* ---------------------------------------------------------------------- *)
(* Declarations                                                           *)
(* ---------------------------------------------------------------------- *)

type kind =
  | Type_decl of {
      name : N.Name.t;
      params : N.Generic_param.t list;
      value : N.Type_or_moulded.t;
      alias : bool;
    }
  | Constant of { name : N.Name.t; type_ : N.Type_expr.t; value : N.Expr.t }
  | Verb of N.Verb_decl.t
  | Enum_map of {
      enum : N.Type_expr.t;
      property : N.Name.t;
      type_ : N.Type_expr.t;
      entries : (N.Name.t * N.Expr.t) list;
    }

(* What a file may write, and what it means (packages.md §3.3). *)
type file = {
  path : string;
  package : string;
  (* `import pkg` and `import pkg as alias`: the spelling before `$` and the
     package it names. *)
  qualifiers : (string, string * Span.t) Hashtbl.t;
  (* Every other form: a bare spelling and the members it brings, as the
     package and the member's own name. A name that more than one import
     brings is a legal overload set of functions or an error at the import
     (§3.8). *)
  bare : (string, bare) Hashtbl.t;
}

and bare = { from : string; member : string; at : Span.t }

type decl = { id : int; package : string; file : file; span : Span.t; kind : kind }

type package = {
  (* The package's identity in the build: its name, after its stamp when it
     has one (Assembly). Declarations, types and symbols name it by this. *)
  name : string;
  (* The name its files declare and its manifest gives it. *)
  declared : string;
  (* The package each of its import keys names, by identity, when the driver
     gave them. *)
  imports : (string * string) list;
  (* Whether it imports through those keys alone, which it does whenever the
     driver gave the build's imports; otherwise an import names a package by
     its name. *)
  keyed : bool;
  is_root : bool;
  files : file list;
  mutable decls : decl list;
  (* Plain-name lookup reads these two and nothing else. *)
  types : (string, decl) Hashtbl.t;
  values : (string, decl list) Hashtbl.t;
  (* Names reached only by method lookup, kept so an import of one can be
     told apart from an import of nothing (§3.6). *)
  method_names : (string, unit) Hashtbl.t;
}

let decl_name d =
  match d.kind with
  | Type_decl { name; _ } | Constant { name; _ } -> name.N.Name.text
  | Enum_map { property; _ } -> property.N.Name.text
  | Verb v -> (
      match v.N.Verb_decl.node with
      | N.Verb_decl.Func { name; _ } | N.Verb_decl.Meth { name; _ } -> name.N.Name.text
      | N.Verb_decl.Op { op; _ } -> Intrinsics.operator_token op.N.Operator.node
      | N.Verb_decl.Flip _ -> "~"
      | N.Verb_decl.Constructor _ -> "constructor"
      | N.Verb_decl.Subscript _ -> "[]")

let is_private name = String.length name > 0 && name.[0] = '_'

let is_upper name =
  let name =
    if is_private name then String.sub name 1 (String.length name - 1) else name
  in
  String.length name > 0 && Char.uppercase_ascii name.[0] = name.[0]
  && Char.lowercase_ascii name.[0] <> name.[0]

let is_function d =
  match d.kind with
  | Verb { N.Verb_decl.node = N.Verb_decl.Func _; _ } -> true
  | _ -> false

(* ---------------------------------------------------------------------- *)
(* Tables the later passes fill in                                        *)
(* ---------------------------------------------------------------------- *)

type definition =
  | Struct of (string * Ty.t) list
  | Variant of (string * Ty.t) list
  | Enum of string list
  | Distinct of Ty.t
  (* A foreign handle (ffi.md §4.1): the C type its objects have, and the
     C functions that replace and release one, when Zane owns them. *)
  | Handle of Nodes.Handle.t

type type_info = {
  tid : Ty.type_id;
  decl : decl;
  params : Ty.param list;
  mutable definition : definition option;
  mutable reference : bool option;
}

type alias_info = {
  alias_decl : decl;
  alias_params : Ty.param list;
  mutable target : Ty.t option;
  mutable resolving : bool;
}

(* Pass 4 files every verb where a call site finds it: constructors under the
   type they build, methods under their name, operators under their token,
   subscripts under nothing -- a subscript is found by its subject. *)
type type_key = Declared_type of Ty.type_id | Intrinsic_type of string * string

(* Enum maps by the enum they range over and the property they name. *)
type enum_map = {
  map_decl : decl;
  map_enum : Ty.type_id;
  map_ty : Ty.t;
}

(* A generic instance pass 5 still has to check (D12), with the declarations
   of the instances being checked when it was asked for, innermost first: the
   chain of instantiations that led to it. *)
type pending = {
  p_decl : decl;
  p_sig : Signature.t;
  p_subst : Ty.subst;
  p_at : Span.t;
  p_chain : int list;
}

(* ---------------------------------------------------------------------- *)
(* One check's tables                                                     *)
(* ---------------------------------------------------------------------- *)

(* Passes 1 and 2 ([Collect]): the packages, in the order given, and every
   declaration by id. *)
type names = {
  packages : (string, package) Hashtbl.t;
  package_order : string list ref;
  decls : (int, decl) Hashtbl.t;
}

(* Pass 3 ([Type_decls]): each type and alias declaration, and each type by
   the id it declares. *)
type types = {
  type_infos : (int, type_info) Hashtbl.t;
  type_infos_by_id : (Ty.type_id, type_info) Hashtbl.t;
  alias_infos : (int, alias_info) Hashtbl.t;
}

(* The checks pass 3 holds back while it runs, in the order they were
   asked for: whether a type is a reference type may depend on a definition
   not yet resolved, so a marker, and the kinds of a type's arguments with
   the arguments written explicitly, wait for every type to be defined. *)
type deferred = {
  marks : (Ty.t * Span.t) Queue.t;
  kinds : (Ty.t * (Ty.arg * Span.t) list * Span.t) Queue.t;
}

(* Pass 4 ([Verb_signatures]): every verb's signature, each constant's type,
   every verb where a call site finds it -- constructors under the type they
   build, methods under their name, operators under their token, subscripts
   under nothing, since a subscript is found by its subject -- the enum maps,
   and each verb's parameters promoted to number parameters because a call
   hands them to one, and those it declares so. *)
type verbs = {
  signatures : (int, Signature.t) Hashtbl.t;
  constant_types : (int, Ty.t) Hashtbl.t;
  constructors : (type_key, Signature.t) Hashtbl.t;
  methods : (string, Signature.t) Hashtbl.t;
  operators : (N.Operator.node, Signature.t) Hashtbl.t;
  flips : Signature.t list ref;
  subscripts : Signature.t list ref;
  enum_maps : (Ty.type_id * string, enum_map list) Hashtbl.t;
  promoted : (int, string list) Hashtbl.t;
  own_numbers : (int, string list) Hashtbl.t;
  (* Each foreign handle type's kind, once every foreign verb that makes
     one is known (ffi.md §4.2), and each foreign verb's C function, by
     declaration ([Foreign_decls]). *)
  handle_kinds : (Ty.type_id, Nodes.Decl.handle_kind) Hashtbl.t;
  foreign_verbs : (int, Nodes.Foreign.t) Hashtbl.t;
}

(* Pass 5 ([Program]) asks for generic instances while it checks bodies: the
   instances recorded, by key, the declarations instantiated at all, those
   whose chain of instantiations ran past the limit, those still to check,
   and the chain of the instance being checked (empty outside one). *)
type requests = {
  instance_keys : (string, unit) Hashtbl.t;
  instantiated : (int, unit) Hashtbl.t;
  runaway : (int, unit) Hashtbl.t;
  pending : pending Stack.t;
  current_chain : int list ref;
}

(* Pass 5 ([Program] and [Check]): the instance requests, while instances may
   be asked for -- a generic verb nothing instantiates is checked where it is
   declared with none, and asks for no instances -- the instances checked; a
   subscript's result type per set of arguments, [None] while it is
   computed, which is how one that depends on itself is caught, and the body
   typed for it; and the field-constructor defaults the program carries. *)
type instances = {
  requests : requests option;
  checked : Nodes.Instance.t list ref;
  subscript_results : (string, Ty.t option) Hashtbl.t;
  subscript_instances : (string, Signature.t * Ty.subst * Nodes.Local.t list * Nodes.Expr.t) Hashtbl.t;
  defaults : Nodes.Defaults.t list ref;
}

(* The next declaration's, type parameter's and local's numbers. [Intrinsics]
   made its own type parameters when it loaded, so a check numbers its own
   after them. *)
type counters = {
  next_decl : int ref;
  next_param : int ref;
  next_local : int ref;
}

(* ---------------------------------------------------------------------- *)
(* What the passes after one read of it                                   *)
(* ---------------------------------------------------------------------- *)

(* A pass reads the groups before it through these, which have no way to
   write. *)
module Names : sig
  type t

  val view : names -> t
  val package : t -> string -> package
  val package_order : t -> string list
  val decl : t -> int -> decl
  val fold_decls : (int -> decl -> 'a -> 'a) -> t -> 'a -> 'a
end = struct
  type t = names

  let view names = names
  let package t name = Hashtbl.find t.packages name
  let package_order t = !(t.package_order)
  let decl t id = Hashtbl.find t.decls id
  let fold_decls f t acc = Hashtbl.fold f t.decls acc
end

(* Whether pass 3 has run is whether the view still holds the checks it
   defers: [defining] makes the view pass 3 reads while it runs, and [view]
   the one it hands on. *)
module Types : sig
  type t

  val defining : types -> deferred -> t
  val view : types -> t
  val deferred : t -> deferred option
  val type_info : t -> int -> type_info option
  val type_info_of_id : t -> Ty.type_id -> type_info option
  val alias_info : t -> int -> alias_info option
  val fold_type_infos : (int -> type_info -> 'a -> 'a) -> t -> 'a -> 'a
  val fold_alias_infos : (int -> alias_info -> 'a -> 'a) -> t -> 'a -> 'a
end = struct
  type t = { tables : types; deferred : deferred option }

  let defining tables deferred = { tables; deferred = Some deferred }
  let view tables = { tables; deferred = None }
  let deferred t = t.deferred
  let type_info t id = Hashtbl.find_opt t.tables.type_infos id
  let type_info_of_id t tid = Hashtbl.find_opt t.tables.type_infos_by_id tid
  let alias_info t id = Hashtbl.find_opt t.tables.alias_infos id
  let fold_type_infos f t acc = Hashtbl.fold f t.tables.type_infos acc
  let fold_alias_infos f t acc = Hashtbl.fold f t.tables.alias_infos acc
end

module Verbs : sig
  type t

  val view : verbs -> t
  val signature : t -> int -> Signature.t option
  val constant_type : t -> int -> Ty.t option
  val constructors : t -> type_key -> Signature.t list
  val methods : t -> string -> Signature.t list
  val operators : t -> N.Operator.node -> Signature.t list
  val flips : t -> Signature.t list
  val subscripts : t -> Signature.t list
  val enum_maps : t -> Ty.type_id * string -> enum_map list option
  val handle_kind : t -> Ty.type_id -> Nodes.Decl.handle_kind option
  val foreign_verb : t -> int -> Nodes.Foreign.t option
end = struct
  type t = verbs

  let view verbs = verbs
  let signature t id = Hashtbl.find_opt t.signatures id
  let constant_type t id = Hashtbl.find_opt t.constant_types id
  let constructors t key = Hashtbl.find_all t.constructors key
  let methods t name = Hashtbl.find_all t.methods name
  let operators t op = Hashtbl.find_all t.operators op
  let flips t = !(t.flips)
  let subscripts t = !(t.subscripts)
  let enum_maps t key = Hashtbl.find_opt t.enum_maps key
  let handle_kind t tid = Hashtbl.find_opt t.handle_kinds tid
  let foreign_verb t id = Hashtbl.find_opt t.foreign_verbs id
end

(* What a pass is given: the diagnostics, the note an error carries (set
   while a generic instance is being checked, so an error inside its body
   names the instantiation that exposed it, D12), the counters, and one slot
   per group. A pass reads the groups before it through their views and fills
   its own; a group not yet filled is [()]. *)
type ('names, 'types, 'verbs, 'instances) t = {
  diagnostics : Diagnostic.t list ref;
  note : string option ref;
  counters : counters;
  (* What each package's C code declares and defines, by package identity
     (docs/design/ffi.md F6): the input foreign verbs are checked against. *)
  interfaces : (string, C_interface.t) Hashtbl.t;
  names : 'names;
  types : 'types;
  verbs : 'verbs;
  instances : 'instances;
}

(* The parameters [Intrinsics] made when it loaded. *)
let intrinsic_params = !Ty.next_param

(* A check before any pass has run. *)
let start () =
  {
    diagnostics = ref [];
    note = ref None;
    counters = { next_decl = ref 0; next_param = ref intrinsic_params; next_local = ref 0 };
    interfaces = Hashtbl.create 4;
    names = ();
    types = ();
    verbs = ();
    instances = ();
  }

(* Each group's tables, empty but for what the intrinsic namespaces supply. *)
let names () = { packages = Hashtbl.create 16; package_order = ref []; decls = Hashtbl.create 256 }

let types () =
  { type_infos = Hashtbl.create 64; type_infos_by_id = Hashtbl.create 64; alias_infos = Hashtbl.create 16 }

let verbs () =
  let verbs =
    {
      signatures = Hashtbl.create 256;
      constant_types = Hashtbl.create 32;
      constructors = Hashtbl.create 64;
      methods = Hashtbl.create 64;
      operators = Hashtbl.create 32;
      flips = ref [];
      subscripts = ref Intrinsics.subscripts;
      enum_maps = Hashtbl.create 16;
      promoted = Hashtbl.create 64;
      own_numbers = Hashtbl.create 64;
      handle_kinds = Hashtbl.create 8;
      foreign_verbs = Hashtbl.create 16;
    }
  in
  List.iter
    (fun (key, s) -> Hashtbl.add verbs.constructors (Intrinsic_type (fst key, snd key)) s)
    Intrinsics.constructors;
  List.iter (fun (name, s) -> Hashtbl.add verbs.methods name s) Intrinsics.methods;
  verbs

let requests () =
  {
    instance_keys = Hashtbl.create 32;
    instantiated = Hashtbl.create 32;
    runaway = Hashtbl.create 4;
    pending = Stack.create ();
    current_chain = ref [];
  }

let instances () =
  {
    requests = None;
    checked = ref [];
    subscript_results = Hashtbl.create 16;
    subscript_instances = Hashtbl.create 16;
    defaults = ref [];
  }

(* A check whose every group is filled and empty, as pass 5 sees it: what a
   test of one of its parts runs against. *)
let create () =
  {
    (start ()) with
    names = Names.view (names ());
    types = Types.view (types ());
    verbs = Verbs.view (verbs ());
    instances = { (instances ()) with requests = Some (requests ()) };
  }

(* ---------------------------------------------------------------------- *)
(* Reading and writing them                                               *)
(* ---------------------------------------------------------------------- *)

(* Runs [f] with [note] set, and puts back the note it found however [f]
   ends. *)
let with_note env n f =
  let saved = !(env.note) in
  env.note := Some n;
  Fun.protect ~finally:(fun () -> env.note := saved) f

(* Runs [f] with an instance's note, if it has one. *)
let in_instance env (i : Nodes.Instance.t) f =
  match i.Nodes.Instance.note with Some n -> with_note env n f | None -> f ()

let error env span message =
  let message =
    match !(env.note) with None -> message | Some n -> message ^ " (" ^ n ^ ")"
  in
  env.diagnostics := Diagnostic.error span message :: !(env.diagnostics)

(* A new type or number parameter of this check. *)
let fresh_param env ~name ~kind =
  incr env.counters.next_param;
  { Ty.id = !(env.counters.next_param); name; kind }

(* The signature a call names: a declared verb's, or an intrinsic method's
   or function's. The overloads of one `@operators$` spelling differ only in
   the primitive they take, which no analysis asking this reads: every
   parameter is a value, and none is a subject. A generic overload is told
   apart by its own parameters, which the call's instance fills: a list's
   methods are one overload on `List` and one on `ListRef`. *)
let intrinsic_signatures =
  Intrinsics.methods @ List.map (fun ((_, n), sg) -> (n, sg)) Intrinsics.functions

let signature_of env (r : Nodes.Verb_ref.t) =
  match r.Nodes.Verb_ref.owner with
  | Signature.Declared id -> Verbs.signature env.verbs id
  | Signature.Intrinsic spelling -> (
      let named =
        List.filter_map
          (fun (_, (sg : Signature.t)) ->
            if sg.Signature.owner = Signature.Intrinsic spelling then Some sg else None)
          intrinsic_signatures
      in
      let instantiated (sg : Signature.t) =
        List.exists
          (fun ((p : Ty.param), _) ->
            List.exists (fun (g : Ty.param) -> g.id = p.id) sg.Signature.generics)
          r.Nodes.Verb_ref.instance
      in
      match List.find_opt instantiated named with
      | Some sg -> Some sg
      | None -> List.nth_opt named 0)

let package env name = Names.package env.names name

(* What a key in an import, or a qualifier, names from a file
   (dependencies.md §8). When the driver gave the build's imports, a package
   imports through its keys alone, and one given none imports nothing
   (packages.md §4.3); otherwise it imports a package by its declared name,
   which then has to name one package of the build. *)
type key = Found of string | Own | Unknown | Not_given | Ambiguous of string list

let resolve_key env (file : file) key =
  let own = package env file.package in
  match own.keyed with
  | true -> (
      match List.assoc_opt key own.imports with
      | Some id when String.equal id own.name -> Own
      | Some id -> Found id
      | None -> if String.equal key own.declared then Own else Not_given)
  | false -> (
      if String.equal key own.declared then Own
      else
        match List.filter (fun id -> String.equal (package env id).declared key) (Names.package_order env.names) with
        | [ id ] -> Found id
        | [] -> Unknown
        | ids -> Ambiguous ids)

let key_message key = function
  | Ambiguous ids ->
      Some
        (Printf.sprintf
           "%s could be %s; the driver says which one this package imports with \
            `--import`"
           (quote key)
           (String.concat " or " (List.map quote ids)))
  | Unknown -> Some (Printf.sprintf "no package named %s is part of this build" (quote key))
  | Not_given ->
      Some
        (Printf.sprintf
           "this package may not import %s, which is not among the packages its place in \
            its project lets it import (packages.md §4.3)"
           (quote key))
  | Found _ | Own -> None

(* ---------------------------------------------------------------------- *)
(* Plain-name lookup                                                      *)
(* ---------------------------------------------------------------------- *)

(* A declaration another package may reach: every one but those named with a
   leading `_` (packages.md §4.1). *)
let accessible ~from (d : decl) =
  String.equal d.package from || not (is_private (decl_name d))

let package_types env pkg name =
  Option.to_list (Hashtbl.find_opt (package env pkg).types name)

let package_values env pkg name =
  Option.value ~default:[] (Hashtbl.find_opt (package env pkg).values name)

(* What a bare name means in a file: its own package's declarations of that
   name, and whatever its imports bring under that spelling (packages.md
   §3.2–§3.3). *)
let bare_entries (file : file) name ~members =
  let own = members file.package name in
  let imported =
    Hashtbl.find_all file.bare name
    |> List.concat_map (fun b -> members b.from b.member)
    |> List.filter (accessible ~from:file.package)
  in
  own @ imported

let lookup_types env file name = bare_entries file name ~members:(package_types env)
let lookup_values env file name = bare_entries file name ~members:(package_values env)

(* `q$name`: the package the file spells `q`, and its members named
   [name]. [Error] carries the diagnostic's text. *)
let qualified_package env (file : file) q =
  match Hashtbl.find_opt file.qualifiers q with
  | Some (pkg, _) -> Ok pkg
  | None -> (
      match resolve_key env file q with
      | Own ->
          Error
            (Printf.sprintf
               "%s is this file's own package, whose members are written \
                unqualified"
               (quote q))
      | Found id when Hashtbl.fold (fun _ (p, _) acc -> acc || p = id) file.qualifiers false ->
          Error (Printf.sprintf "this file spells the package %s another way" (quote q))
      | _ -> Error (Printf.sprintf "no import in this file spells a package %s" (quote q)))

let qualified env (file : file) q name ~members =
  Result.map
    (fun pkg ->
      let found = members pkg name in
      let reachable = List.filter (accessible ~from:file.package) found in
      (pkg, found, reachable))
    (qualified_package env file q)

(* For a name that is not in scope: another package of the build that
   declares an accessible one, which is almost always the import the file is
   missing. *)
let declared_elsewhere env (file : file) name ~members =
  List.find_opt
    (fun pkg ->
      (not (String.equal pkg file.package))
      && List.exists (fun d -> not (is_private (decl_name d))) (members pkg name))
    (Names.package_order env.names)

let missing_import_hint env file name ~members =
  match declared_elsewhere env file name ~members with
  | Some pkg ->
      Printf.sprintf "; the package %s declares one, and like every package it needs an import"
        (quote pkg)
  | None -> ""

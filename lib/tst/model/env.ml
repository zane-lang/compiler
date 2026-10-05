(* Everything the passes share about one build: the declarations of every
   package, each file's import map, and the tables each later pass fills in.

   The passes run in order (docs/design/semantics.md §3) and each reads only what the
   ones before it wrote. The tables are mutable because a pass writes them
   once and every later pass reads them; nothing is written twice. *)

module N = Sst.Nodes
module Span = Source.Span

(* ---------------------------------------------------------------------- *)
(* Diagnostics                                                            *)
(* ---------------------------------------------------------------------- *)

let diagnostics : Diagnostic.t list ref = ref []

(* Set while a generic instance is being checked, so an error inside its body
   names the instantiation that exposed it (D12). *)
let note : string option ref = ref None

(* Runs [f] with [note] set, and puts back the note it found however [f]
   ends. *)
let with_note n f =
  let saved = !note in
  note := Some n;
  Fun.protect ~finally:(fun () -> note := saved) f

let error span message =
  let message =
    match !note with None -> message | Some n -> message ^ " (" ^ n ^ ")"
  in
  diagnostics := Diagnostic.error span message :: !diagnostics

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
     gave them; empty when an import names a package by its name. *)
  imports : (string * string) list;
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

let packages : (string, package) Hashtbl.t = Hashtbl.create 16
let package_order : string list ref = ref []
let decls : (int, decl) Hashtbl.t = Hashtbl.create 256

let next_decl = ref 0

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

let type_infos : (int, type_info) Hashtbl.t = Hashtbl.create 64

(* The same records, by the type they declare. *)
let type_infos_by_id : (Ty.type_id, type_info) Hashtbl.t = Hashtbl.create 64
let alias_infos : (int, alias_info) Hashtbl.t = Hashtbl.create 16
let signatures : (int, Signature.t) Hashtbl.t = Hashtbl.create 256

(* The signature a call names: a declared verb's, or an intrinsic method's. *)
let signature_of (r : Nodes.Verb_ref.t) =
  match r.Nodes.Verb_ref.owner with
  | Signature.Declared id -> Hashtbl.find_opt signatures id
  | Signature.Intrinsic spelling ->
      List.find_map
        (fun (_, (sg : Signature.t)) ->
          if sg.Signature.owner = Signature.Intrinsic spelling then Some sg else None)
        Intrinsics.methods
let constant_types : (int, Ty.t) Hashtbl.t = Hashtbl.create 32

(* Pass 4 files every verb where a call site finds it: constructors under the
   type they build, methods under their name, operators under their token,
   subscripts under nothing -- a subscript is found by its subject. *)
type type_key = Declared_type of Ty.type_id | Intrinsic_type of string * string

let constructors : (type_key, Signature.t) Hashtbl.t = Hashtbl.create 64
let methods : (string, Signature.t) Hashtbl.t = Hashtbl.create 64
let operators : (N.Operator.node, Signature.t) Hashtbl.t = Hashtbl.create 32
let flips : Signature.t list ref = ref []
let subscripts : Signature.t list ref = ref []

(* Enum maps by the enum they range over and the property they name. *)
type enum_map = {
  map_decl : decl;
  map_enum : Ty.type_id;
  map_ty : Ty.t;
}

let enum_maps : (Ty.type_id * string, enum_map list) Hashtbl.t = Hashtbl.create 16

(* ---------------------------------------------------------------------- *)
(* What one pass leaves for itself or the next                            *)
(* ---------------------------------------------------------------------- *)

(* Pass 3 ([Type_decls]). Once it has run, whether a type is a reference type
   can be asked of any type; before it has, the answer may depend on a
   definition not yet resolved, so the checks that need it wait. *)
let ready = ref false
let deferred_guests : (Ty.t * Span.t) list ref = ref []

(* Pass 4 ([Verb_signatures]): each verb's parameters promoted to number
   parameters because a call hands them to one, and those it declares so. *)
let promoted : (int, string list) Hashtbl.t = Hashtbl.create 64
let own_numbers : (int, string list) Hashtbl.t = Hashtbl.create 64

(* Pass 5 ([Check]): the next local's number. *)
let next_local = ref 0

(* Pass 5's generic instances ([Instances], D12): each one recorded, by key,
   how many each declaration has, those still to check, and those checked.
   [defining] is set while a generic verb nothing instantiates is checked
   where it is declared: that check asks for no instances, since whatever it
   calls is checked when something that runs calls it. *)
type pending = { p_decl : decl; p_sig : Signature.t; p_subst : Ty.subst; p_at : Span.t }

let instance_keys : (string, unit) Hashtbl.t = Hashtbl.create 32
let instance_counts : (int, int) Hashtbl.t = Hashtbl.create 32
let pending : pending Queue.t = Queue.create ()
let instances : Nodes.Instance.t list ref = ref []
let defining = ref false

(* Pass 5's subscripts ([Overloads]): a subscript's result type per set of
   arguments, and the body typed for it. [None] while it is being computed,
   which is how a subscript whose type depends on itself is caught. *)
let subscript_results : (string, Ty.t option) Hashtbl.t = Hashtbl.create 16

let subscript_instances : (string, Signature.t * Ty.subst * Nodes.Local.t list * Nodes.Expr.t) Hashtbl.t =
  Hashtbl.create 16

(* Pass 5's field-constructor defaults, as the program carries them: a
   declaration's, and each instance's. *)
let defaults : Nodes.Defaults.t list ref = ref []

(* The parameters [Intrinsics] made when it loaded: a check numbers its own
   after them. *)
let intrinsic_params = !Ty.next_param

(* Every table above, as a check starts. *)
let reset () =
  next_decl := 0;
  ready := false;
  deferred_guests := [];
  Hashtbl.reset promoted;
  Hashtbl.reset own_numbers;
  next_local := 0;
  Hashtbl.reset instance_keys;
  Hashtbl.reset instance_counts;
  Queue.clear pending;
  instances := [];
  defining := false;
  Hashtbl.reset subscript_results;
  Hashtbl.reset subscript_instances;
  defaults := [];
  Ty.next_param := intrinsic_params;
  diagnostics := [];
  note := None;
  Hashtbl.reset packages;
  package_order := [];
  Hashtbl.reset decls;
  Hashtbl.reset type_infos;
  Hashtbl.reset type_infos_by_id;
  Hashtbl.reset alias_infos;
  Hashtbl.reset signatures;
  Hashtbl.reset constant_types;
  Hashtbl.reset constructors;
  Hashtbl.reset methods;
  Hashtbl.reset operators;
  Hashtbl.reset enum_maps;
  flips := [];
  subscripts := [];
  List.iter
    (fun (key, s) -> Hashtbl.add constructors (Intrinsic_type (fst key, snd key)) s)
    Intrinsics.constructors;
  List.iter (fun (name, s) -> Hashtbl.add methods name s) Intrinsics.methods;
  List.iter (fun (op, s) -> Hashtbl.add operators op s) Intrinsics.operators;
  flips := Intrinsics.flips;
  subscripts := Intrinsics.subscripts

let package name = Hashtbl.find packages name

(* What a key in an import, or a qualifier, names from a file
   (dependencies.md §8). A package the driver gave keys imports through those
   keys alone; any other imports a package by its declared name, which then
   has to name one package of the build. *)
type key = Found of string | Own | Unknown | Ambiguous of string list

let resolve_key (file : file) key =
  let own = package file.package in
  match own.imports with
  | _ :: _ -> (
      match List.assoc_opt key own.imports with
      | Some id when String.equal id own.name -> Own
      | Some id -> Found id
      | None -> if String.equal key own.declared then Own else Unknown)
  | [] -> (
      if String.equal key own.declared then Own
      else
        match List.filter (fun id -> String.equal (package id).declared key) !package_order with
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
  | Found _ | Own -> None

(* ---------------------------------------------------------------------- *)
(* Plain-name lookup                                                      *)
(* ---------------------------------------------------------------------- *)

(* A declaration another package may reach: every one but those named with a
   leading `_` (packages.md §4.1). *)
let accessible ~from (d : decl) =
  String.equal d.package from || not (is_private (decl_name d))

let package_types pkg name =
  Option.to_list (Hashtbl.find_opt (package pkg).types name)

let package_values pkg name =
  Option.value ~default:[] (Hashtbl.find_opt (package pkg).values name)

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

let lookup_types file name = bare_entries file name ~members:package_types
let lookup_values file name = bare_entries file name ~members:package_values

(* `q$name`: the package the file spells `q`, and its members named
   [name]. [Error] carries the diagnostic's text. *)
let qualified_package (file : file) q =
  match Hashtbl.find_opt file.qualifiers q with
  | Some (pkg, _) -> Ok pkg
  | None -> (
      match resolve_key file q with
      | Own ->
          Error
            (Printf.sprintf
               "%s is this file's own package, whose members are written \
                unqualified"
               (quote q))
      | Found id when Hashtbl.fold (fun _ (p, _) acc -> acc || p = id) file.qualifiers false ->
          Error (Printf.sprintf "this file spells the package %s another way" (quote q))
      | _ -> Error (Printf.sprintf "no import in this file spells a package %s" (quote q)))

let qualified (file : file) q name ~members =
  Result.map
    (fun pkg ->
      let found = members pkg name in
      let reachable = List.filter (accessible ~from:file.package) found in
      (pkg, found, reachable))
    (qualified_package file q)

(* For a name that is not in scope: another package of the build that
   declares an accessible one, which is almost always the import the file is
   missing. *)
let declared_elsewhere (file : file) name ~members =
  List.find_opt
    (fun pkg ->
      (not (String.equal pkg file.package))
      && List.exists (fun d -> not (is_private (decl_name d))) (members pkg name))
    !package_order

let missing_import_hint file name ~members =
  match declared_elsewhere file name ~members with
  | Some pkg ->
      Printf.sprintf "; the package %s declares one, and like every package it needs an import"
        (quote pkg)
  | None -> ""

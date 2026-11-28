(* What a check knows about the names of a build, for the language server
   (docs/design/language-server.md): every use [Uses] recorded, and a
   description of each target a use can name. *)

open Env
module S = Signature
module Span = Source.Span

type kind =
  | Struct
  | Variant
  | Enum
  | Handle
  | Distinct
  | Alias
  | Constant
  | Function
  | Method
  | Operator
  | Constructor
  | Subscript
  | Flip
  | Enum_map

type entry = {
  name : string;
  kind : kind;
  (* The identity of the package that declares it. *)
  package : string;
  path : string;
  (* The whole declaration, whose first line a documentation comment
     precedes. *)
  span : Span.t;
  (* The declaration as a reader would write it: a signature, a type's
     definition, a constant's type. *)
  detail : string;
}

(* What a member completion offers. *)
type member_kind = Field_member | Case_member | Enum_member | Map_member | Method_member

type t = {
  uses : Uses.use list;
  decls : (int, entry) Hashtbl.t;
  (* The type of each struct field and variant case. *)
  fields : (Ty.type_id * string, Ty.t) Hashtbl.t;
  locals : (int, Nodes.Local.t) Hashtbl.t;
  parameters : (int, unit) Hashtbl.t;
  params : (int, Ty.param) Hashtbl.t;
  probes : (Span.t * Uses.probe) list;
  (* The members a value of a type offers in a file of [package] at [path]:
     fields, cases, enum maps and methods, each with its kind and a
     description, under the rules the checker reads them by. *)
  members_of : Ty.t -> package:string -> path:string -> (string * member_kind * string) list;
  (* The members of a type itself: an enum's members and a variant's
     cases. *)
  type_members_of : Ty.t -> (string * member_kind * string) list;
  (* The names a file can write: the declarations of its own package and the
     members its imports bring bare, each with its kind and description,
     and the qualifiers it may write before `$`. *)
  in_scope : path:string -> (string * kind * string) list * string list;
  (* Whether code at [offset] of the file at [path] reaches `@program$`
     (effects.md §6.6): code of the build's root package, or the body of an
     exported lambda in any package (packages.md §8.4). *)
  reaches_program : path:string -> offset:int -> bool;
  (* The package identities of the build, the root first. *)
  packages : string list;
}

let params_to_string (ps : Ty.param list) =
  match ps with
  | [] -> ""
  | ps ->
      "<"
      ^ String.concat ", "
          (List.map
             (fun (p : Ty.param) ->
               p.Ty.name ^ match p.Ty.kind with Ty.Type_kind -> " Type" | Ty.Number_kind -> " @concepts$Int")
             ps)
      ^ ">"

let fields_to_string fs = String.concat "; " (List.map (fun (n, t) -> n ^ " " ^ Ty.to_string t) fs)

let describe env (d : decl) : (kind * string) option =
  let name = decl_name d in
  match d.kind with
  | Type_decl { alias = true; _ } -> (
      match Types.alias_info env.types d.id with
      | Some a ->
          let target = match a.target with Some t -> Ty.to_string t | None -> "?" in
          Some (Alias, Printf.sprintf "alias %s%s = %s" name (params_to_string a.alias_params) target)
      | None -> (
          (* An alias of a mould is registered as a type. *)
          match Types.type_info env.types d.id with
          | Some _ -> None
          | None -> Some (Alias, "alias " ^ name)))
  | Type_decl _ -> None
  | Constant _ ->
      let ty = Option.value ~default:Ty.Error (Verbs.constant_type env.verbs d.id) in
      Some (Constant, Printf.sprintf "%s %s" name (Ty.to_string ty))
  | Enum_map _ ->
      let ty = Option.value ~default:Ty.Error (Verbs.constant_type env.verbs d.id) in
      Some (Enum_map, Printf.sprintf "%s %s" name (Ty.to_string ty))
  | Verb _ -> (
      match Verbs.signature env.verbs d.id with
      | None -> None
      | Some s ->
          let kind =
            match s.S.kind with
            | S.Function -> Function
            | S.Method -> Method
            | S.Operator -> Operator
            | S.Flip -> Flip
            | S.Constructor _ -> Constructor
            | S.Subscript -> Subscript
          in
          Some (kind, S.to_string s))

let type_entry (info : type_info) =
  let header = info.tid.Ty.name ^ params_to_string info.params in
  let reference = match info.reference with Some true -> "#" | _ -> "" in
  match info.definition with
  | Some (Struct fs) -> (Struct, Printf.sprintf "type %s = %sstruct{ %s }" header reference (fields_to_string fs))
  | Some (Variant cs) -> (Variant, Printf.sprintf "type %s = %svariant{ %s }" header reference (fields_to_string cs))
  | Some (Enum ms) -> (Enum, Printf.sprintf "type %s = enum{ %s }" header (String.concat "; " ms))
  | Some (Handle h) -> (Handle, Printf.sprintf "type %s = #handle{ cType = %s }" header h.Nodes.Handle.c_type)
  | Some (Distinct t) -> (Distinct, Printf.sprintf "type %s = %s" header (Ty.to_string t))
  | None -> (Distinct, "type " ^ header)

(* The identifier the index shows for [d]: the member of a named constructor
   such as `Box.make`, and [decl_name] for every other declaration. *)
let index_name (d : decl) =
  match d.kind with
  | Verb { N.Verb_decl.node = N.Verb_decl.Constructor { member = Some m; _ }; _ } -> m.N.Name.text
  | _ -> decl_name d

(* Whether a method's subject takes a value of [a]: the same type, with
   the same arguments where the method fixes them. *)
let rec fits (p : Ty.t) (a : Ty.t) =
  match (Ty.strip_mode p, Ty.strip_mode a) with
  | Ty.Param _, _ | Ty.Error, _ | _, Ty.Error -> true
  | Ty.Named (x, ps), Ty.Named (y, args) -> x = y && args_fit ps args
  | Ty.Intrinsic { namespace = n1; name = m1; args = ps }, Ty.Intrinsic { namespace = n2; name = m2; args } ->
      n1 = n2 && m1 = m2 && args_fit ps args
  | p, a -> p = a

and args_fit ps args =
  List.length ps = List.length args
  && List.for_all2
       (fun p a ->
         match (p, a) with
         | Ty.Type p, Ty.Type a -> fits p a
         | Ty.Number (Ty.Number_param _), Ty.Number _ -> true
         | p, a -> p = a)
       ps args

(* Whether [s] is a method whose subject takes a value of [t]. *)
let subject_fits (s : S.t) t = match s.S.params with { S.ty; _ } :: _ -> fits ty t | [] -> false

let build env (uses : Uses.t) : t =
  let decls = Hashtbl.create 256 in
  let fields = Hashtbl.create 64 in
  Names.fold_decls
    (fun id (d : decl) () ->
      let add kind detail =
        Hashtbl.replace decls id { name = index_name d; kind; package = d.package; path = d.file.path; span = d.span; detail }
      in
      match Types.type_info env.types id with
      | Some info ->
          let kind, detail = type_entry info in
          add kind detail;
          (match info.definition with
          | Some (Struct fs | Variant fs) -> List.iter (fun (n, t) -> Hashtbl.replace fields (info.tid, n) t) fs
          | _ -> ())
      | None -> Option.iter (fun (kind, detail) -> add kind detail) (describe env d))
    env.names ();
  let files () = List.concat_map (fun name -> (package env name).files) (Names.package_order env.names) in
  let members_of (t : Ty.t) ~package ~path =
    let visible_field (tid : Ty.type_id) n = String.equal tid.Ty.package package || not (is_private n) in
    let tid, own =
      match Context.definition env t with
      | Some (tid, Struct fs) -> (tid, List.filter_map (fun (n, ft) -> if visible_field tid n then Some (n, Field_member, Ty.to_string ft) else None) fs)
      | Some (tid, Variant cs) -> (tid, List.map (fun (n, ct) -> (n, Case_member, Ty.to_string ct)) cs)
      | Some (tid, _) -> (tid, [])
      | None -> ({ Ty.package = ""; name = "" }, [])
    in
    (* An enum map is found where Check.map_read finds it: in the enum's
       home package, then in the current one. *)
    let maps =
      Names.fold_decls
        (fun _ (d : decl) acc ->
          match d.kind with
          | Enum_map { property; _ } when not (List.exists (fun (n, _, _) -> n = property.N.Name.text) acc) -> (
              let all = Option.value ~default:[] (Verbs.enum_maps env.verbs (tid, property.N.Name.text)) in
              let in_package p = List.filter (fun (m : enum_map) -> m.map_decl.package = p) all in
              match in_package tid.Ty.package @ in_package package with
              | m :: _ -> (property.N.Name.text, Map_member, Ty.to_string m.map_ty) :: acc
              | [] -> acc)
          | _ -> acc)
        env.names []
    in
    let home = Verb_signatures.home t in
    let subject_fits s = subject_fits s t in
    (* Check.method_call reaches a method of the subject's home package or
       of the current one, and Context.accessible_sig hides another
       package's private method. *)
    let reachable (s : S.t) =
      match s.S.home with
      | S.Package p -> (Some s.S.home = home || p = package) && (p = package || not (is_private s.S.name))
      | S.Namespace _ -> Some s.S.home = home
    in
    let add name (s : S.t) acc =
      if List.exists (fun (n, _, d) -> n = name && d = S.to_string s) acc then acc else (name, Method_member, S.to_string s) :: acc
    in
    let methods =
      Verbs.fold_methods (fun name (s : S.t) acc -> if reachable s && subject_fits s then add name s acc else acc) env.verbs []
    in
    (* A method of any subject that the file imports, under the file's
       spelling of it, as Check.any_subject finds it: among the methods of
       the importing package, which another package sees only when public. *)
    let imported =
      match List.find_opt (fun (f : file) -> String.equal f.path path) (files ()) with
      | None -> []
      | Some file ->
          let any_subject (b : bare) (s : S.t) =
            s.S.home = S.Package b.from
            && (b.from = package || not (is_private s.S.name))
            && match s.S.params with { S.ty = Ty.Param _; _ } :: _ -> true | [] | _ :: _ -> false
          in
          Hashtbl.fold
            (fun spelling (b : bare) acc ->
              List.fold_left
                (fun acc s -> if any_subject b s then add spelling s acc else acc)
                acc (Verbs.methods env.verbs b.member))
            file.bare []
    in
    own @ List.rev maps @ List.sort_uniq compare (methods @ imported)
  in
  let type_members_of (t : Ty.t) =
    match Context.definition env t with
    | Some (tid, Enum ms) -> List.map (fun m -> (m, Enum_member, tid.Ty.name)) ms
    | Some (_, Variant cs) -> List.map (fun (n, ct) -> (n, Case_member, Ty.to_string ct)) cs
    | _ -> []
  in
  let in_scope ~path =
    match List.find_opt (fun (f : file) -> String.equal f.path path) (files ()) with
    | None -> ([], [])
    | Some file ->
        let entry (d : decl) =
          Option.map (fun (e : entry) -> (e.name, e.kind, e.detail)) (Hashtbl.find_opt decls d.id)
        in
        let own = List.filter_map entry (package env file.package).decls in
        let bare =
          Hashtbl.fold
            (fun spelling (b : bare) acc ->
              let found = package_types env b.from b.member @ package_values env b.from b.member in
              List.filter_map (fun d -> Option.map (fun (_, k, detail) -> (spelling, k, detail)) (entry d)) found @ acc)
            file.bare []
        in
        let qualifiers = Hashtbl.fold (fun q _ acc -> q :: acc) file.qualifiers [] in
        (own @ bare, List.sort_uniq compare qualifiers)
  in
  {
    uses = uses.Uses.uses;
    decls;
    fields;
    locals = uses.Uses.locals;
    parameters = uses.Uses.parameters;
    params = uses.Uses.params;
    probes = uses.Uses.probes;
    members_of;
    type_members_of;
    in_scope;
    reaches_program =
      (fun ~path ~offset ->
        List.exists
          (fun (f : file) ->
            String.equal f.path path
            && ((package env f.package).is_root
               || List.exists
                    (fun (d : decl) ->
                      String.equal d.file.path path
                      && (match d.kind with Constant { export = Some _; _ } -> true | _ -> false)
                      && d.span.Span.start_.Lexing.pos_cnum <= offset
                      && offset <= d.span.Span.end_.Lexing.pos_cnum)
                    (package env f.package).decls))
          (files ()));
    packages = Names.package_order env.names;
  }

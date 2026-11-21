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
  (* The members a value of a type offers: fields, cases, enum maps and
     methods, each with its kind and a description. *)
  members_of : Ty.t -> package:string -> (string * member_kind * string) list;
  (* The names a file can write: the declarations of its own package and the
     members its imports bring bare, each with its kind and description,
     and the qualifiers it may write before `$`. *)
  in_scope : path:string -> (string * kind * string) list * string list;
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

let build env (uses : Uses.t) : t =
  let decls = Hashtbl.create 256 in
  let fields = Hashtbl.create 64 in
  Names.fold_decls
    (fun id (d : decl) () ->
      let add kind detail =
        Hashtbl.replace decls id { name = decl_name d; kind; package = d.package; path = d.file.path; span = d.span; detail }
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
  let members_of (t : Ty.t) ~package =
    let own =
      match Context.definition env t with
      | Some (tid, Struct fs) -> List.map (fun (n, ft) -> (n, Field_member, Ty.to_string ft)) fs |> fun l -> (tid, l)
      | Some (tid, Variant cs) -> (tid, List.map (fun (n, ct) -> (n, Case_member, Ty.to_string ct)) cs)
      | Some (tid, Enum ms) -> (tid, List.map (fun m -> (m, Enum_member, tid.Ty.name)) ms)
      | Some (tid, _) -> (tid, [])
      | None -> ({ Ty.package = ""; name = "" }, [])
    in
    let tid, own = own in
    let maps =
      Names.fold_decls
        (fun _ (d : decl) acc ->
          match d.kind with
          | Enum_map { property; _ } when Verbs.enum_maps env.verbs (tid, property.N.Name.text) <> None ->
              let ty = Option.value ~default:Ty.Error (Verbs.constant_type env.verbs d.id) in
              if List.exists (fun (n, _, _) -> n = property.N.Name.text) acc then acc
              else (property.N.Name.text, Map_member, Ty.to_string ty) :: acc
          | _ -> acc)
        env.names []
    in
    let home = Verb_signatures.home t in
    let subject_fits (s : S.t) =
      match s.S.params with
      | { S.ty; _ } :: _ -> (
          match (Ty.strip_mode ty, Ty.strip_mode t) with
          | Ty.Param _, _ -> true
          | Ty.Named (a, _), Ty.Named (b, _) -> a = b
          | Ty.Intrinsic { namespace = n1; name = m1; _ }, Ty.Intrinsic { namespace = n2; name = m2; _ } ->
              n1 = n2 && m1 = m2
          | a, b -> a = b)
      | [] -> false
    in
    let methods =
      Verbs.fold_methods
        (fun name (s : S.t) acc ->
          let reachable =
            match s.S.home with
            | S.Package p -> Some s.S.home = home || p = package
            | S.Namespace _ -> Some s.S.home = home
          in
          if reachable && subject_fits s && not (List.exists (fun (n, _, d) -> n = name && d = S.to_string s) acc) then
            (name, Method_member, S.to_string s) :: acc
          else acc)
        env.verbs []
    in
    own @ List.rev maps @ List.sort compare methods
  in
  let in_scope ~path =
    let files =
      List.concat_map (fun name -> (package env name).files) (Names.package_order env.names)
    in
    match List.find_opt (fun (f : file) -> String.equal f.path path) files with
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
    in_scope;
    packages = Names.package_order env.names;
  }

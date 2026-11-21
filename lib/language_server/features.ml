(* The answers the server gives: hover, definitions, references, rename,
   document symbols, semantic tokens and completion, each read from a
   build's analysis (docs/design/language-server.md). *)

module Span = Source.Span
module Uses = Tst.Uses
module Index = Tst.Index
module Ty = Tst.Ty
module P = Project

type json = Yojson.Safe.t

(* ---------------------------------------------------------------------- *)
(* Spans and positions                                                    *)
(* ---------------------------------------------------------------------- *)

let span_path (s : Span.t) = s.Span.start_.Lexing.pos_fname
let span_offsets (s : Span.t) = (s.Span.start_.Lexing.pos_cnum, s.Span.end_.Lexing.pos_cnum)

(* How a file's analyzed text maps onto the text the editor shows. *)
type view = { lines : Text.lines; shift : Text.shift; current : string }

let view (t : P.t) (a : P.analysis) path =
  match P.text_of t path with
  | None -> None
  | Some current ->
      let shift =
        match Hashtbl.find_opt a.P.texts path with
        | Some before when not (String.equal before current) -> Text.shift ~before ~after:current
        | _ -> Text.identity
      in
      Some { lines = Text.lines current; shift; current }

let position_json encoding lines offset =
  let line, character = Text.position encoding lines offset in
  `Assoc [ ("line", `Int line); ("character", `Int character) ]

let range_json encoding lines (start, stop) =
  `Assoc [ ("start", position_json encoding lines start); ("end", position_json encoding lines stop) ]

(* A span as an editor's range, in the text the editor shows. *)
let range_of encoding t a (s : Span.t) =
  let path = span_path s in
  match view t a path with
  | None -> None
  | Some v -> Option.map (fun r -> (path, range_json encoding v.lines r)) (Text.move v.shift (span_offsets s))

let location_json (path, range) = `Assoc [ ("uri", `String (Text.uri_of_path path)); ("range", range) ]

(* The offset in the analyzed text of [path] for a position the editor
   names in its own text. *)
let analyzed_offset encoding t a path (line, character) =
  match view t a path with
  | None -> None
  | Some v -> Text.move_back v.shift (Text.offset encoding v.lines (line, character))

(* ---------------------------------------------------------------------- *)
(* What a position names                                                  *)
(* ---------------------------------------------------------------------- *)

let index_of (a : P.analysis) = Option.map (fun r -> Lazy.force r.Driver.index) a.P.result

(* The innermost use whose span holds [offset], its end included, so a
   cursor just after a name still names it. *)
let use_at (index : Index.t) path offset =
  List.fold_left
    (fun best (u : Uses.use) ->
      let start, stop = span_offsets u.Uses.span in
      if String.equal (span_path u.Uses.span) path && start <= offset && offset <= stop then
        match best with
        | Some (b : Uses.use) ->
            let bs, be = span_offsets b.Uses.span in
            if stop - start < be - bs then Some u else best
        | None -> Some u
      else best)
    None index.Index.uses

let declarations (index : Index.t) target =
  List.filter (fun (u : Uses.use) -> u.Uses.declaration && u.Uses.target = target) index.Index.uses

(* What identifies a target in every build of a project: where it is
   declared, or its spelling when nothing declares it. *)
type key = Declared_at of string * int | Package of string | Intrinsic of string

let key_of index (target : Uses.target) =
  match target with
  | Uses.Package p -> Some (Package p)
  | Uses.Intrinsic s -> Some (Intrinsic s)
  | _ -> (
      match declarations index target with
      | d :: _ -> Some (Declared_at (span_path d.Uses.span, fst (span_offsets d.Uses.span)))
      | [] -> None)

(* The key of every target of [index], from one pass over its uses: the
   first declaration [declarations] would find decides it. *)
let key_table (index : Index.t) =
  let declared = Hashtbl.create 256 in
  List.iter
    (fun (u : Uses.use) -> if u.Uses.declaration && not (Hashtbl.mem declared u.Uses.target) then Hashtbl.replace declared u.Uses.target u)
    index.Index.uses;
  fun (target : Uses.target) ->
    match target with
    | Uses.Package p -> Some (Package p)
    | Uses.Intrinsic s -> Some (Intrinsic s)
    | _ ->
        Option.map
          (fun (d : Uses.use) -> Declared_at (span_path d.Uses.span, fst (span_offsets d.Uses.span)))
          (Hashtbl.find_opt declared target)

(* Every use of the target [key] in every build of [project], each once. *)
let uses_of_key t (project : P.project) key =
  let seen = Hashtbl.create 64 in
  List.concat_map
    (fun b ->
      match Option.bind (P.ensure t b) (fun a -> Option.map (fun i -> (a, i)) (index_of a)) with
      | None -> []
      | Some (a, index) ->
          let key_of = key_table index in
          List.filter_map
            (fun (u : Uses.use) ->
              let id = (span_path u.Uses.span, span_offsets u.Uses.span) in
              if key_of u.Uses.target = Some key && not (Hashtbl.mem seen id) then begin
                Hashtbl.replace seen id ();
                Some (a, u)
              end
              else None)
            index.Index.uses)
    project.P.builds

(* Whether a span that names [key] also names another target in some build
   of [project], as a call in a generic body does when its instances choose
   different overloads. *)
let names_another_target t (project : P.project) key =
  let keys = Hashtbl.create 256 in
  List.iter
    (fun b ->
      match Option.bind (P.ensure t b) index_of with
      | None -> ()
      | Some index ->
          let key_of = key_table index in
          List.iter
            (fun (u : Uses.use) ->
              let id = (span_path u.Uses.span, span_offsets u.Uses.span) in
              match key_of u.Uses.target with
              | Some k -> Hashtbl.replace keys id (k :: Option.value ~default:[] (Hashtbl.find_opt keys id))
              | None -> ())
            index.Index.uses)
    project.P.builds;
  Hashtbl.fold (fun _ ks found -> found || (List.mem key ks && List.exists (fun k -> k <> key) ks)) keys false

(* ---------------------------------------------------------------------- *)
(* Hover                                                                  *)
(* ---------------------------------------------------------------------- *)

(* The `///` lines right above the line a declaration starts on, read from
   the text the analysis [a] read, whose lines the declaration's span counts:
   the current text may have moved them. *)
let documentation (a : P.analysis) (entry : Index.entry) =
  match Hashtbl.find_opt a.P.texts entry.Index.path with
  | None -> ""
  | Some text ->
      let lines = Array.of_list (String.split_on_char '\n' text) in
      let line = entry.Index.span.Span.start_.Lexing.pos_lnum - 1 in
      let rec above i acc =
        if i < 0 then acc
        else
          let l = String.trim lines.(i) in
          if String.starts_with ~prefix:"///" l then
            above (i - 1) (String.trim (String.sub l 3 (String.length l - 3)) :: acc)
          else acc
      in
      if line <= 0 || line > Array.length lines then "" else String.concat "\n" (above (line - 1) [])

let code s = "```zane\n" ^ s ^ "\n```"

let local_description (l : Tst.Nodes.Local.t) = Printf.sprintf "%s %s" l.Tst.Nodes.Local.name (Ty.to_string l.ty)

let describe (a : P.analysis) (index : Index.t) (target : Uses.target) =
  match target with
  | Uses.Decl id -> (
      match Hashtbl.find_opt index.Index.decls id with
      | Some e ->
          let doc = documentation a e in
          Some (code e.Index.detail ^ (if doc = "" then "" else "\n\n" ^ doc) ^ "\n\nDeclared in `" ^ e.Index.package ^ "`.")
      | None -> None)
  | Uses.Field (tid, name) ->
      Option.map
        (fun ty -> code (Printf.sprintf "%s %s" name (Ty.to_string ty)) ^ "\n\nIn `" ^ tid.Ty.package ^ "$" ^ tid.Ty.name ^ "`.")
        (Hashtbl.find_opt index.Index.fields (tid, name))
  | Uses.Member (tid, name) -> Some (code (tid.Ty.name ^ "." ^ name) ^ "\n\nA member of `" ^ tid.Ty.package ^ "$" ^ tid.Ty.name ^ "`.")
  | Uses.Label (id, name) ->
      Option.map
        (fun (e : Index.entry) -> code name ^ "\n\nA field of the constructor `" ^ e.Index.detail ^ "`.")
        (Hashtbl.find_opt index.Index.decls id)
  | Uses.Local id -> Option.map (fun l -> code (local_description l)) (Hashtbl.find_opt index.Index.locals id)
  | Uses.Param id ->
      Option.map
        (fun (p : Ty.param) ->
          code (p.Ty.name ^ match p.Ty.kind with Ty.Type_kind -> " Type" | Ty.Number_kind -> " @concepts$Int")
          ^ "\n\nA generic parameter.")
        (Hashtbl.find_opt index.Index.params id)
  | Uses.Package p -> Some (code ("package " ^ p))
  | Uses.Intrinsic spelling -> (
      let ns, name =
        match String.index_opt spelling '$' with
        | Some i when String.length spelling > 1 -> (String.sub spelling 1 (i - 1), String.sub spelling (i + 1) (String.length spelling - i - 1))
        | _ -> ("", spelling)
      in
      let functions = Tst.Intrinsics.find_functions ns name in
      match (Tst.Intrinsics.find_value ns name, functions) with
      | Some ty, _ -> Some (code (spelling ^ " " ^ Ty.to_string ty))
      | None, (_ :: _ as fs) -> Some (code (String.concat "\n" (List.map Tst.Signature.to_string fs)))
      | None, [] -> Some (code spelling))

(* ---------------------------------------------------------------------- *)
(* Semantic tokens                                                        *)
(* ---------------------------------------------------------------------- *)

let token_types =
  [ "namespace"; "type"; "enum"; "struct"; "typeParameter"; "parameter"; "variable"; "property"; "enumMember"; "function"; "method"; "operator" ]

let token_modifiers = [ "declaration"; "readonly"; "defaultLibrary" ]

let token_index name =
  let rec find i = function [] -> 0 | x :: rest -> if String.equal x name then i else find (i + 1) rest in
  find 0 token_types

let classify (index : Index.t) (u : Uses.use) =
  let kind, readonly, library =
    match u.Uses.target with
    | Uses.Package _ -> (Some "namespace", false, false)
    | Uses.Decl id -> (
        match Hashtbl.find_opt index.Index.decls id with
        | Some e -> (
            match e.Index.kind with
            | Index.Struct | Index.Variant | Index.Handle | Index.Distinct | Index.Alias -> (Some "type", false, false)
            | Index.Enum -> (Some "enum", false, false)
            | Index.Constant -> (Some "variable", true, false)
            | Index.Function | Index.Constructor | Index.Flip -> (Some "function", false, false)
            | Index.Method | Index.Subscript -> (Some "method", false, false)
            | Index.Operator -> (Some "operator", false, false)
            | Index.Enum_map -> (Some "property", true, false))
        | None -> (None, false, false))
    | Uses.Field _ -> (Some "property", false, false)
    | Uses.Member _ -> (Some "enumMember", false, false)
    | Uses.Local id -> (
        match Hashtbl.find_opt index.Index.locals id with
        | Some l when Hashtbl.mem index.Index.parameters l.Tst.Nodes.Local.id -> (Some "parameter", false, false)
        | _ -> (Some "variable", false, false))
    | Uses.Param _ -> (Some "typeParameter", false, false)
    | Uses.Label _ -> (Some "parameter", false, false)
    | Uses.Intrinsic spelling ->
        let name = match String.index_opt spelling '$' with Some i -> String.sub spelling (i + 1) (String.length spelling - i - 1) | None -> spelling in
        if name <> "" && Cst.is_upper_identifier name then (Some "type", false, true) else (Some "function", false, true)
  in
  Option.map
    (fun k ->
      let bits = (if u.Uses.declaration then 1 else 0) lor (if readonly then 2 else 0) lor if library then 4 else 0 in
      (token_index k, bits))
    kind

let semantic_tokens encoding t (a : P.analysis) path =
  match (index_of a, view t a path) with
  | Some index, Some v ->
      let tokens =
        List.filter_map
          (fun (u : Uses.use) ->
            if not (String.equal (span_path u.Uses.span) path) then None
            else
              match (Text.move v.shift (span_offsets u.Uses.span), classify index u) with
              | Some (start, stop), Some (kind, bits) when stop > start ->
                  let line, character = Text.position encoding v.lines start in
                  let eline, echaracter = Text.position encoding v.lines stop in
                  if eline <> line then None else Some (line, character, echaracter - character, kind, bits)
              | _ -> None)
          index.Index.uses
        |> List.sort_uniq compare
      in
      (* Two uses can cover one name, as an import's member names every
         overload it brings; a token is sent once, and never overlapping. *)
      let rec dedupe kept = function
        | (l1, c1, n1, k, b) :: (l2, c2, _, _, _) :: rest when l1 = l2 && c2 < c1 + n1 -> dedupe kept ((l1, c1, n1, k, b) :: rest)
        | x :: rest -> dedupe (x :: kept) rest
        | [] -> List.rev kept
      in
      let tokens = dedupe [] tokens in
      let _, _, data =
        List.fold_left
          (fun (pl, pc, acc) (l, c, n, k, b) ->
            let dl = l - pl in
            let dc = if dl = 0 then c - pc else c in
            (l, c, b :: k :: n :: dc :: dl :: acc))
          (0, 0, []) tokens
      in
      `Assoc [ ("data", `List (List.rev_map (fun i -> `Int i) data)) ]
  | _ -> `Assoc [ ("data", `List []) ]

(* ---------------------------------------------------------------------- *)
(* Document symbols, from the file's own syntax                          *)
(* ---------------------------------------------------------------------- *)

(* LSP's numbers for the kinds of symbol. *)
let symbol_kind = function
  | `Type -> 5 (* class *)
  | `Struct -> 23
  | `Enum -> 10
  | `Alias -> 26 (* type parameter *)
  | `Constant -> 14
  | `Function -> 12
  | `Method -> 6
  | `Operator -> 25
  | `Constructor -> 9
  | `Field -> 8
  | `Member -> 22
  | `Property -> 7
  | `Package -> 4

let document_symbols encoding (d : P.document) =
  let text = match (d.P.parse_error, d.P.parsed) with Some _, Some good -> good | _ -> d.P.text in
  match Cst.parse d.P.path text with
  | Error _ | (exception _) -> `List []
  | Ok cst ->
      let module N = Sst.Nodes in
      let sst = Sst.of_cst cst in
      let shift = Text.shift ~before:text ~after:d.P.text and lines = Text.lines d.P.text in
      let range (s : Span.t) = Option.map (range_json encoding lines) (Text.move shift (span_offsets s)) in
      let symbol ?(children = []) name kind (whole : Span.t) (selection : Span.t) =
        match (range whole, range selection) with
        | Some r, Some sel ->
            Some
              (`Assoc
                 ([ ("name", `String name); ("kind", `Int (symbol_kind kind)); ("range", r); ("selectionRange", sel) ]
                 @ if children = [] then [] else [ ("children", `List children) ]))
        | _ -> None
      in
      let named (n : N.Name.t) = (n.N.Name.text, n.N.Name.span) in
      let members (value : N.Type_or_moulded.t) =
        match value.N.Type_or_moulded.node with
        | N.Type_or_moulded.Moulded { N.Moulded.mould; _ } -> (
            match mould.N.Mould.node with
            | N.Mould.Struct fs ->
                ( `Struct,
                  List.filter_map
                    (fun (f : N.Body_field.t) -> let n, s = named f.N.Body_field.name in symbol n `Field f.N.Body_field.span s)
                    fs )
            | N.Mould.Variant cs ->
                ( `Type,
                  List.filter_map
                    (fun (f : N.Body_field.t) -> let n, s = named f.N.Body_field.name in symbol n `Member f.N.Body_field.span s)
                    cs )
            | N.Mould.Enum ms -> (`Enum, List.filter_map (fun (m : N.Name.t) -> symbol m.N.Name.text `Member m.N.Name.span m.N.Name.span) ms)
            | N.Mould.Handle _ -> (`Type, []))
        | N.Type_or_moulded.Raw _ -> (`Type, [])
      in
      let decl (x : N.Decl.t) =
        let span = x.N.Decl.span in
        match x.N.Decl.node with
        | N.Decl.Package n -> symbol n.N.Name.text `Package span n.N.Name.span
        | N.Decl.Import _ -> None
        | N.Decl.Var { name; _ } -> symbol name.N.Name.text `Constant span name.N.Name.span
        | N.Decl.Type { name; value; _ } ->
            let kind, children = members value in
            symbol ~children name.N.Name.text kind span name.N.Name.span
        | N.Decl.Alias { name; _ } -> symbol name.N.Name.text `Alias span name.N.Name.span
        | N.Decl.EnumMap { property; _ } -> symbol property.N.Name.text `Property span property.N.Name.span
        | N.Decl.Verb v -> (
            match v.N.Verb_decl.node with
            | N.Verb_decl.Func { name; _ } -> symbol name.N.Name.text `Function span name.N.Name.span
            | N.Verb_decl.Meth { name; this_type; _ } ->
                let owner = match this_type.N.Type_expr.node with
                  | N.Type_expr.Path { name = { N.Name_type.node = N.Name_type.Ident i; _ }; _ } -> i.N.Name.text ^ ":"
                  | _ -> ""
                in
                symbol (owner ^ name.N.Name.text) `Method span name.N.Name.span
            | N.Verb_decl.Op { op; _ } -> symbol (Tst.Intrinsics.operator_token op.N.Operator.node) `Operator span op.N.Operator.span
            | N.Verb_decl.Constructor { type_; member; _ } ->
                let base = match type_.N.Type_expr.node with
                  | N.Type_expr.Path { name = { N.Name_type.node = N.Name_type.Ident i; _ }; _ } -> i.N.Name.text
                  | _ -> "constructor"
                in
                let name = match member with Some m -> base ^ "." ^ m.N.Name.text | None -> base in
                symbol name `Constructor span type_.N.Type_expr.span
            | N.Verb_decl.Subscript { this_type; _ } -> symbol "[]" `Method span this_type.N.Type_expr.span
            | N.Verb_decl.Flip _ -> symbol "~" `Operator span span)
      in
      `List (List.filter_map decl sst.N.Package.decls)

(* ---------------------------------------------------------------------- *)
(* Completion                                                             *)
(* ---------------------------------------------------------------------- *)

let placeholder_lower = "zaneLanguageServerCompletion"
let placeholder_upper = "ZaneLanguageServerCompletion"

let is_identifier_byte c = match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | c -> Char.code c >= 0x80

(* LSP's numbers for the kinds of completion item. *)
let item_kind = function
  | `Method -> 2
  | `Function -> 3
  | `Constructor -> 4
  | `Field -> 5
  | `Variable -> 6
  | `Class -> 7
  | `Module -> 9
  | `Property -> 10
  | `Enum -> 13
  | `Keyword -> 14
  | `Member -> 20
  | `Constant -> 21
  | `Struct -> 22
  | `Operator -> 24
  | `Type_parameter -> 25

let item ?detail label kind =
  `Assoc
    ([ ("label", `String label); ("kind", `Int (item_kind kind)) ]
    @ match detail with Some d -> [ ("detail", `String d) ] | None -> [])

let kind_of_entry = function
  | Index.Struct | Index.Handle | Index.Distinct | Index.Alias -> `Struct
  | Index.Variant -> `Class
  | Index.Enum -> `Enum
  | Index.Constant -> `Constant
  | Index.Function | Index.Flip -> `Function
  | Index.Constructor -> `Constructor
  | Index.Method | Index.Subscript -> `Method
  | Index.Operator -> `Operator
  | Index.Enum_map -> `Property

let is_type_kind = function
  | Index.Struct | Index.Variant | Index.Enum | Index.Handle | Index.Distinct | Index.Alias -> true
  | _ -> false

(* The texts to try, each with the placeholder where the cursor's name is,
   until one parses: the line as it is, then closed as a statement, then
   closed as a call. A name being typed rarely leaves a file that parses. *)
let attempts text ~start ~stop ~placeholder =
  let line_end = match String.index_from_opt text stop '\n' with Some i -> i | None -> String.length text in
  let with_rest rest = String.sub text 0 start ^ placeholder ^ rest in
  let tail = String.sub text stop (String.length text - stop) in
  let after_line = String.sub text line_end (String.length text - line_end) in
  [
    with_rest tail;
    with_rest (";" ^ tail);
    with_rest ("();" ^ tail);
    with_rest (";" ^ after_line);
    with_rest ("();" ^ after_line);
    with_rest (");" ^ after_line);
    with_rest ("());" ^ after_line);
  ]

let completion encoding t (d : P.document) (line, character) =
  let text = d.P.text in
  let cursor = Text.offset encoding (Text.lines text) (line, character) in
  let rec back i = if i > 0 && is_identifier_byte text.[i - 1] then back (i - 1) else i in
  let start = back cursor in
  let prefix = String.sub text start (cursor - start) in
  let trigger = if start > 0 then Some text.[start - 1] else None in
  let upper = prefix <> "" && Cst.is_upper_identifier prefix in
  let placeholder = if upper then placeholder_upper else placeholder_lower in
  let stop =
    let rec forward i = if i < String.length text && is_identifier_byte text.[i] then forward (i + 1) else i in
    forward cursor
  in
  let parses candidate = match Cst.parse d.P.path candidate with Ok _ -> true | Error _ -> false | exception _ -> false in
  let found = List.find_opt parses (attempts text ~start ~stop ~placeholder) in
  let analysis =
    match (found, P.build_of t d.P.path) with
    | Some candidate, Some (_, b) -> (
        try Some (P.analyze ~override:[ (d.P.path, candidate) ] ~placeholder t b) with _ -> None)
    | _ -> None
  in
  let index = Option.bind analysis index_of in
  let fallback = Option.bind (P.build_of t d.P.path) (fun (_, b) -> Option.bind (P.ensure t b) index_of) in
  let names (index : Index.t) ~types =
    let entries, qualifiers = index.Index.in_scope ~path:d.P.path in
    let entries =
      List.filter_map
        (fun (name, kind, detail) ->
          if is_type_kind kind = types && kind <> Index.Operator && kind <> Index.Subscript && kind <> Index.Constructor
             && kind <> Index.Method && kind <> Index.Flip
          then Some (item ~detail name (kind_of_entry kind))
          else None)
        entries
    in
    entries @ List.map (fun q -> item ~detail:"package" q `Module) qualifiers
  in
  let keywords = List.map (fun k -> item k `Keyword) Cst.keywords in
  let probe = Option.bind index (fun (index : Index.t) -> match index.Index.probes with (_, p) :: _ -> Some (index, p) | [] -> None) in
  let member_item (name, k, detail) =
    item ~detail name
      (match k with
      | Index.Field_member -> `Field
      | Index.Case_member -> `Member
      | Index.Enum_member -> `Member
      | Index.Map_member -> `Property
      | Index.Method_member -> `Method)
  in
  let items =
    match (probe, trigger) with
    | Some (index, Uses.Member_of { ty; package; path }), _ ->
        let methods = trigger = Some ':' || trigger = Some '!' in
        index.Index.members_of ty ~package ~path
        |> List.filter (fun (_, k, _) -> if methods then k = Index.Method_member else k <> Index.Method_member)
        |> List.map member_item
    | Some (index, Uses.Type_member_of ty), _ -> List.map member_item (index.Index.type_members_of ty)
    | Some (index, Uses.Name_in { locals; _ }), _ ->
        List.map (fun (l : Tst.Nodes.Local.t) -> item ~detail:(Ty.to_string l.Tst.Nodes.Local.ty) l.Tst.Nodes.Local.name `Variable) locals
        @ names index ~types:false @ keywords
    | Some (index, Uses.Type_in { params; _ }), _ ->
        List.map (fun p -> item p `Type_parameter) params @ names index ~types:true
    | None, Some ('.' | ':' | '!') -> []
    | None, _ -> (match fallback with Some index -> names index ~types:upper | None -> []) @ keywords
  in
  let items =
    List.filter
      (function
        | `Assoc fields -> (
            match List.assoc_opt "label" fields with
            | Some (`String l) -> String.starts_with ~prefix l && not (String.equal l placeholder)
            | _ -> false)
        | _ -> false)
      items
  in
  let seen = Hashtbl.create 64 in
  let items = List.filter (fun i -> if Hashtbl.mem seen i then false else (Hashtbl.add seen i (); true)) items in
  `Assoc [ ("isIncomplete", `Bool false); ("items", `List items) ]

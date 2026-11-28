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

let code s = "```zane\n" ^ s ^ "\n```"

(* ---------------------------------------------------------------------- *)
(* Intrinsics                                                             *)
(* ---------------------------------------------------------------------- *)

module I = Tst.Intrinsics

(* An intrinsic's spelling, `@math$sqrt`, as its namespace and the name
   after `$`. *)
let split_spelling spelling =
  match String.index_opt spelling '$' with
  | Some i when String.length spelling > 1 && spelling.[0] = '@' ->
      (String.sub spelling 1 (i - 1), String.sub spelling (i + 1) (String.length spelling - i - 1))
  | _ -> ("", spelling)

let is_intrinsic_type ns name =
  Option.is_some (I.find_type ns name) || (ns = "concepts" && List.mem name I.concept_names)

(* The declaration lines a hover shows for [spelling]: a value's type, or a
   type and its constructors, or each overload a call to it may choose. *)
let intrinsic_lines spelling =
  let ns, name = split_spelling spelling in
  match I.find_value ns name with
  | Some ty -> [ spelling ^ " " ^ Ty.to_string ty ]
  | None ->
      let head = if is_intrinsic_type ns name then [ "type " ^ spelling ] else [] in
      head @ List.sort_uniq compare (List.map I.signature_text (I.signatures spelling))

let intrinsic_hover spelling =
  let ns, _ = split_spelling spelling in
  let lines = match intrinsic_lines spelling with [] -> [ spelling ] | ls -> ls in
  let doc = match Tst.Intrinsic_docs.find spelling with Some d -> "\n\n" ^ d | None -> "" in
  code (String.concat "\n" lines) ^ doc ^ "\n\nAn intrinsic of `@" ^ ns ^ "$`."

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
  | Uses.Intrinsic spelling -> Some (intrinsic_hover spelling)

(* ---------------------------------------------------------------------- *)
(* Semantic tokens                                                        *)
(* ---------------------------------------------------------------------- *)

let token_types =
  [ "namespace"; "type"; "enum"; "struct"; "typeParameter"; "parameter"; "variable"; "property"; "enumMember"; "function"; "method"; "operator" ]

let token_modifiers = [ "declaration"; "readonly" ]

let token_index name =
  let rec find i = function [] -> 0 | x :: rest -> if String.equal x name then i else find (i + 1) rest in
  find 0 token_types

(* An intrinsic gets no token: its `@` makes it plain in the syntax, so the
   Tree-sitter query colors it, and the color stays while the server's
   analysis is out of date. *)
let classify (index : Index.t) (u : Uses.use) =
  let kind, readonly =
    match u.Uses.target with
    | Uses.Package _ -> (Some "namespace", false)
    | Uses.Decl id -> (
        match Hashtbl.find_opt index.Index.decls id with
        | Some e -> (
            match e.Index.kind with
            | Index.Struct | Index.Variant | Index.Handle | Index.Distinct | Index.Alias -> (Some "type", false)
            | Index.Enum -> (Some "enum", false)
            | Index.Constant -> (Some "variable", true)
            | Index.Function | Index.Constructor | Index.Flip -> (Some "function", false)
            | Index.Method | Index.Subscript -> (Some "method", false)
            | Index.Operator -> (Some "operator", false)
            | Index.Enum_map -> (Some "property", true))
        | None -> (None, false))
    | Uses.Field _ -> (Some "property", false)
    | Uses.Member _ -> (Some "enumMember", false)
    | Uses.Local id -> (
        match Hashtbl.find_opt index.Index.locals id with
        | Some l when Hashtbl.mem index.Index.parameters l.Tst.Nodes.Local.id -> (Some "parameter", false)
        | _ -> (Some "variable", false))
    | Uses.Param _ -> (Some "typeParameter", false)
    | Uses.Label _ -> (Some "parameter", false)
    | Uses.Intrinsic _ -> (None, false)
  in
  Option.map
    (fun k ->
      let bits = (if u.Uses.declaration then 1 else 0) lor (if readonly then 2 else 0) in
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

(* The outline of the current text: every declaration that parses, read
   past the syntax errors in the others ([Cst.parse_recovering]). Unlike the
   build's answers, it needs no earlier text: a declaration is listed as soon
   as it is written, and only the ones that do not parse yet are missing. *)
let document_symbols encoding (d : P.document) =
  match Cst.parse_recovering d.P.path d.P.text with
  | exception _ -> `List []
  | cst, _ ->
      let module N = Sst.Nodes in
      let sst = Sst.of_cst cst in
      let lines = Text.lines d.P.text in
      let range (s : Span.t) = Some (range_json encoding lines (span_offsets s)) in
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
        | N.Decl.Import _ | N.Decl.ExportLine _ -> None
        | N.Decl.Var { name; _ } | N.Decl.ExportedVar { name; _ } -> symbol name.N.Name.text `Constant span name.N.Name.span
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

let item ?detail ?documentation ?insert label kind =
  `Assoc
    ([ ("label", `String label); ("kind", `Int (item_kind kind)) ]
    @ (match detail with Some d -> [ ("detail", `String d) ] | None -> [])
    @ (match documentation with
      | Some d -> [ ("documentation", `Assoc [ ("kind", `String "markdown"); ("value", `String d) ]) ]
      | None -> [])
    @ match insert with Some t -> [ ("insertText", `String t) ] | None -> [])

(* Where the cursor's name stands after an intrinsic's namespace. *)
type intrinsic_site =
  | Namespace_name  (** after `@` *)
  | Namespace_member of { namespace : string; call : [ `Read | `Mut ] option }
      (** after `@namespace$`; [call] is the `:` (a read) or `!` (a `mut` call) of a method name *)
  | Named_constructor of { namespace : string; type_ : string }  (** after `@namespace$Type.` *)

(* The intrinsic site of a name that starts at [start] in [text], read from
   the characters before it. A method's name follows `:` or `!` before the
   `@`. *)
let intrinsic_site text start =
  let rec back i = if i > 0 && is_identifier_byte text.[i - 1] then back (i - 1) else i in
  let char_at i = if i >= 0 && i < String.length text then Some text.[i] else None in
  (* The namespace whose `$` sits at [dollar], and where its `@` is. *)
  let namespace_before dollar =
    let ns_start = back dollar in
    if ns_start < dollar && char_at (ns_start - 1) = Some '@' then Some (String.sub text ns_start (dollar - ns_start), ns_start - 1)
    else None
  in
  match char_at (start - 1) with
  | Some '@' -> Some Namespace_name
  | Some '$' -> (
      match namespace_before (start - 1) with
      | Some (namespace, at) ->
          let call = match char_at (at - 1) with Some ':' -> Some `Read | Some '!' -> Some `Mut | _ -> None in
          Some (Namespace_member { namespace; call })
      | None -> None)
  | Some '.' -> (
      let dot = start - 1 in
      let type_start = back dot in
      if type_start < dot && char_at (type_start - 1) = Some '$' then
        match namespace_before (type_start - 1) with
        | Some (namespace, _) -> Some (Named_constructor { namespace; type_ = String.sub text type_start (dot - type_start) })
        | None -> None
      else None)
  | _ -> None

(* A completion item's detail: the first of the declaration lines, and how
   many more there are. *)
let intrinsic_detail lines =
  match lines with
  | [] -> None
  | [ l ] -> Some l
  | l :: rest -> Some (Printf.sprintf "%s (+%d more)" l (List.length rest))

(* [subject] is the type of the value before `:` or `!`, when the check
   reached the cursor and found it. *)
let intrinsic_items site ~types_only ~subject ~root =
  let doc spelling = Tst.Intrinsic_docs.find spelling in
  match site with
  | Namespace_name ->
      List.filter_map
        (fun ns ->
          if ns = "program" && not root then None
          else Some (item ?documentation:(doc ("@" ^ ns ^ "$")) ~insert:(ns ^ "$") ns `Module))
        I.namespaces
  | Namespace_member { namespace; _ } when namespace = "program" && not root -> []
  | Namespace_member { namespace; call } ->
      let method_ = Option.is_some call in
      (* A method is called with `!` exactly when it is `mut`, and its subject
         takes the value before the `!` or `:`. *)
      let callable (s : Tst.Signature.t) =
        s.Tst.Signature.is_mut = (call = Some `Mut)
        && match subject with Some t -> Index.subject_fits s t | None -> true
      in
      List.filter_map
        (fun (e : I.entry) ->
          let wanted =
            match e.I.kind with
            | I.Method_entry -> (
                method_ && List.exists callable e.I.signatures)
            | I.Type_entry -> not method_
            | I.Value_entry | I.Function_entry -> not (method_ || types_only)
          in
          if not wanted then None
          else
            let spelling = I.spelling_of e in
            let kind =
              match e.I.kind with
              | I.Type_entry -> `Struct
              | I.Value_entry -> `Constant
              | I.Function_entry -> `Function
              | I.Method_entry -> `Method
            in
            let lines =
              match e.I.kind with
              | I.Type_entry | I.Value_entry -> intrinsic_lines spelling
              | I.Function_entry | I.Method_entry -> List.sort_uniq compare (List.map I.signature_text e.I.signatures)
            in
            Some (item ?detail:(intrinsic_detail lines) ?documentation:(doc spelling) e.I.name kind))
        (I.find_entries namespace)
  | Named_constructor { namespace; type_ } ->
      List.map
        (fun (member, sigs) ->
          let spelling = "@" ^ namespace ^ "$" ^ type_ ^ "." ^ member in
          let detail = match sigs with s :: _ -> Some (I.signature_text s) | [] -> None in
          item ?detail ?documentation:(doc spelling) member `Constructor)
        (I.named_constructors namespace type_)

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
  let stop =
    let rec forward i = if i < String.length text && is_identifier_byte text.[i] then forward (i + 1) else i in
    forward cursor
  in
  let parses candidate = match Cst.parse d.P.path candidate with Ok _ -> true | Error _ -> false | exception _ -> false in
  (* The placeholder takes the case of the name typed so far. With no name
     typed after `@namespace$`, the server tries a lower-case placeholder
     first, which parses in an expression, and then an upper-case one, the
     only case the grammar takes there in a type. *)
  let placeholders =
    if prefix <> "" then [ (if Cst.is_upper_identifier prefix then placeholder_upper else placeholder_lower) ]
    else
      match intrinsic_site text start with
      | Some (Namespace_member { call = None; _ }) -> [ placeholder_lower; placeholder_upper ]
      | _ -> [ placeholder_lower ]
  in
  let placeholder, found =
    let rec first = function
      | [] -> (List.hd placeholders, None)
      | p :: rest -> (
          match List.find_opt parses (attempts text ~start ~stop ~placeholder:p) with
          | Some c -> (p, Some c)
          | None -> first rest)
    in
    first placeholders
  in
  let upper = String.equal placeholder placeholder_upper in
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
  let root =
    match (if Option.is_some index then index else fallback) with
    | Some (index : Index.t) -> index.Index.reaches_program ~path:d.P.path ~offset:start
    | None -> false
  in
  let intrinsics site =
    let types_only = match probe with Some (_, Uses.Type_in _) -> true | _ -> false in
    let subject = match probe with Some (_, Uses.Member_of { ty; _ }) -> Some ty | _ -> None in
    intrinsic_items site ~types_only ~subject ~root
  in
  let items =
    match (intrinsic_site text start, probe, trigger) with
    | Some site, _, _ -> intrinsics site
    | None, Some (index, Uses.Member_of { ty; package; path }), _ ->
        let methods = trigger = Some ':' || trigger = Some '!' in
        index.Index.members_of ty ~package ~path
        |> List.filter (fun (_, k, _) -> if methods then k = Index.Method_member else k <> Index.Method_member)
        |> List.map member_item
    | None, Some (index, Uses.Type_member_of ty), _ -> List.map member_item (index.Index.type_members_of ty)
    | None, Some (index, Uses.Name_in { locals; _ }), _ ->
        List.map (fun (l : Tst.Nodes.Local.t) -> item ~detail:(Ty.to_string l.Tst.Nodes.Local.ty) l.Tst.Nodes.Local.name `Variable) locals
        @ names index ~types:false @ keywords
    | None, Some (index, Uses.Type_in { params; _ }), _ ->
        List.map (fun p -> item p `Type_parameter) params @ names index ~types:true
    | None, None, Some ('.' | ':' | '!') -> []
    | None, None, _ -> (match fallback with Some index -> names index ~types:upper | None -> []) @ keywords
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

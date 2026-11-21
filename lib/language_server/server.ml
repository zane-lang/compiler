(* The server's loop: read what the editor sent, check what changed, and
   answer (docs/design/language-server.md). *)

module Span = Source.Span
module Uses = Tst.Uses
module Index = Tst.Index
module Ty = Tst.Ty
module P = Project
module F = Features

type json = Yojson.Safe.t

type state = {
  project : P.t;
  out : out_channel;
  mutable encoding : Text.encoding;
  (* The paths each build published diagnostics for, so a file whose last
     problem was fixed is cleared. *)
  published : (string, unit) Hashtbl.t;
  (* The problems without a file each build last showed the user, by the
     project's root and the build's label: each is shown once while it
     lasts, since a check runs after every edit (D15). *)
  shown : (string * string, string list) Hashtbl.t;
  mutable shutting_down : bool;
  (* What the client offered in `initialize`: registering file watchers
     while it runs, and edits tied to a document's version. *)
  mutable can_watch : bool;
  mutable versioned_edits : bool;
}

let field name (json : json) = match json with `Assoc fields -> List.assoc_opt name fields | _ -> None
let string_field name json = match field name json with Some (`String s) -> Some s | _ -> None
let int_field name json = match field name json with Some (`Int i) -> Some i | _ -> None

let log st message = Transport.notify st.out "window/logMessage" (`Assoc [ ("type", `Int 4); ("message", `String message) ])

let show st ~error message =
  Transport.notify st.out "window/showMessage" (`Assoc [ ("type", `Int (if error then 1 else 2)); ("message", `String message) ])

let document_path params =
  Option.bind (field "textDocument" params) (fun d -> Option.bind (string_field "uri" d) Text.path_of_uri)
  |> Option.map P.canonical

let position params =
  match field "position" params with
  | Some p -> (Option.value ~default:0 (int_field "line" p), Option.value ~default:0 (int_field "character" p))
  | None -> (0, 0)

(* ---------------------------------------------------------------------- *)
(* Diagnostics                                                            *)
(* ---------------------------------------------------------------------- *)

let diagnostic_json st lines ?range (d : Diagnostic.t) =
  let range = match range with Some r -> r | None -> F.range_json st.encoding lines (0, 0) in
  `Assoc
    [
      ("range", range);
      ("severity", `Int (match d.Diagnostic.severity with Diagnostic.Severity.Error -> 1 | Diagnostic.Severity.Warning -> 2));
      ("source", `String "zanec");
      ("message", `String d.Diagnostic.message);
    ]

let publish st path diagnostics =
  Transport.notify st.out "textDocument/publishDiagnostics"
    (`Assoc [ ("uri", `String (Text.uri_of_path path)); ("diagnostics", `List diagnostics) ])

(* Whether the server reports problems in [path]: a file of the project, and
   not of a dependency kept in a cache or of a package with a stamp. *)
let reported (p : P.project) path =
  String.starts_with ~prefix:(p.P.root ^ Filename.dir_sep) path || p.P.listed_by_zane = false

(* The diagnostics of [path] in its current text: its parse error alone
   when it does not parse (D7), and otherwise the build's problems moved
   onto the current text. *)
let file_diagnostics st a by_path path current =
  let lines = Text.lines current in
  match Hashtbl.find_opt st.project.P.documents path with
  | Some { P.parse_error = Some e; _ } ->
      let range =
        match e.Diagnostic.location with
        | Diagnostic.Location.Span s -> Some (F.range_json st.encoding lines (F.span_offsets s))
        | _ -> None
      in
      [ diagnostic_json st lines ?range e ]
  | _ ->
      let view = F.view st.project a path in
      let placed ((d : Diagnostic.t), s) =
        match (s, view) with
        | None, _ -> Some (diagnostic_json st lines d)
        | Some s, Some v ->
            Option.map
              (fun r -> diagnostic_json st lines ~range:(F.range_json st.encoding lines r) d)
              (Text.move v.F.shift (F.span_offsets s))
        | Some _, None -> None
      in
      List.filter_map placed (List.rev (Hashtbl.find_all by_path path))

(* Publishes [path]'s diagnostics when [b] is the build that checks it, and
   clears a file whose last problem was fixed. *)
let publish_file st (p : P.project) (b : P.build) a by_path path =
  let owner = match P.build_of st.project path with Some (_, owner) -> owner == b | None -> false in
  match P.text_of st.project path with
  | Some current when owner && reported p path ->
      let diagnostics = file_diagnostics st a by_path path current in
      if diagnostics <> [] || Hashtbl.mem st.published path then begin
        publish st path diagnostics;
        if diagnostics = [] then Hashtbl.remove st.published path else Hashtbl.replace st.published path ()
      end
  | _ -> ()

(* Publishes the problems of every file whose build is [b]. A document that
   does not parse shows its parse error alone, since the build read its last
   text that parsed (D7). *)
let publish_build st (p : P.project) (b : P.build) =
  match P.ensure st.project b with
  | None -> ()
  | Some a ->
      let by_path = Hashtbl.create 16 in
      let elsewhere = ref [] in
      List.iter
        (fun (d : Diagnostic.t) ->
          match d.Diagnostic.location with
          | Diagnostic.Location.Span s -> Hashtbl.add by_path (F.span_path s) (d, Some s)
          | Diagnostic.Location.File path -> Hashtbl.add by_path (P.canonical path) (d, None)
          | Diagnostic.Location.Directory dir -> elsewhere := (dir ^ ": " ^ d.Diagnostic.message) :: !elsewhere
          | Diagnostic.Location.Invocation ->
              elsewhere := (b.P.label ^ ": " ^ d.Diagnostic.message) :: !elsewhere)
        a.P.problems;
      let messages = List.rev !elsewhere in
      let key = (p.P.root, b.P.label) in
      let before = Option.value ~default:[] (Hashtbl.find_opt st.shown key) in
      List.iter
        (fun message ->
          log st message;
          if not (List.mem message before) then show st ~error:true message)
        messages;
      Hashtbl.replace st.shown key messages;
      let files =
        Hashtbl.fold (fun path _ acc -> path :: acc) a.P.texts []
        @ Hashtbl.fold (fun path _ acc -> path :: acc) by_path []
        @ Hashtbl.fold (fun path (d : P.document) acc -> if P.holds b d.P.path then path :: acc else acc) st.project.P.documents []
        |> List.sort_uniq String.compare
      in
      List.iter (fun path -> publish_file st p b a by_path path) files

(* A file in no build: its parse error, if it has one. *)
let publish_loose st (d : P.document) =
  let lines = Text.lines d.P.text in
  let diagnostics =
    match d.P.parse_error with
    | Some e ->
        let range =
          match e.Diagnostic.location with
          | Diagnostic.Location.Span s -> Some (F.range_json st.encoding lines (F.span_offsets s))
          | _ -> None
        in
        [ diagnostic_json st lines ?range e ]
    | None -> []
  in
  publish st d.P.path diagnostics;
  if diagnostics = [] then Hashtbl.remove st.published d.P.path else Hashtbl.replace st.published d.P.path ()

(* Checks every stale build that holds an open document, and publishes its
   problems. *)
let refresh st =
  let open_paths = Hashtbl.fold (fun path _ acc -> path :: acc) st.project.P.documents [] in
  List.iter
    (fun path ->
      match P.project_of st.project path with
      | None -> Option.iter (publish_loose st) (Hashtbl.find_opt st.project.P.documents path)
      | Some p -> (
          match P.build_of st.project path with
          | None -> Option.iter (publish_loose st) (Hashtbl.find_opt st.project.P.documents path)
          | Some (_, b) -> if b.P.stale then publish_build st p b))
    open_paths

(* ---------------------------------------------------------------------- *)
(* Requests                                                               *)
(* ---------------------------------------------------------------------- *)

(* The analysis of the build that checks [path], and what is at [pos]. *)
let at st params =
  match document_path params with
  | None -> None
  | Some path -> (
      match P.build_of st.project path with
      | None -> None
      | Some (p, b) -> (
          match P.ensure st.project b with
          | None -> None
          | Some a -> (
              match (F.index_of a, F.analyzed_offset st.encoding st.project a path (position params)) with
              | Some index, Some offset -> Option.map (fun u -> (p, a, index, u)) (F.use_at index path offset)
              | _ -> None)))

let hover st params =
  match at st params with
  | None -> `Null
  | Some (_, a, index, u) -> (
      match F.describe a index u.Uses.target with
      | None -> `Null
      | Some markdown ->
          `Assoc
            ([ ("contents", `Assoc [ ("kind", `String "markdown"); ("value", `String markdown) ]) ]
            @
            match F.range_of st.encoding st.project a u.Uses.span with
            | Some (_, range) -> [ ("range", range) ]
            | None -> []))

let definition st params =
  match at st params with
  | None -> `Null
  | Some (p, a, index, u) -> (
      let local = List.filter_map (fun (d : Uses.use) -> F.range_of st.encoding st.project a d.Uses.span) (F.declarations index u.Uses.target) in
      match local with
      | _ :: _ -> `List (List.map F.location_json local)
      | [] -> (
          (* Declared in a file another build reads, as a library's
             declaration seen from a program. *)
          match F.key_of index u.Uses.target with
          | None -> `Null
          | Some key ->
              F.uses_of_key st.project p key
              |> List.filter_map (fun ((a : P.analysis), (d : Uses.use)) ->
                     if d.Uses.declaration then F.range_of st.encoding st.project a d.Uses.span else None)
              |> List.map F.location_json
              |> fun l -> `List l))

(* The declaration of the type a name has. *)
let type_definition st params =
  match at st params with
  | None -> `Null
  | Some (_, a, index, u) -> (
      let ty =
        match u.Uses.target with
        | Uses.Local id -> Option.map (fun (l : Tst.Nodes.Local.t) -> l.Tst.Nodes.Local.ty) (Hashtbl.find_opt index.Index.locals id)
        | Uses.Field (tid, name) -> Hashtbl.find_opt index.Index.fields (tid, name)
        | Uses.Member (tid, _) -> Some (Ty.Named (tid, []))
        | _ -> None
      in
      let rec named = function Ty.Named (tid, _) -> Some tid | Ty.Reference t | Ty.Roaming t -> named t | _ -> None in
      match Option.bind ty named with
      | None -> `Null
      | Some tid ->
          let decl =
            Hashtbl.fold
              (fun id (e : Index.entry) acc ->
                if String.equal e.Index.name tid.Ty.name && String.equal e.Index.package tid.Ty.package && F.is_type_kind e.Index.kind
                then Some id
                else acc)
              index.Index.decls None
          in
          match decl with
          | None -> `Null
          | Some id ->
              `List
                (List.filter_map
                   (fun (d : Uses.use) -> Option.map F.location_json (F.range_of st.encoding st.project a d.Uses.span))
                   (F.declarations index (Uses.Decl id))))

let references st params =
  match at st params with
  | None -> `Null
  | Some (p, _, index, u) -> (
      let include_declaration =
        match Option.bind (field "context" params) (field "includeDeclaration") with Some (`Bool b) -> b | _ -> true
      in
      match F.key_of index u.Uses.target with
      | None -> `List []
      | Some key ->
          F.uses_of_key st.project p key
          |> List.filter (fun (_, (d : Uses.use)) -> include_declaration || not d.Uses.declaration)
          |> List.filter_map (fun ((a : P.analysis), (d : Uses.use)) -> F.range_of st.encoding st.project a d.Uses.span)
          |> List.map F.location_json
          |> fun l -> `List l)

(* What a rename may not change, and the name it would change. *)
let renamable (p : P.project) index (u : Uses.use) =
  let declared_in_project =
    match F.declarations index u.Uses.target with
    | d :: _ -> reported p (F.span_path d.Uses.span)
    | [] -> false
  in
  match u.Uses.target with
  | Uses.Intrinsic _ -> Error "an intrinsic cannot be renamed"
  | Uses.Package _ -> Error "a package is renamed in its manifest, not in source"
  | Uses.Local id when (match Hashtbl.find_opt index.Index.locals id with Some l -> l.Tst.Nodes.Local.name = "this" | None -> false) ->
      Error "`this` cannot be renamed"
  | _ when not declared_in_project -> Error "this is declared outside the project, in a dependency"
  | Uses.Decl id -> (
      match Hashtbl.find_opt index.Index.decls id with
      | Some { Index.kind = Index.Operator | Index.Subscript | Index.Flip; _ }
      | Some { Index.kind = Index.Constructor; name = "constructor"; _ } ->
          Error "only a declaration with a name can be renamed"
      | Some e -> Ok e.Index.name
      | None -> Error "this cannot be renamed")
  | Uses.Field (_, n) | Uses.Member (_, n) | Uses.Label (_, n) -> Ok n
  | Uses.Local id -> (match Hashtbl.find_opt index.Index.locals id with Some l -> Ok l.Tst.Nodes.Local.name | None -> Error "this cannot be renamed")
  | Uses.Param id -> (match Hashtbl.find_opt index.Index.params id with Some q -> Ok q.Ty.name | None -> Error "this cannot be renamed")

let prepare_rename st id params =
  match at st params with
  | None -> Transport.respond st.out id `Null
  | Some (p, a, index, u) -> (
      match renamable p index u with
      | Error message -> Transport.respond_error st.out id ~code:(-32602) message
      | Ok name -> (
          match F.range_of st.encoding st.project a u.Uses.span with
          | Some (_, range) -> Transport.respond st.out id (`Assoc [ ("range", range); ("placeholder", `String name) ])
          | None -> Transport.respond st.out id `Null))

(* An edit of every use of [key] from [old_name] to [new_name], by file:
   only the identifier as written, since an import's alias names the
   declaration under another spelling. The rename is refused when its edits
   could be incomplete: a build's last check failed, a use cannot be placed
   in the current text because the file does not parse, or one call names
   [key] in one instance of a generic body and another target in another. *)
let rename_edits st p key ~old_name ~new_name =
  (* Every build is brought up to date first, so a build whose check fails
     now is refused like one whose check failed before. *)
  List.iter (fun b -> ignore (P.ensure st.project b)) p.P.builds;
  let failed = List.filter (fun (b : P.build) -> b.P.failed) p.P.builds in
  if failed <> [] then
    Error (Printf.sprintf "the last check of %s failed; rename after it checks again" (List.hd failed).P.label)
  else if F.names_another_target st.project p key then
    Error "a call that names this declaration names another in some instance of a generic body"
  else
    let edits = Hashtbl.create 8 and lost = ref None in
    let add ((a : P.analysis), (d : Uses.use)) =
      let path = F.span_path d.Uses.span in
      let s0, e0 = F.span_offsets d.Uses.span in
      let analyzed = Option.map (fun text -> String.sub text s0 (e0 - s0)) (Hashtbl.find_opt a.P.texts path) in
      match (analyzed, F.view st.project a path) with
      | Some spelled, _ when not (String.equal spelled old_name) -> ()
      | _, Some v -> (
          match Text.move v.F.shift (s0, e0) with
          | Some (s, e) ->
              let edit = `Assoc [ ("range", F.range_json st.encoding v.F.lines (s, e)); ("newText", `String new_name) ] in
              Hashtbl.replace edits path ((s, edit) :: Option.value ~default:[] (Hashtbl.find_opt edits path))
          | None -> lost := Some path)
      | _, None -> lost := Some path
    in
    List.iter add (F.uses_of_key st.project p key);
    match !lost with
    | Some path -> Error (Printf.sprintf "%s does not parse where `%s` is used; rename after fixing it" path old_name)
    | None ->
        (* Last edit first: the protocol applies every edit to the original
           text, but a client applying them one by one then still edits the
           right places. *)
        let in_order es = List.sort_uniq (fun (a, _) (b, _) -> compare b a) es |> List.map snd in
        let files = Hashtbl.fold (fun path es acc -> (path, `List (in_order es)) :: acc) edits [] in
        (* A client that takes versions gets them, so it refuses edits of a
           document that changed since. *)
        if st.versioned_edits then
          let version path =
            match Hashtbl.find_opt st.project.P.documents path with Some d -> `Int d.P.version | None -> `Null
          in
          let edit (path, es) =
            `Assoc [ ("textDocument", `Assoc [ ("uri", `String (Text.uri_of_path path)); ("version", version path) ]); ("edits", es) ]
          in
          Ok (`Assoc [ ("documentChanges", `List (List.map edit files)) ])
        else Ok (`Assoc [ ("changes", `Assoc (List.map (fun (path, es) -> (Text.uri_of_path path, es)) files)) ])

let rename st id params =
  match at st params with
  | None -> Transport.respond st.out id `Null
  | Some (p, _, index, u) -> (
      let new_name = Option.value ~default:"" (string_field "newName" params) in
      match renamable p index u with
      | Error message -> Transport.respond_error st.out id ~code:(-32602) message
      | Ok old_name -> (
          (* The case of an identifier is part of what it is (lexical.md §3):
             a type stays upper-case and a value lower-case. *)
          let fits =
            if Cst.is_upper_identifier old_name then Cst.is_upper_identifier new_name
            else Cst.is_lower_identifier new_name
          in
          if not fits then
            Transport.respond_error st.out id ~code:(-32602)
              (Printf.sprintf "`%s` is not a %s identifier, as `%s` is" new_name
                 (if Cst.is_upper_identifier old_name then "upper-case" else "lower-case") old_name)
          else
            match F.key_of index u.Uses.target with
            | None -> Transport.respond st.out id `Null
            | Some key -> (
                match rename_edits st p key ~old_name ~new_name with
                | Ok edit -> Transport.respond st.out id edit
                | Error message -> Transport.respond_error st.out id ~code:(-32602) message)))

(* The document a request names: the editor's, or the file on disk when
   the editor has not opened it. *)
let with_document st params f =
  match document_path params with
  | None -> `Null
  | Some path -> (
      match Hashtbl.find_opt st.project.P.documents path with
      | Some d -> f d
      | None -> (
          match P.text_of st.project path with
          | Some text ->
              let d = { P.path; text; version = 0; parsed = None; parse_error = None } in
              P.reparse d;
              f d
          | None -> `Null))

let semantic_tokens st params =
  match document_path params with
  | None -> `Null
  | Some path -> (
      match P.build_of st.project path with
      | None -> `Assoc [ ("data", `List []) ]
      | Some (_, b) -> (
          match P.ensure st.project b with Some a -> F.semantic_tokens st.encoding st.project a path | None -> `Assoc [ ("data", `List []) ]))

(* ---------------------------------------------------------------------- *)
(* Lifecycle                                                              *)
(* ---------------------------------------------------------------------- *)

let capabilities st =
  `Assoc
    [
      ("positionEncoding", `String (match st.encoding with Text.Utf8 -> "utf-8" | Text.Utf16 -> "utf-16"));
      ( "textDocumentSync",
        `Assoc [ ("openClose", `Bool true); ("change", `Int 2); ("save", `Assoc [ ("includeText", `Bool false) ]) ] );
      ("hoverProvider", `Bool true);
      ("definitionProvider", `Bool true);
      ("typeDefinitionProvider", `Bool true);
      ("referencesProvider", `Bool true);
      ("renameProvider", `Assoc [ ("prepareProvider", `Bool true) ]);
      ("documentSymbolProvider", `Bool true);
      ( "completionProvider",
        `Assoc [ ("triggerCharacters", `List [ `String "."; `String ":"; `String "!"; `String "$" ]) ] );
      ( "semanticTokensProvider",
        `Assoc
          [
            ( "legend",
              `Assoc
                [
                  ("tokenTypes", `List (List.map (fun s -> `String s) F.token_types));
                  ("tokenModifiers", `List (List.map (fun s -> `String s) F.token_modifiers));
                ] );
            ("full", `Bool true);
          ] );
    ]

let initialize st params =
  let encodings =
    match Option.bind (field "capabilities" params) (field "general") |> fun g -> Option.bind g (field "positionEncodings") with
    | Some (`List l) -> List.filter_map (function `String s -> Some s | _ -> None) l
    | _ -> []
  in
  if List.mem "utf-8" encodings then st.encoding <- Text.Utf8;
  let offered path =
    let rec go json = function [] -> json = Some (`Bool true) | name :: rest -> go (Option.bind json (field name)) rest in
    go (Some params) ("capabilities" :: path)
  in
  st.can_watch <- offered [ "workspace"; "didChangeWatchedFiles"; "dynamicRegistration" ];
  st.versioned_edits <- offered [ "workspace"; "workspaceEdit"; "documentChanges" ];
  (match Option.bind (field "initializationOptions" params) (field "builds") with
  | Some builds ->
      let root =
        match Option.bind (string_field "rootUri" params) Text.path_of_uri with
        | Some r -> P.canonical_dir r
        | None -> Sys.getcwd ()
      in
      st.project.P.given <- Some { P.root; builds = P.builds_of_json builds; listed_by_zane = false; listing_error = None }
  | None -> ());
  `Assoc [ ("capabilities", capabilities st); ("serverInfo", `Assoc [ ("name", `String "zanec") ]) ]

(* Asks the client to tell the server when a manifest, a source file or C
   code changes on disk, where the client can watch files. *)
let watch st =
  let glob g = `Assoc [ ("globPattern", `String g) ] in
  Transport.request st.out "client/registerCapability"
    (`Assoc
       [
         ( "registrations",
           `List
             [
               `Assoc
                 [
                   ("id", `String "zane-files");
                   ("method", `String "workspace/didChangeWatchedFiles");
                   ( "registerOptions",
                     `Assoc
                       [
                         ( "watchers",
                           `List (List.map glob [ "**/zane.coda"; "**/zane-lock.coda"; "**/*.zn"; "**/*.c"; "**/*.h"; "**/c.coda" ]) );
                       ] );
                 ];
             ] );
       ])

let is_c_file path =
  List.exists (Filename.check_suffix path) [ ".c"; ".h" ] || String.equal (Filename.basename path) "c.coda"

(* A file changed on disk: a manifest reloads its project's builds, C code
   recompiles its builds' C, and a source file makes its builds stale. *)
let changed_on_disk st path =
  let base = Filename.basename path in
  if base = "zane.coda" || base = "zane-lock.coda" then
    List.iter
      (fun (p : P.project) -> if String.equal p.P.root (Filename.dirname path) then P.reload_project st.project p)
      st.project.P.projects
  else begin
    if is_c_file path then
      List.iter
        (fun (p : P.project) -> List.iter (fun (b : P.build) -> if P.holds b path then b.P.c <- P.Not_compiled) p.P.builds)
        (P.all_projects st.project);
    P.touch st.project path
  end

let apply_change st (d : P.document) (change : json) =
  match (field "range" change, string_field "text" change) with
  | Some range, Some text ->
      let pos name = match field name range with Some p -> (Option.value ~default:0 (int_field "line" p), Option.value ~default:0 (int_field "character" p)) | None -> (0, 0) in
      let lines = Text.lines d.P.text in
      let start = Text.offset st.encoding lines (pos "start") and stop = Text.offset st.encoding lines (pos "end") in
      d.P.text <- Text.replace d.P.text ~start ~stop:(max start stop) text
  | None, Some text -> d.P.text <- text
  | _ -> ()

let notification st method_ params =
  match method_ with
  | "initialized" -> if st.can_watch then watch st
  | "textDocument/didOpen" -> (
      match Option.bind (field "textDocument" params) (fun d -> Option.map (fun u -> (d, u)) (string_field "uri" d)) with
      | Some (doc, uri) -> (
          match Text.path_of_uri uri with
          | Some path ->
              let path = P.canonical path in
              let text = Option.value ~default:"" (string_field "text" doc) in
              ignore (P.open_document st.project ~path ~text ~version:(Option.value ~default:0 (int_field "version" doc)));
              P.touch st.project path;
              ignore (P.project_of st.project path)
          | None -> ())
      | None -> ())
  | "textDocument/didChange" -> (
      match document_path params with
      | Some path -> (
          match Hashtbl.find_opt st.project.P.documents path with
          | Some d ->
              (match field "contentChanges" params with Some (`List changes) -> List.iter (apply_change st d) changes | _ -> ());
              Option.iter (fun v -> d.P.version <- v) (Option.bind (field "textDocument" params) (int_field "version"));
              P.reparse d;
              P.touch st.project path
          | None -> ())
      | None -> ())
  | "textDocument/didSave" -> Option.iter (changed_on_disk st) (document_path params)
  | "textDocument/didClose" -> (
      match document_path params with
      | Some path ->
          Hashtbl.remove st.project.P.documents path;
          P.touch st.project path;
          (* A file no build checks any more, or an unsaved file the user
             discarded, keeps no diagnostics. *)
          if Hashtbl.mem st.published path && (P.build_of st.project path = None || not (Sys.file_exists path)) then begin
            publish st path [];
            Hashtbl.remove st.published path
          end
      | None -> ())
  | "workspace/didChangeWatchedFiles" -> (
      match field "changes" params with
      | Some (`List changes) ->
          List.iter
            (fun c -> Option.iter (fun p -> changed_on_disk st (P.canonical p)) (Option.bind (string_field "uri" c) Text.path_of_uri))
            changes
      | _ -> ())
  | "exit" -> exit (if st.shutting_down then 0 else 1)
  | _ -> ()

let request st id method_ params =
  let reply result = Transport.respond st.out id result in
  match method_ with
  | "initialize" -> reply (initialize st params)
  | "shutdown" ->
      st.shutting_down <- true;
      reply `Null
  | "textDocument/hover" -> reply (hover st params)
  | "textDocument/definition" | "textDocument/declaration" -> reply (definition st params)
  | "textDocument/typeDefinition" -> reply (type_definition st params)
  | "textDocument/references" -> reply (references st params)
  | "textDocument/prepareRename" -> prepare_rename st id params
  | "textDocument/rename" -> rename st id params
  | "textDocument/documentSymbol" -> reply (with_document st params (F.document_symbols st.encoding))
  | "textDocument/semanticTokens/full" -> reply (semantic_tokens st params)
  | "textDocument/completion" -> reply (with_document st params (fun d -> F.completion st.encoding st.project d (position params)))
  | _ -> Transport.respond_error st.out id ~code:(-32601) ("no method " ^ method_)

let guarded st f =
  try f () with
  | Diagnostic.Internal { span; message } ->
      let text = Diagnostic.render_internal ?span message in
      log st text;
      show st ~error:true ("internal compiler error: " ^ message)
  | Stack_overflow -> show st ~error:true "internal compiler error: the stack overflowed"
  | Out_of_memory -> show st ~error:true "the compiler ran out of memory"
  | e ->
      (* Any other failure ends this message's handling, not the server. *)
      let backtrace = Printexc.get_backtrace () in
      log st (Printexc.to_string e ^ if backtrace = "" then "" else "\n" ^ backtrace)

let run ?zane () =
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  let st_ref = ref None in
  let project = P.create ~zane ~log:(fun m -> match !st_ref with Some st -> log st m | None -> prerr_endline m) in
  let st = { project; out = stdout; encoding = Text.Utf16; published = Hashtbl.create 16; shown = Hashtbl.create 4; shutting_down = false; can_watch = false; versioned_edits = false } in
  st_ref := Some st;
  let queue = Transport.start stdin in
  (* Messages are handled in the order they came. An edit only marks its
     builds stale; the check runs once, before the next request that needs
     it or after the last message waiting, so a burst of keystrokes is
     checked once (D10). *)
  let rec loop () =
    let messages = Transport.take queue in
    let closed =
      List.fold_left
        (fun closed message ->
          if closed then closed
          else
            match message with
            | Transport.Notification { method_; params } ->
                guarded st (fun () -> notification st method_ params);
                false
            | Transport.Request { id; _ } when st.shutting_down ->
                Transport.respond_error st.out id ~code:(-32600) "the server is shutting down";
                false
            | Transport.Request { id; method_; params } ->
                if method_ <> "initialize" && method_ <> "shutdown" then guarded st (fun () -> refresh st);
                let answered = ref false in
                guarded st (fun () ->
                    request st id method_ params;
                    answered := true);
                if not !answered then Transport.respond_error st.out id ~code:(-32603) "the compiler failed on this request";
                false
            | Transport.Response _ -> false
            | Transport.Unreadable ->
                Transport.respond_error st.out `Null ~code:(-32700) "the message is not a JSON-RPC message";
                false
            | Transport.Closed -> true)
        false messages
    in
    if not st.shutting_down then guarded st (fun () -> refresh st);
    if not closed then loop ()
  in
  loop ()

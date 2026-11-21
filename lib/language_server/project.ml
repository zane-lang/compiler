(* What the server knows about the files an editor works on: the open
   documents, the builds of each project, and each build's last analysis
   (docs/design/language-server.md). *)

module Assembly = Tst.Assembly
module Span = Source.Span

(* A file the editor has open. [parsed] is its last text that parsed, which
   the build reads while the current text does not parse (D7). *)
type document = {
  path : string;
  mutable text : string;
  mutable version : int;
  mutable parsed : string option;
  mutable parse_error : Diagnostic.t option;
}

(* One build of a project, as `zane builds` lists it. *)
type build = {
  label : string;
  flags : Driver.Build_flags.t;
  (* The directory of each package, as an absolute path without symbolic
     links: what a document's path is compared with. *)
  dirs : string list;
  (* The interfaces of the packages' C code, compiled when the build loads
     and again when a C file of the build is saved (D12). *)
  mutable c : c_code;
  mutable c_problems : Diagnostic.t list;
  mutable analysis : analysis option;
  mutable stale : bool;
  (* Whether the last check of the current inputs failed, so [analysis] is
     an earlier one: answers may read it, a rename may not. *)
  mutable failed : bool;
}

(* A build's C code: not compiled yet, compiled, or refused, which is not
   tried again until a C file changes. *)
and c_code = Not_compiled | Compiled of Foreign.package list | Refused

and analysis = {
  packages : Assembly.package list;
  (* The text each file had when the build read it. *)
  texts : (string, string) Hashtbl.t;
  result : Driver.analysis option;
  (* Every problem, by the path it points into; a problem with no file under
     the empty path. *)
  problems : Diagnostic.t list;
}

type project = {
  root : string;
  mutable builds : build list;
  (* Where the builds came from: `zane builds` in [root], or the client's
     initialization options. *)
  listed_by_zane : bool;
  (* What `zane builds` reported when it failed. *)
  mutable listing_error : string option;
}

type t = {
  documents : (string, document) Hashtbl.t;
  mutable projects : project list;
  (* The `zane` that lists a project's builds. *)
  zane : string option;
  (* Builds the client gave, which serve every file in their packages. *)
  mutable given : project option;
  log : string -> unit;
}

let create ~zane ~log = { documents = Hashtbl.create 16; projects = []; zane; given = None; log }

let absolute path = if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

(* A directory as the server compares directories: absolute, and without
   symbolic links when it exists. *)
let canonical_dir path =
  let path = absolute path in
  match Unix.realpath path with real -> real | exception Unix.Unix_error _ -> path

(* A file as the server compares files: its name, in its directory's
   canonical path, joined as a build joins a package directory and a file's
   name. The file's own name stays, so a link `main.zn` to `main.src` is the
   file `main.zn` that its package reads, and on Windows the separator is the
   one the build writes. *)
let canonical path =
  let path = absolute path in
  Source.Files.in_directory (canonical_dir (Filename.dirname path)) (Filename.basename path)

(* ---------------------------------------------------------------------- *)
(* Documents                                                              *)
(* ---------------------------------------------------------------------- *)

let reparse (d : document) =
  match Cst.parse d.path d.text with
  | Ok _ ->
      d.parsed <- Some d.text;
      d.parse_error <- None
  | Error e -> d.parse_error <- Some e
  | exception _ -> ()

let open_document t ~path ~text ~version =
  let d = { path; text; version; parsed = None; parse_error = None } in
  reparse d;
  Hashtbl.replace t.documents path d;
  d

(* The text of a file: the editor's, when it holds the file open. *)
let text_of t path =
  match Hashtbl.find_opt t.documents path with
  | Some d -> Some d.text
  | None -> ( try Some (In_channel.with_open_bin path In_channel.input_all) with Sys_error _ -> None)

(* ---------------------------------------------------------------------- *)
(* Builds                                                                 *)
(* ---------------------------------------------------------------------- *)

let make_build label flags =
  match Driver.Build_flags.parse flags with
  | exception Driver.Build_flags.Usage -> None
  | flags ->
      let dirs = List.map (fun (r : Assembly.request) -> canonical_dir r.Assembly.directory) flags.Driver.Build_flags.packages in
      let packages = List.map2 (fun (r : Assembly.request) dir -> { r with Assembly.directory = dir }) flags.packages dirs in
      Some { label; flags = { flags with packages }; dirs; c = Not_compiled; c_problems = []; analysis = None; stale = true; failed = false }

(* Builds as JSON gives them: [{"label": ..., "flags": [...]}, ...]. *)
let builds_of_json (json : Yojson.Safe.t) =
  let one = function
    | `Assoc fields -> (
        let label = match List.assoc_opt "label" fields with Some (`String s) -> s | _ -> "build" in
        match List.assoc_opt "flags" fields with
        | Some (`List flags) ->
            make_build label (List.filter_map (function `String s -> Some s | _ -> None) flags)
        | _ -> None)
    | _ -> None
  in
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "builds" fields with Some (`List l) -> List.filter_map one l | _ -> [])
  | `List l -> List.filter_map one l
  | _ -> []

(* Runs `zane builds` in [root] and reads what it prints. Its progress and
   problems go to standard error, which the editor keeps as the server's
   log. Its standard input is empty: the server's own carries the editor's
   messages, which `zane` must not read. *)
let list_builds ~zane root =
  let nothing = Unix.openfile (if Sys.win32 then "NUL" else "/dev/null") [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  let out_read, out_write =
    try Unix.pipe ~cloexec:true ()
    with e ->
      Unix.close nothing;
      raise e
  in
  let previous = Sys.getcwd () in
  match
    Fun.protect
      ~finally:(fun () -> Sys.chdir previous)
      (fun () ->
        Sys.chdir root;
        Unix.create_process zane [| zane; "builds" |] nothing out_write Unix.stderr)
  with
  | exception Unix.Unix_error (e, _, _) ->
      Unix.close nothing;
      Unix.close out_read;
      Unix.close out_write;
      Error (Printf.sprintf "`%s builds` could not be started: %s" zane (Unix.error_message e))
  | exception Sys_error message ->
      Unix.close nothing;
      Unix.close out_read;
      Unix.close out_write;
      Error message
  | pid -> (
      Unix.close nothing;
      Unix.close out_write;
      let ic = Unix.in_channel_of_descr out_read in
      let output =
        Fun.protect ~finally:(fun () -> In_channel.close ic) (fun () -> try Ok (In_channel.input_all ic) with Sys_error m -> Error m)
      in
      match (Unix.waitpid [] pid, output) with
      | _, Error message -> Error (Printf.sprintf "`zane builds` could not be read: %s" message)
      | (_, Unix.WEXITED 0), Ok output -> (
          match Yojson.Safe.from_string output with
          | json -> Ok (builds_of_json json)
          | exception Yojson.Json_error message -> Error ("`zane builds` printed no list of builds: " ^ message))
      | _ -> Error (Printf.sprintf "`zane builds` failed in %s; run `zane check` there for the reason" root))

(* The nearest directory, the file's own or one above it, that holds a
   project's manifest. *)
let project_root path =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir "zane.coda") then Some dir
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else up parent
  in
  up (Filename.dirname path)

let load_project t root =
  match t.zane with
  | None ->
      let p = { root; builds = []; listed_by_zane = false; listing_error = Some "no `zane` to list the project's builds" } in
      t.projects <- p :: t.projects;
      p
  | Some zane ->
      let p = { root; builds = []; listed_by_zane = true; listing_error = None } in
      (match list_builds ~zane root with
      | Ok builds -> p.builds <- builds
      | Error message ->
          t.log message;
          p.listing_error <- Some message);
      t.projects <- p :: t.projects;
      p

let reload_project t (p : project) =
  if p.listed_by_zane then
    match t.zane with
    | None -> ()
    | Some zane -> (
        match list_builds ~zane p.root with
        | Ok builds ->
            p.builds <- builds;
            p.listing_error <- None
        | Error message ->
            t.log message;
            p.listing_error <- Some message)

let holds (b : build) path =
  let dir = canonical_dir (Filename.dirname path) in
  List.exists (String.equal dir) b.dirs

(* The project a file belongs to: the client's builds when one of them holds
   it, and otherwise the project of its nearest manifest. *)
let project_of t path =
  match t.given with
  | Some p when List.exists (fun b -> holds b path) p.builds -> Some p
  | _ -> (
      match project_root path with
      | None -> None
      | Some root -> (
          let root = canonical_dir root in
          match List.find_opt (fun p -> String.equal p.root root) t.projects with
          | Some p -> Some p
          | None -> Some (load_project t root)))

(* The build a file is checked in: the first that holds it (D4). *)
let build_of t path =
  match project_of t path with
  | None -> None
  | Some p -> Option.map (fun b -> (p, b)) (List.find_opt (fun b -> holds b path) p.builds)

(* ---------------------------------------------------------------------- *)
(* Analysis                                                               *)
(* ---------------------------------------------------------------------- *)

(* The text the build reads for each open document: its current text when
   that parses, and otherwise the last text that did. *)
let buffers ?(override = []) t =
  Hashtbl.fold
    (fun path (d : document) acc ->
      if List.mem_assoc path override then acc
      else
        let text = match (d.parse_error, d.parsed) with Some _, Some good -> good | _ -> d.text in
        (path, text) :: acc)
    t.documents override

let c_code t (b : build) packages =
  match b.c with
  | Compiled c -> Some c
  | Refused -> None
  | Not_compiled -> (
      match Driver.c_code ?target:b.flags.target packages with
      | Ok c ->
          b.c <- Compiled c;
          b.c_problems <- [];
          Some c
      | Error { Driver.diagnostics; _ } ->
          t.log "the build's C code did not compile";
          b.c <- Refused;
          b.c_problems <- diagnostics;
          None
      | exception e ->
          t.log ("compiling the build's C code failed: " ^ Printexc.to_string e);
          b.c <- Refused;
          None)

(* Runs the build over the current buffers. [override] replaces the text of
   files for this run alone, as a completion's placeholder does. *)
let analyze ?override ?placeholder t (b : build) =
  let flags = b.flags in
  let root = Option.value flags.Driver.Build_flags.root ~default:true in
  let buffers = buffers ?override t in
  match Driver.assemble ~buffers ~root ~imports:flags.imports ~stamps:flags.stamps flags.packages with
  | Error { Driver.diagnostics; sources } ->
      let texts = Hashtbl.create 16 in
      List.iter (fun (p, s) -> Hashtbl.replace texts p s) sources;
      { packages = []; texts; result = None; problems = diagnostics }
  | Ok packages ->
      let texts = Hashtbl.create 64 in
      List.iter (fun (p, s) -> Hashtbl.replace texts p s) (Assembly.sources packages);
      let c = if placeholder = None then c_code t b packages else (match b.c with Compiled c -> Some c | Not_compiled | Refused -> None) in
      let result = Driver.analyze ?c ?placeholder packages in
      { packages; texts; result = Some result; problems = b.c_problems @ result.Driver.diagnostics }

let ensure t (b : build) =
  match (b.analysis, b.stale) with
  | a, false -> a
  | _ ->
      let a =
        try Some (analyze t b) with
        | Diagnostic.Internal { span; message } ->
            t.log (Diagnostic.render_internal ?span message);
            None
        | Stack_overflow ->
            t.log "internal compiler error: the stack overflowed";
            None
      in
      (* A failed check is not retried until the inputs change again, since
         it would fail the same way; until then answers read the last
         analysis that succeeded. *)
      (match a with Some a -> b.analysis <- Some a | None -> ());
      b.stale <- false;
      b.failed <- Option.is_none a;
      b.analysis

(* Marks every build that holds [path] as needing a new check. *)
let touch t path =
  let mark (p : project) = List.iter (fun b -> if holds b path then b.stale <- true) p.builds in
  List.iter mark t.projects;
  Option.iter mark t.given

let all_projects t = Option.to_list t.given @ t.projects

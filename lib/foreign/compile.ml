(* A package's C compiled to LLVM bitcode by the linked clang (spec ffi.md
   §2.2, docs/design/ffi.md F2, F3).

   Every C source is compiled with the fixed flags first, then the
   package's `include` and `define` rows in the order its `c.coda` writes
   them. The module comes out of the front end unoptimized but optimizable:
   `-O2` with LLVM's passes disabled, since `-O0` would mark every function
   `noinline`.

   A source's module is kept in the cache under a hash of its preprocessed
   text, the front-end command and the linked clang's version. The
   package's directory and the directory holding the headers the compiler
   gives every compilation differ between machines without changing the
   code, so both are mapped to fixed names, `/zane/pkg` and `/zane/cache`,
   in `__FILE__` and debug information by `-ffile-prefix-map`, and in the
   hash by the same substitution, and a VFS overlay makes each fixed name
   resolve to its directory. *)

(* The headers every compilation reads from the compiler: the linked
   clang's builtin headers, under `include/` of the resource directory
   named with `-resource-dir`, and `zane_ffi.h`, in a directory of its own
   given with `-isystem`. *)
type headers = { root : string; resource : string; ffi : string }

(* Every file [files] lists, written under [dir] unless already there: the
   name of the directory is a hash of their contents, so one that exists
   holds them. Each is written to a temporary of its own, created
   exclusively, and renamed into place, so builds writing one directory at
   once never see half a file. A rename that fails once the file is in
   place lost to another build's, which wrote the same: Windows refuses to
   replace a file another process has open. Raises [Sys_error] when [dir]
   cannot be written. *)
let write_files dir files =
  let random = Random.State.make_self_init () in
  List.iter
    (fun (name, text) ->
      let path = Filename.concat dir name in
      if not (Sys.file_exists path) then begin
        Cache.make_dirs (Filename.dirname path);
        let temporary = Printf.sprintf "%s.%08x" path (Random.State.bits random) in
        Fun.protect
          ~finally:(fun () -> try Sys.remove temporary with Sys_error _ -> ())
          (fun () ->
            Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o644 temporary
              (fun oc -> output_string oc text);
            try Sys.rename temporary path with Sys_error _ when Sys.file_exists path -> ())
      end)
    files

(* The headers written into [root], the cache's `foreign/` directory or a
   build's own work directory when there is no cache. *)
let headers root =
  let hash files = Digest.to_hex (Digest.string (String.concat "\000" (List.concat_map (fun (n, t) -> [ n; t ]) files))) in
  let ffi_files = [ ("zane_ffi.h", Zane_ffi_header.text) ] in
  let resource = Filename.concat root ("resource-" ^ hash Builtin_headers.files) in
  let ffi = Filename.concat root ("ffi-" ^ hash ffi_files) in
  write_files (Filename.concat resource "include") Builtin_headers.files;
  write_files ffi ffi_files;
  { root; resource; ffi }

(* The flags that compile C for [cpu], the processor the program's own code
   is emitted for (Build.cpu): `-march` on x86-64, whose `-mcpu` only tunes,
   and `-mcpu` elsewhere. LLVM's default, [cpu] empty, is named as clang
   names it: the baseline `x86-64` on x86-64, `generic` on AArch64 and
   `generic-rv64` on 64-bit RISC-V. Elsewhere clang's own default is that
   baseline already, and some targets (SystemZ, LoongArch) take no `-mcpu`,
   so none is given. C then uses what the program's processor has and no
   more, whatever processor clang defaults to for the target. *)
let processor_flags ~triple cpu =
  let given baseline = if cpu = "" then baseline else cpu in
  match String.split_on_char '-' triple with
  | ("x86_64" | "x86_64h" | "amd64") :: _ -> [ "-march=" ^ given "x86-64" ]
  | ("aarch64" | "arm64") :: _ -> [ "-mcpu=" ^ given "generic" ]
  | "riscv64" :: _ -> [ "-mcpu=" ^ given "generic-rv64" ]
  | _ -> if cpu = "" then [] else [ "-mcpu=" ^ cpu ]

(* The flags every C source is compiled with, whatever its package's
   settings: C17, floating-point expressions evaluated as written, the
   build's target and processor, the headers above, and the target's C
   library headers. *)
let fixed_flags ~triple ~cpu ~headers ~include_dirs =
  [
    "-std=c17";
    "-ffp-contract=off";
    "-fno-fast-math";
    "-fno-finite-math-only";
    "-fno-associative-math";
    "-fno-rounding-math";
    "--target=" ^ triple;
  ]
  @ processor_flags ~triple cpu
  @ [
    "-O2";
    "-Xclang";
    "-disable-llvm-passes";
    "-nostdlibinc";
    "-resource-dir";
    headers.resource;
    "-isystem";
    headers.ffi;
  ]
  @ List.concat_map (function Probe.System d -> [ "-isystem"; d ] | Probe.Framework d -> [ "-iframework"; d ]) include_dirs

(* The package's own settings: its `include` rows as directories searched
   before the system's, its `define` rows as macros. *)
let package_flags dir (rows : Settings.row list) =
  List.concat_map
    (fun (row : Settings.row) ->
      match row.setting with
      | Settings.Include -> [ "-I"; Source.Files.in_directory dir row.value ]
      | Settings.Define -> [ "-D"; row.value ]
      | Settings.Source | Settings.Archive | Settings.System -> [])
    rows

(* [maps] with each directory mapped by its real path too, where that
   differs: clang names a file by the path that reached it, and macOS's
   temporary directory, under `/var`, is a link to `/private/var`. *)
let with_real_paths maps =
  List.concat_map
    (fun (from, to_) ->
      let real = try Unix.realpath from with Unix.Unix_error _ -> from in
      if real = from then [ (from, to_) ] else [ (from, to_); (real, to_) ])
    maps

(* The two directories that differ between machines, mapped to the fixed
   names they are spelled as. *)
let prefix_maps ~dir ~headers = with_real_paths [ (dir, "/zane/pkg"); (headers.root, "/zane/cache") ]

(* A JSON string holding [s]. *)
let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(* On a Windows host, the directory under which the overlay puts each
   fixed name again, which the front end searches last: a Windows path
   needs a drive to be absolute, so the front end takes `/zane/pkg/api.c`
   for a relative name and looks for it under the directories it
   searches, never at the overlay's root `/zane/pkg`. Under this one it
   finds `C:\zane-fixed/zane/pkg/api.c`, which `-ffile-prefix-map` spells
   as the fixed name again. The directory exists only in the overlay. *)
let search_root = if Sys.win32 then Some {|C:\zane-fixed|} else None

(* A clang VFS overlay that makes each fixed name a directory holding what
   the directory it stands for holds, so a path C spells through
   `__FILE__`, such as a source's `#include __FILE__`, names a file that
   exists. It is written once into [dir], named by a hash of its text,
   which the maps decide whole. *)
let overlay ~dir maps =
  let root name from =
    Printf.sprintf {|{"name":%s,"type":"directory-remap","external-contents":%s}|} (json_string name) (json_string from)
  in
  let roots (from, to_) =
    root to_ from :: Option.fold ~none:[] ~some:(fun search -> [ root (search ^ to_) from ]) search_root
  in
  let text = Printf.sprintf {|{"version":0,"roots":[%s]}|} (String.concat "," (List.concat_map roots maps)) in
  let dir = Filename.concat dir "vfs" in
  let name = Digest.to_hex (Digest.string text) ^ ".yaml" in
  write_files dir [ (name, text) ];
  Filename.concat dir name

(* The flags that spell each directory of [maps] by its fixed name, in
   `__FILE__` and debug information, and resolve that name back to it
   through an overlay written into [dir]: the cache's `foreign/` directory
   or a build's own work directory, as for the headers. `__FILE__` keeps
   the host's separator on every target, since the overlay is read with
   the host's: a Windows target's `\zane\pkg\...` names no directory on a
   Unix host. On a Windows host the flags also search [search_root] and
   spell it as nothing. *)
let map_flags ~dir maps =
  let search = Option.fold ~none:[] ~some:(fun s -> [ "-ffile-prefix-map=" ^ s ^ "="; "-idirafter"; s ]) search_root in
  List.map (fun (from, to_) -> "-ffile-prefix-map=" ^ from ^ "=" ^ to_) maps
  @ [ "-fno-file-reproducible"; "-ivfsoverlay"; overlay ~dir maps ]
  @ search

(* [args] without the overlays [map_flags] adds: an overlay's path is a
   temporary file's, and what it holds follows from the maps, which the
   arguments spell already. Nor with the flags that search
   [search_root], which only a Windows host adds, so the hash is the one
   any host computes. *)
let rec without_overlays args =
  let search = Option.map (fun s -> "-ffile-prefix-map=" ^ s ^ "=") search_root in
  match args with
  | "-ivfsoverlay" :: _ :: rest -> without_overlays rest
  | "-idirafter" :: s :: rest when Some s = search_root -> without_overlays rest
  | a :: rest when Some a = search -> without_overlays rest
  | a :: rest -> a :: without_overlays rest
  | [] -> []

(* [path] with the longest mapped directory it starts with replaced by its
   fixed name. A directory is a prefix only up to a separator, so `inc`
   does not map `include`; on Windows `\` separates too. A path under
   [search_root] is the fixed name it ends with. *)
let mapped_path maps path =
  let starts from =
    let n = String.length from in
    from <> "" && String.starts_with ~prefix:from path
    && (String.length path = n || path.[n] = '/' || path.[n] = '=' || (Sys.win32 && path.[n] = '\\'))
  in
  let after from = String.sub path (String.length from) (String.length path - String.length from) in
  let longest = List.sort (fun (a, _) (b, _) -> compare (String.length b) (String.length a)) maps in
  match search_root with
  | Some s when starts s -> after s
  | _ -> (
      match List.find_opt (fun (from, _) -> starts from) longest with
      | Some (from, to_) -> to_ ^ after from
      | None -> path)

(* [path], as [mapped_path] spells it, with the fixed name it starts with
   replaced by the directory it stands for in [maps]. *)
let unmapped_path maps path = mapped_path (List.map (fun (from, to_) -> (to_, from)) maps) path

(* A command-line argument with the directory it names mapped: a path, a
   path joined to `-I`, or the directory a `-ffile-prefix-map` maps. Any
   other text, such as a `-D` value, is kept as written. *)
let mapped_arg maps arg =
  let after prefix =
    if String.starts_with ~prefix arg then
      Some (prefix ^ mapped_path maps (String.sub arg (String.length prefix) (String.length arg - String.length prefix)))
    else None
  in
  match after "-ffile-prefix-map=" with
  | Some a -> a
  | None -> ( match after "-I" with Some a -> a | None -> mapped_path maps arg)

(* Whether [line] of preprocessed C is a line marker, `# N "file"`. *)
let marker line =
  let n = String.length line in
  n > 2 && line.[0] = '#' && line.[1] = ' ' && line.[2] >= '0' && line.[2] <= '9'

(* A line marker's file name as the path it is: clang escapes a backslash
   in it, as Windows' paths hold, as a C string does. *)
let unescaped name =
  let b = Buffer.create (String.length name) in
  let rec go i =
    if i < String.length name then
      if name.[i] = '\\' && i + 1 < String.length name then begin
        Buffer.add_char b name.[i + 1];
        go (i + 2)
      end
      else begin
        Buffer.add_char b name.[i];
        go (i + 1)
      end
  in
  go 0;
  Buffer.contents b

(* [text], preprocessed C, with the file named by each line marker mapped,
   so the hash reads the paths as `__FILE__` does, which clang's own
   prefix map already spells mapped. Only a marker's file name is a path:
   the source text itself is kept as written. *)
let mapped maps text =
  let line l =
    if not (marker l) then l
    else
      match String.index_opt l '"' with
      | None -> l
      | Some i -> (
          match String.index_from_opt l (i + 1) '"' with
          | None -> l
          | Some j ->
              String.sub l 0 (i + 1)
              ^ mapped_path maps (unescaped (String.sub l (i + 1) (j - i - 1)))
              ^ String.sub l j (String.length l - j))
  in
  String.concat "\n" (List.map line (String.split_on_char '\n' text))

(* One C source compiled, or what the front end said was wrong with it,
   and the files its code came from, each by its real path. *)
type source = { path : string; bitcode : string; key : string; includes : string list; warnings : Clang.problem list }

(* Warnings as text kept beside a cached module, one a line, its file,
   line, column and message apart by tabs, each escaped, so a module loaded
   from the cache warns as the compile that made it did. *)
let warnings_text (ws : Clang.problem list) =
  let escape s =
    let b = Buffer.create (String.length s) in
    String.iter
      (function '\\' -> Buffer.add_string b "\\\\" | '\t' -> Buffer.add_string b "\\t" | '\n' -> Buffer.add_string b "\\n" | c -> Buffer.add_char b c)
      s;
    Buffer.contents b
  in
  String.concat ""
    (List.map (fun (w : Clang.problem) -> Printf.sprintf "%s\t%d\t%d\t%s\n" (escape w.file) w.line w.column (escape w.message)) ws)

let warnings_of_text text =
  let unescape s =
    let b = Buffer.create (String.length s) in
    let n = String.length s in
    let rec go i =
      if i < n then
        if s.[i] = '\\' && i + 1 < n then begin
          Buffer.add_char b (match s.[i + 1] with 't' -> '\t' | 'n' -> '\n' | c -> c);
          go (i + 2)
        end
        else begin
          Buffer.add_char b s.[i];
          go (i + 1)
        end
    in
    go 0;
    Buffer.contents b
  in
  List.filter_map
    (fun line ->
      match String.split_on_char '\t' line with
      | [ file; l; c; message ] -> (
          match (int_of_string_opt l, int_of_string_opt c) with
          | Some line, Some column -> Some { Clang.file = unescape file; line; column; message = unescape message }
          | _ -> None)
      | _ -> None)
    (String.split_on_char '\n' text)

(* [path] with every link and `.` or `..` resolved, or as it is when it
   names nothing. *)
let real path = try Unix.realpath path with Unix.Unix_error _ -> path

(* The files [text], preprocessed C, names in its line markers, by their
   real paths: the source and every header it included. *)
let included text =
  let file line =
    if marker line then
      match String.index_opt line '"' with
      | None -> None
      | Some i -> Option.map (fun j -> String.sub line (i + 1) (j - i - 1)) (String.index_from_opt line (i + 1) '"')
    else None
  in
  List.filter_map file (String.split_on_char '\n' text) |> List.sort_uniq compare |> List.map real |> List.sort_uniq compare

(* The problems the front end reported, as diagnostics against the files
   they point into, and the text of those files. *)
let diagnostics (problems : Clang.problem list) =
  let texts = Hashtbl.create 4 in
  let text file =
    match Hashtbl.find_opt texts file with
    | Some t -> t
    | None ->
        let t = Cache.read file in
        Hashtbl.add texts file t;
        t
  in
  let located (p : Clang.problem) =
    match text p.file with
    | Some source when p.line > 0 -> (
        match Location.position ~path:p.file source ~line:p.line ~column:p.column with
        | Some position -> Diagnostic.error (Source.Span.of_loc (position, position)) p.message
        | None -> Diagnostic.in_file p.file p.message)
    | _ when p.file <> "" -> Diagnostic.in_file p.file p.message
    | _ -> Diagnostic.about_invocation p.message
  in
  let ds = List.map located problems in
  let sources = Hashtbl.fold (fun file t acc -> match t with Some t -> (file, t) :: acc | None -> acc) texts [] in
  (ds, sources)

type failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

(* What [path], an interface header, declares, compiled alone with
   [flags] (docs/design/ffi.md F6), and the warnings it gave. A header
   compiled as the main file has every `static` helper it defines unused
   and its `#pragma once` outside a header, which no source that includes
   it sees, so those warnings are not asked for. *)
let interface flags path =
  let quiet = [ "-Wno-unused"; "-Wno-pragma-once-outside-header" ] in
  let read = Clang.interface (flags @ quiet @ [ "-fsyntax-only"; "-x"; "c"; path ]) in
  if not read.ok then
    let diagnostics, sources = diagnostics read.problems in
    Error { diagnostics; sources }
  else
    match C_interface.read read.output with
    | table -> Ok (table, read.warnings)
    | exception C_interface.Malformed why -> Diagnostic.bug ("the interface table of " ^ path ^ " is malformed: " ^ why)

(* Whether [text] holds [word] anywhere. *)
let mentions word text =
  let n = String.length word and m = String.length text in
  let rec from i = i + n <= m && (String.sub text i n = word || from (i + 1)) in
  from 0

(* [path], a C source of the package in [dir], compiled with [flags], from
   the module cache under [cache] when it holds it. The key is the
   preprocessed text, which keeps neither a token's column nor the line of
   one inside a macro argument that spans lines, so a module that asks for
   either (`__builtin_COLUMN`, `__builtin_LINE`) is compiled every time
   instead. The key's tag names the form zanec makes of clang's module
   (its aliases and their linkage, the processor its functions lose), so a
   module kept in another form is compiled again. *)
let compile_source ?cache ~maps flags path =
  let args = flags @ [ "-c"; path ] in
  let preprocessed = Clang.preprocess args in
  if not preprocessed.ok then
    let diagnostics, sources = diagnostics preprocessed.problems in
    Error { diagnostics; sources }
  else
    let key =
      Digest.to_hex
        (Digest.string
           (String.concat "\000"
              [ "c-module 6"; Clang.version (); String.concat "\000" (List.map (mapped_arg maps) (without_overlays args)); mapped maps preprocessed.output ]))
    in
    let placed = List.exists (fun w -> mentions w preprocessed.output) [ "__builtin_COLUMN"; "__builtin_LINE" ] in
    let cache = if placed then None else cache in
    let kept = Option.map (fun c -> Filename.concat (Filename.concat c "foreign/module") (key ^ ".bc")) cache in
    let includes = included preprocessed.output in
    let warned = Option.map (fun k -> Filename.remove_extension k ^ ".warnings") kept in
    match Option.bind kept Cache.read with
    | Some bitcode ->
        (* The warnings are kept with their files mapped, as the key is,
           so a module compiled in another directory names this one's. *)
        let warnings = Option.fold ~none:[] ~some:warnings_of_text (Option.bind warned Cache.read) in
        let warnings = List.map (fun (w : Clang.problem) -> { w with file = unmapped_path maps w.file }) warnings in
        Ok { path; bitcode; key; includes; warnings }
    | None ->
        let compiled = Clang.compile args in
        if not compiled.ok then
          let diagnostics, sources = diagnostics compiled.problems in
          Error { diagnostics; sources }
        else begin
          (* The warnings are kept before the module, so a module in the
             cache always has its warnings beside it. *)
          Option.iter
            (fun kept ->
              let ws = List.map (fun (w : Clang.problem) -> { w with file = mapped_path maps w.file }) compiled.warnings in
              Cache.keep_string ~dir:(Filename.dirname kept) ~kept (warnings_text ws))
            warned;
          Option.iter
            (fun kept -> Cache.keep_string ~dir:(Filename.dirname kept) ~kept compiled.output)
            kept;
          (* A module compiled every time is keyed by what it compiled
             to, so nothing kept under its key outlives a change. *)
          let key = if placed then Digest.to_hex (Digest.string compiled.output) else key in
          Ok { path; bitcode = compiled.output; key; includes; warnings = compiled.warnings }
        end

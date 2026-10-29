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
   hash by the same substitution. *)

(* The headers every compilation reads from the compiler: the linked
   clang's builtin headers, under `include/` of the resource directory
   named with `-resource-dir`, and `zane_ffi.h`, in a directory of its own
   given with `-isystem`. *)
type headers = { root : string; resource : string; ffi : string }

(* Every file [files] lists, written under [dir] unless already there: the
   name of the directory is a hash of their contents, so one that exists
   holds them. Each is written to a temporary of its own, created
   exclusively, and renamed into place, so builds writing one directory at
   once never see half a file. Raises [Sys_error] when [dir] cannot be
   written. *)
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
            Sys.rename temporary path)
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

(* The flags every C source is compiled with, whatever its package's
   settings: C17, floating-point expressions evaluated as written, the
   build's target, the headers above, and the target's C library headers. *)
let fixed_flags ~triple ~headers ~include_dirs =
  [
    "-std=c17";
    "-ffp-contract=off";
    "-fno-fast-math";
    "-fno-finite-math-only";
    "-fno-associative-math";
    "-fno-rounding-math";
    "--target=" ^ triple;
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
      | Settings.Include -> [ "-I"; Filename.concat dir row.value ]
      | Settings.Define -> [ "-D"; row.value ]
      | Settings.Source | Settings.Archive | Settings.System -> [])
    rows

(* The two directories that differ between machines, mapped to the fixed
   names they are spelled as. *)
let prefix_maps ~dir ~headers = [ (dir, "/zane/pkg"); (headers.root, "/zane/cache") ]

let map_flags maps = List.map (fun (from, to_) -> "-ffile-prefix-map=" ^ from ^ "=" ^ to_) maps

(* [path] with the longest mapped directory it starts with replaced by its
   fixed name. A directory is a prefix only up to a separator, so `inc`
   does not map `include`. *)
let mapped_path maps path =
  let starts (from, _) =
    let n = String.length from in
    from <> "" && String.starts_with ~prefix:from path
    && (String.length path = n || path.[n] = '/' || path.[n] = '=')
  in
  let longest = List.sort (fun (a, _) (b, _) -> compare (String.length b) (String.length a)) maps in
  match List.find_opt starts longest with
  | Some (from, to_) ->
      let n = String.length from in
      to_ ^ String.sub path n (String.length path - n)
  | None -> path

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

(* [text], preprocessed C, with the file named by each line marker mapped,
   so the hash reads the paths as `__FILE__` does, which clang's own
   prefix map already spells mapped. Only a marker's file name is a path:
   the source text itself is kept as written. *)
let mapped maps text =
  let marker line =
    let is_digit c = c >= '0' && c <= '9' in
    let n = String.length line in
    n > 2 && line.[0] = '#' && line.[1] = ' ' && is_digit line.[2]
  in
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
              ^ mapped_path maps (String.sub l (i + 1) (j - i - 1))
              ^ String.sub l j (String.length l - j))
  in
  String.concat "\n" (List.map line (String.split_on_char '\n' text))

(* One C source compiled, or what the front end said was wrong with it. *)
type source = { path : string; bitcode : string; key : string }

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

(* Whether [text] holds [word] anywhere. *)
let mentions word text =
  let n = String.length word and m = String.length text in
  let rec from i = i + n <= m && (String.sub text i n = word || from (i + 1)) in
  from 0

(* [path], a C source of the package in [dir], compiled with [flags], from
   the module cache under [cache] when it holds it. The key is the
   preprocessed text, which keeps each token's line but not its column, so
   a module that asks for its column (`__builtin_COLUMN`) is compiled
   every time instead. *)
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
              [ "c-module"; Clang.version (); String.concat "\000" (List.map (mapped_arg maps) args); mapped maps preprocessed.output ]))
    in
    let cache = if mentions "__builtin_COLUMN" preprocessed.output then None else cache in
    let kept = Option.map (fun c -> Filename.concat (Filename.concat c "foreign/module") (key ^ ".bc")) cache in
    match Option.bind kept Cache.read with
    | Some bitcode -> Ok { path; bitcode; key }
    | None ->
        let compiled = Clang.compile args in
        if not compiled.ok then
          let diagnostics, sources = diagnostics compiled.problems in
          Error { diagnostics; sources }
        else begin
          Option.iter
            (fun kept -> Cache.keep_string ~dir:(Filename.dirname kept) ~kept compiled.output)
            kept;
          Ok { path; bitcode = compiled.output; key }
        end

(* Where the target's C library headers are (docs/design/ffi.md F1). The
   linked clang knows how to compile C for any target, but not where a
   target's `<stdio.h>` lives, so the C compiler `ZANE_CC` names is asked:
   once, on an empty source with `-E -v` for the build's target, for the
   list of directories it searches for `#include <...>`. The answer is kept
   in the cache, keyed by what changes it.

   MSVC's `cl.exe`, and `clang-cl` in its mode, print no such list: they
   search the directories of the `INCLUDE` variable, which is read in each
   build instead. *)

type dir = System of string | Framework of string

(* What kind of C compiler `ZANE_CC` is, as its `--version` (or, for
   `cl.exe`, its `/?`) says. A GCC builds for the one target it was
   configured for; a clang or `zig cc` takes `--target=`. *)
type kind = Gcc | Clang | Msvc

(* The directories a compiler searches for `#include <...>`, from its
   `-E -v` output: the lines between `#include <...> search starts here:`
   and `End of search list.`, an entry the list marks `(framework
   directory)` a framework directory. GCC, clang and `zig cc` all print it
   so. *)
let search_list output =
  let lines = String.split_on_char '\n' output |> List.map String.trim in
  let rec skip = function
    | [] -> []
    | l :: rest -> if l = "#include <...> search starts here:" then take [] rest else skip rest
  and take acc = function
    | [] -> List.rev acc
    | l :: rest ->
        if l = "End of search list." then List.rev acc
        else if l = "" then take acc rest
        else
          let suffix = " (framework directory)" in
          if String.ends_with ~suffix l then
            take (Framework (String.sub l 0 (String.length l - String.length suffix)) :: acc) rest
          else take (System l :: acc) rest
  in
  skip lines

(* What [version] says the compiler is; [name] is the file it runs, since
   `clang-cl` answers `--version` as a clang does. *)
let kind_of ~name version =
  let lower = String.lowercase_ascii version in
  let has s =
    let n = String.length s and m = String.length lower in
    let rec at i = i + n <= m && (String.sub lower i n = s || at (i + 1)) in
    at 0
  in
  let base = String.lowercase_ascii (Filename.remove_extension (Filename.basename name)) in
  if base = "cl" || base = "clang-cl" || has "microsoft (r) c/c++" then Msvc
  else if has "clang" then Clang
  else Gcc

(* [cc] run with [args], its standard input empty and its output, both
   streams, written to a file of [dir]: the output, and whether it
   succeeded. *)
let run ~dir cc args =
  let file = Filename.concat dir (Printf.sprintf "probe-%08x" (Random.bits ())) in
  let null = if Sys.win32 then "NUL" else "/dev/null" in
  let status = Sys.command (Filename.quote_command cc ~stdin:null ~stdout:file ~stderr:file args) in
  let output = Option.value ~default:"" (Cache.read file) in
  (try Sys.remove file with Sys_error _ -> ());
  (status = 0, output)

(* The directory a path names, without a trailing separator or `.` and
   `..` parts, so two spellings of one directory compare equal. *)
let canonical path =
  try Unix.realpath path with Unix.Unix_error _ -> path

(* The directories of [cc]'s own builtin headers: the one it names for
   `-print-file-name=include` and, for GCC, the `include-fixed` beside it.
   `zig cc` names none, so a directory holding clang's own
   `__stddef_max_align_t.h`, which no C library ships, is taken for one too.
   They hold the compiler's intrinsics and `<stddef.h>`, written for its own
   builtins, so the linked clang reads its own instead. *)
let builtin_dirs ~dir ~kind cc target_args =
  match run ~dir cc (target_args @ [ "-print-file-name=include" ]) with
  | true, output when not (Filename.is_relative (String.trim output)) ->
      let named = String.trim output in
      let fixed = Filename.concat (Filename.dirname named) "include-fixed" in
      List.map canonical (if kind = Gcc then [ named; fixed ] else [ named ])
  | _ -> []

let is_builtin builtins d =
  List.mem (canonical d) builtins || Sys.file_exists (Filename.concat d "__stddef_max_align_t.h")

let not_target ~cc ~triple machine =
  Printf.sprintf
    "the C compiler `%s` builds for `%s`, not for `%s`; set `ZANE_CC` to a GCC for that target, or to a clang or `zig cc`"
    cc machine triple

(* The directories [cc] searches when it compiles for [target] (the host
   when [None]), its builtin headers left out. [triple] is the build's
   target, named or the host, which a GCC must build for whether or not the
   target was named: the C is compiled for it either way. *)
let asked ~dir ~kind ~cc ~triple target =
  let target_args = match (kind, target) with Clang, Some t -> [ "--target=" ^ t ] | _ -> [] in
  let checked =
    match kind with
    | Gcc -> (
        match run ~dir cc [ "-dumpmachine" ] with
        | true, machine ->
            let machine = String.trim machine in
            if Clang.same_abi machine triple then Ok () else Error (not_target ~cc ~triple machine)
        | false, output -> Error (Printf.sprintf "the C compiler `%s` did not say its target: %s" cc (String.trim output)))
    | Clang | Msvc -> Ok ()
  in
  match checked with
  | Error _ as e -> e
  | Ok () -> (
      match run ~dir cc (target_args @ [ "-E"; "-v"; "-x"; "c"; "-" ]) with
      | false, output ->
          Error
            (Printf.sprintf "the C compiler `%s` could not be asked for `%s`'s headers:\n%s" cc triple (String.trim output))
      | true, output ->
          let builtins = builtin_dirs ~dir ~kind cc target_args in
          let dirs =
            List.filter
              (function System d | Framework d -> not (is_builtin builtins d))
              (search_list output)
          in
          Ok dirs)

(* The directories of `INCLUDE`, as MSVC reads it. *)
let msvc_dirs () =
  match Sys.getenv_opt "INCLUDE" with
  | None | Some "" ->
      Error
        "the C compiler is MSVC's, which finds the target's headers through `INCLUDE`; run the build from a Visual Studio developer shell"
  | Some dirs -> Ok (String.split_on_char ';' dirs |> List.filter (( <> ) "") |> List.map (fun d -> System d))

let encode dirs =
  String.concat "\n" (List.map (function System d -> "s" ^ d | Framework d -> "f" ^ d) dirs)

let decode text =
  String.split_on_char '\n' text
  |> List.filter_map (fun l ->
         if l = "" then None
         else
           let rest = String.sub l 1 (String.length l - 1) in
           match l.[0] with 's' -> Some (System rest) | 'f' -> Some (Framework rest) | _ -> None)

(* The variables that change where a C compiler searches. *)
let search_variables = [ "CPATH"; "C_INCLUDE_PATH"; "SDKROOT" ]

(* The include directories for a build for [target] (the host when
   [None]), whose triple is [triple], of the C compiler [cc], asked in
   [dir] and kept in [cache] under the compiler's command, the file it
   runs, its version, the target, and [search_variables]. The file it runs
   is part of the key because a bare command such as `gcc` names whichever
   one `PATH` finds first. *)
let include_dirs ?cache ~dir ~cc ~triple target =
  let _, version = run ~dir cc [ "--version" ] in
  let version = if String.trim version = "" then snd (run ~dir cc [ "/?" ]) else version in
  match kind_of ~name:cc version with
  | Msvc -> msvc_dirs ()
  | kind -> (
      let key =
        Digest.to_hex
          (Digest.string
             (String.concat "\000"
                ([ "include-dirs"; cc; Option.value ~default:"" (Cache.located cc); version; triple ]
                @ List.map (fun v -> v ^ "=" ^ Option.value ~default:"" (Sys.getenv_opt v)) search_variables)))
      in
      let kept = Option.map (fun c -> Filename.concat (Filename.concat c "foreign/include-dirs") key) cache in
      match Option.bind kept Cache.read with
      | Some text -> Ok (decode text)
      | None ->
          let answer = asked ~dir ~kind ~cc ~triple target in
          (match (answer, kept) with
          | Ok dirs, Some kept -> Cache.keep_string ~dir ~kept (encode dirs)
          | _ -> ());
          answer)

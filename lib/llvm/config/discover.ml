(* The flags the compiler's C and C++ stubs are built and linked with, and
   the files generated from the LLVM the compiler links. Both are read from
   the LLVM that `LLVM_CONFIG` names, or from `llvm-config` on PATH. Each
   mode prints one result on standard output. CCOMP is the C compiler's
   type (`%{ocaml-config:ccomp_type}`: `cc` or `msvc`), and the flags are
   written in the form that compiler type accepts.

   - `cflags`: the flags LLVM's OCaml bindings (lib/llvm) compile with, as
     a dune S-expression, and `libs CCOMP TARGETS...`: the flags they link
     with. LLVM is linked the way it was built: through its shared library
     when it has one, found again at run time through an rpath, and
     otherwise through its static libraries, as on Windows, with the system
     libraries those need.
   - `cxx CCOMP CFLAGS...` and `cxx-no-rtti CCOMP CFLAGS...`: the flags for
     C++ that includes LLVM's, clang's or LLD's headers, derived from
     OCaml's C flags (`%{ocaml-config:ocamlc_cflags}`), and `std CCOMP
     CFLAGS...`: the same flags with only the C++ standard, for C++ that
     includes none of those headers (lib/coda).
   - `clang-libs CCOMP TARGETS...` and `lld-libs CCOMP TARGETS...`: the
     flags that link clang's front end (lib/foreign) or LLD (lib/codegen)
     into the compiler. Each link mode also writes the response file in its
     rule's TARGETS, the target ending in `.rsp` (see [link]).
   - `o2-pipeline`: LLVM's own `default<O2>` pipeline as OCaml, with two
     passes added (lib/codegen/passes.ml).
   - `builtin-headers`: clang's builtin headers as OCaml (lib/foreign).

   Clang's and LLD's headers and libraries are taken from the installation
   of the `ld.lld` in LLVM's own bin directory, when that directory has one,
   as in a single conda environment. Otherwise they are taken from the
   installation of the `ld.lld` on PATH, for an installation that keeps
   clang and LLD apart from LLVM. *)

let llvm_config = match Sys.getenv_opt "LLVM_CONFIG" with Some p when p <> "" -> p | _ -> "llvm-config"

let run prog args =
  let ic = Unix.open_process_args_in prog (Array.of_list (prog :: args)) in
  let out = In_channel.input_all ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> String.trim out
  | _ -> failwith (Printf.sprintf "%s %s failed" prog (String.concat " " args))

let ask args = run llvm_config args
let words s = String.split_on_char ' ' s |> List.concat_map (String.split_on_char '\n') |> List.map String.trim |> List.filter (( <> ) "")
let shared () = ask [ "--shared-mode" ] = "shared"

(* The program [name] in [dir], also tried with the `.exe` suffix on
   Windows. *)
let program dir name =
  List.find_opt Sys.file_exists
    (Filename.concat dir name :: (if Sys.win32 then [ Filename.concat dir (name ^ ".exe") ] else []))

let on_path name =
  let sep = if Sys.win32 then ';' else ':' in
  String.split_on_char sep (Option.value (Sys.getenv_opt "PATH") ~default:"") |> List.find_map (fun dir -> program dir name)

(* The installation directory that holds clang's and LLD's headers and
   libraries. *)
let prefix () =
  let lld =
    match program (ask [ "--bindir" ]) "ld.lld" with
    | Some p -> p
    | None -> ( match on_path "ld.lld" with Some p -> p | None -> failwith "no ld.lld beside LLVM or on PATH")
  in
  Filename.dirname (Filename.dirname lld)

(* A library that llvm-config names as a file (`LLVMCore.lib`, as MSVC's
   builds do) is given by its path in the library directory when the file is
   there, because it is LLVM's own library or a dependency's in the same
   environment. Otherwise the name is given as written, for a system library
   that the linker finds. An import library that LLVM's build named
   `x.dll.lib` (zstd's) is named `x.lib` in a conda environment. *)
let library libdir word =
  if String.length word > 0 && word.[0] = '-' then word
  else
    let names =
      if Filename.check_suffix word ".dll.lib" then [ word; Filename.chop_suffix word ".dll.lib" ^ ".lib" ] else [ word ]
    in
    match List.find_opt Sys.file_exists (List.map (Filename.concat libdir) names) with Some path -> path | None -> word

(* Microsoft's DIA SDK, which an MSVC LLVM built with PDB support calls
   (LLVMDebugInfoPDB) and llvm-config does not name. It comes with Visual
   Studio, whose developer environment sets VSINSTALLDIR. Its library names
   ATL's `atls.lib` as a default library, which flexlink looks for on the
   library path. That path is the ATL directory of the developer
   environment's toolset, or else the ATL directory of any toolset in the
   installation that has one. *)
let atl vs =
  let in_toolset dir = List.fold_left Filename.concat dir [ "ATLMFC"; "lib"; "x64" ] in
  let has dir = Sys.file_exists (Filename.concat dir "atls.lib") in
  let current = Option.map in_toolset (Sys.getenv_opt "VCToolsInstallDir") in
  match current with
  | Some dir when has dir -> [ "-L" ^ dir ]
  | _ -> (
      let tools = List.fold_left Filename.concat vs [ "VC"; "Tools"; "MSVC" ] in
      let versions = try List.rev (List.sort compare (Array.to_list (Sys.readdir tools))) with Sys_error _ -> [] in
      match List.find_opt has (List.map (fun v -> in_toolset (Filename.concat tools v)) versions) with
      | Some dir -> [ "-L" ^ dir ]
      | None -> [])

let dia_sdk () =
  match Sys.getenv_opt "VSINSTALLDIR" with
  | Some vs ->
      let lib = List.fold_left Filename.concat vs [ "DIA SDK"; "lib"; "amd64"; "diaguids.lib" ] in
      if Sys.file_exists lib then atl vs @ [ lib ] else []
  | None -> []

let libs () =
  let libdir = ask [ "--libdir" ] in
  if shared () then
    [ "-L" ^ libdir ] @ (if Sys.win32 then [] else [ "-Wl,-rpath," ^ libdir ]) @ words (ask [ "--link-shared"; "--libs" ])
  else
    List.map (library libdir) (words (ask [ "--link-static"; "--libs" ]))
    @ List.map (library libdir) (words (ask [ "--link-static"; "--system-libs" ]))
    @ if Sys.win32 then dia_sdk () else []

(* The compiler builds with exactly one LLVM, the environment's (pixi.toml):
   the bindings (vendor/llvm-ocaml) and the stubs are written against LLVM
   21's interfaces. Any other LLVM version is refused here, before a stub
   fails to compile. *)
let llvm_major = "21"

let check_version () =
  let version = ask [ "--version" ] in
  match String.split_on_char '.' version with
  | major :: _ when major = llvm_major -> ()
  | _ -> failwith (Printf.sprintf "%s names LLVM %s; the compiler builds with LLVM %s (pixi.toml)" llvm_config version llvm_major)

let cflags () =
  check_version ();
  [ "-I" ^ ask [ "--includedir" ] ]
let msvc = function "msvc" -> true | "cc" -> false | c -> failwith ("unknown C compiler type " ^ c)

(* OCaml's C flags, which dune's `:standard` also passes to C++, minus the C
   standard that MSVC's OCaml names (`-std:c11`, for its C11 atomics):
   `cl` refuses a C standard next to a C++ standard. *)
let base cflags =
  List.concat_map words cflags
  |> List.filter (fun f -> not (String.starts_with ~prefix:"-std" f || String.starts_with ~prefix:"/std" f || f = "-experimental:c11atomics"))

let std ccomp cflags = base cflags @ if msvc ccomp then [ "/std:c++17" ] else [ "-std=c++17" ]

(* With MSVC and clang's static libraries, the flags add
   `CLANG_BUILD_STATIC`. Without it, clang's headers mark clang's classes
   `__declspec(dllimport)`, inline methods included, and those methods then
   refer to DLL symbols that no static library defines (an `Attr`'s
   `classof`, for example). *)
let cxx ~rtti ccomp cflags =
  let no_exceptions, no_rtti = if msvc ccomp then ([ "/EHs-c-"; "-D_HAS_EXCEPTIONS=0" ], [ "/GR-" ]) else ([ "-fno-exceptions" ], [ "-fno-rtti" ]) in
  let static = if msvc ccomp && not (shared ()) then [ "-DCLANG_BUILD_STATIC" ] else [] in
  std ccomp cflags @ no_exceptions @ (if rtti then [] else no_rtti) @ static @ [ "-I" ^ Filename.concat (prefix ()) "include"; "-I" ^ ask [ "--includedir" ] ]

(* The C++ runtime that libLLVM and these libraries were built against.
   MSVC's linker takes MSVC's C++ runtime by default. *)
let cxx_runtime ccomp = if msvc ccomp then [] else [ "-lstdc++" ]

(* Clang's front end is linked as clang's shared library when LLVM is
   shared. Otherwise it is linked as the static libraries that make up the
   front end and its code generation, completed by LLVM's own static
   libraries, which lib/llvm links. *)
let clang_static =
  [ "clangCodeGen"; "clangFrontend"; "clangDriver"; "clangParse"; "clangSema"; "clangSerialization"; "clangAnalysis";
    "clangAPINotes"; "clangEdit"; "clangAST"; "clangASTMatchers"; "clangLex"; "clangBasic"; "clangSupport"; "clangRewrite" ]

let lld_static = [ "lldCOFF"; "lldELF"; "lldMachO"; "lldMinGW"; "lldCommon" ]

(* A static library in [dir], under the file name the platform uses for
   static libraries. *)
let static dir name = Filename.concat dir (if Sys.win32 then name ^ ".lib" else "lib" ^ name ^ ".a")

let clang_libs ccomp =
  let lib = Filename.concat (prefix ()) "lib" in
  if shared () then [ "-L" ^ lib; "-lclang-cpp"; "-L" ^ ask [ "--libdir" ]; "-lLLVM" ] @ cxx_runtime ccomp
  else List.map (static lib) clang_static @ cxx_runtime ccomp

(* LLD's archives are static and compress output sections by calling zlib
   and zstd themselves, so those two are named here when LLVM was built with
   them. A shared LLVM reports only the system libraries of its static
   libraries, and libLLVM carries the rest (libxml2, for example) itself.
   For a static LLVM, lib/llvm links all of the system libraries. *)
let lld_libs ccomp =
  let lib = Filename.concat (prefix ()) "lib" in
  if shared () then
    let system = try words (ask [ "--link-static"; "--system-libs" ]) with Failure _ -> [] in
    [ "-L" ^ lib ]
    @ List.map (fun l -> "-l" ^ l) lld_static
    @ [ "-L" ^ ask [ "--libdir" ]; "-lLLVM" ]
    @ List.filter (fun l -> l = "-lz" || l = "-lzstd") system
    @ cxx_runtime ccomp
  else List.map (static lib) lld_static @ cxx_runtime ccomp

(* [pipeline] with the text [b] inserted between the first [a] that is
   immediately followed by [c] and that [c]. *)
let add pipeline a b c =
  let needle = a ^ c in
  let n = String.length needle and len = String.length pipeline in
  let rec find i =
    if i + n > len then failwith (Printf.sprintf "o2-pipeline: no %s followed by %s in: %s" a c pipeline)
    else if String.sub pipeline i n = needle then i
    else find (i + 1)
  in
  let i = find 0 + String.length a in
  String.sub pipeline 0 i ^ b ^ String.sub pipeline i (len - i)

(* The pipeline adds jump threading at the end of the first function
   simplification, once each function's locals are in registers, and
   inductive range check elimination after the loop passes that first
   rotate each loop and hoist its loads. A second pipeline is the same with
   runtime loop unrolling off, for tier 1 (docs/design/tiers.md T2). The
   pipeline text is printed by the `opt` of the LLVM that llvm-config
   describes, so it is exactly that LLVM's pipeline. *)
let o2_pipeline () =
  let opt = match program (ask [ "--bindir" ]) "opt" with Some p -> p | None -> failwith "no opt beside llvm-config" in
  let input = Filename.temp_file "o2" ".ll" in
  Out_channel.with_open_bin input (fun oc -> output_string oc "define void @f() { ret void }\n");
  let pipeline = Fun.protect ~finally:(fun () -> Sys.remove input) (fun () -> run opt [ "-passes=default<O2>"; "-print-pipeline-passes"; "-disable-output"; input ]) in
  let pipeline = add pipeline "sroa<modify-cfg>,early-cse<>" ",jump-threading" ")" in
  let pipeline = add pipeline "simple-loop-unswitch<no-nontrivial;trivial>)" ",irce" ",simplifycfg" in
  Printf.printf "let optimized = %S\n" pipeline;
  Printf.printf "let tier1 = %S\n" (add pipeline "loop-unroll<O2" ";no-runtime" ">")

(* The linked clang's own builtin headers (<stddef.h>, <stdint.h>, the
   intrinsics), as an OCaml list of each file's name and text, taken from
   clang's resource directory. They are written into the cache and named with
   `-resource-dir`, so the C compiler that is asked for the target's headers
   never supplies its own (docs/design/ffi.md F1). Only the top level is
   taken: the subdirectories wrap other languages' headers (CUDA, OpenMP,
   C++). *)
let builtin_headers () =
  let clang = Filename.concat (Filename.concat (prefix ()) "lib") "clang" in
  (* An environment may hold the resource directories of other clangs next
     to the linked clang's, as conda's does on Windows. The linked clang's
     resource directory is named after LLVM's major version. *)
  let dir = List.fold_left Filename.concat clang [ llvm_major; "include" ] in
  if not (Sys.file_exists dir) then failwith ("no clang " ^ llvm_major ^ " resource directory in " ^ clang);
  print_string "let files = [\n";
  let headers = Sys.readdir dir |> Array.to_list |> List.filter (fun f -> Filename.check_suffix f ".h") |> List.sort compare in
  headers @ [ "module.modulemap" ]
  |> List.filter (fun f -> Sys.file_exists (Filename.concat dir f) && not (Sys.is_directory (Filename.concat dir f)))
  |> List.iter (fun f ->
         Printf.printf "  (%S, {zane_header|%s|zane_header});\n" f (In_channel.with_open_bin (Filename.concat dir f) In_channel.input_all));
  print_string "]\n"

let sexp flags = print_string ("(" ^ String.concat " " (List.map (Printf.sprintf "%S") flags) ^ ")\n")

(* Link flags, written to the response file [rsp] for MSVC, where flexlink
   reads them, and given on the command line otherwise. LLVM's static
   libraries are more than cmd.exe takes on one line. [rsp] is written in
   both cases, empty when not used, because the dune rule lists it as a
   target. *)
let link ccomp rsp flags =
  if msvc ccomp then begin
    let lib = ask [ "--libdir" ] in
    (* One argument per line, quoted when it contains a space, which is the
       format flexlink reads. *)
    let line f = if String.contains f ' ' then "\"" ^ f ^ "\"" else f in
    Out_channel.with_open_bin rsp (fun oc -> List.iter (fun f -> output_string oc (line f ^ "\n")) (("-L" ^ lib) :: flags));
    let rsp = if Filename.is_relative rsp then Filename.concat (Sys.getcwd ()) rsp else rsp in
    sexp [ "@" ^ rsp ]
  end
  else begin
    Out_channel.with_open_bin rsp (fun _ -> ());
    sexp flags
  end

(* The response file among a rule's targets. *)
let rsp targets =
  match List.filter (fun t -> Filename.check_suffix t ".rsp") targets with
  | [ t ] -> t
  | _ -> failwith "expected one .rsp among the targets"

let () =
  set_binary_mode_out stdout true;
  match Array.to_list Sys.argv with
  | [ _; "cflags" ] -> sexp (cflags ())
  | _ :: "libs" :: c :: targets -> link c (rsp targets) (libs ())
  | _ :: "clang-libs" :: c :: targets -> link c (rsp targets) (clang_libs c)
  | _ :: "lld-libs" :: c :: targets -> link c (rsp targets) (lld_libs c)
  | _ :: "std" :: c :: cflags -> sexp (std c cflags)
  | _ :: "cxx" :: c :: cflags -> sexp (cxx ~rtti:true c cflags)
  | _ :: "cxx-no-rtti" :: c :: cflags -> sexp (cxx ~rtti:false c cflags)
  | [ _; "o2-pipeline" ] -> o2_pipeline ()
  | [ _; "builtin-headers" ] -> builtin_headers ()
  | _ -> failwith "usage: discover cflags|o2-pipeline|builtin-headers|(libs|clang-libs|lld-libs) CCOMP TARGETS...|(std|cxx|cxx-no-rtti) CCOMP CFLAGS..."

(* What the compiler's C and C++ stubs are built and linked with, and the
   files written from the LLVM it links, read from the LLVM that
   `LLVM_CONFIG` names, or `llvm-config` on PATH. Each mode prints one
   thing on standard output:

   - `cflags`: the flags LLVM's OCaml bindings (lib/llvm) compile with, and
     `libs` the ones they link with, as a dune S-expression. LLVM is linked
     the way it was built: its shared library where it has one, found again
     at run time through an rpath, and its static libraries otherwise, as on
     Windows, with the system libraries they need.
   - `cxx CCOMP` and `cxx-no-rtti CCOMP`: the flags C++ that includes
     LLVM's, clang's or LLD's headers compiles with, in the form the C
     compiler of type CCOMP (`%{ocaml-config:ccomp_type}`: `cc` or `msvc`)
     reads, and `std CCOMP` the C++ standard alone, for C++ that includes
     none of them (lib/coda).
   - `clang-libs CCOMP` and `lld-libs CCOMP`: what links clang's front end
     (lib/foreign) or LLD (lib/codegen) into the compiler.
   - `o2-pipeline`: LLVM's own `default<O2>` pipeline as OCaml, with two
     passes added (lib/codegen/passes.ml).
   - `builtin-headers`: clang's builtin headers as OCaml (lib/foreign).

   Clang's and LLD's headers and libraries are taken from beside the
   `ld.lld` in LLVM's own bin directory where it has one, as in one conda
   environment, and from beside the `ld.lld` on PATH otherwise, as in the
   devbox profile, which keeps them apart from LLVM's. *)

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

(* The program [name] in [dir], with Windows' `.exe` where it has one. *)
let program dir name =
  List.find_opt Sys.file_exists
    (Filename.concat dir name :: (if Sys.win32 then [ Filename.concat dir (name ^ ".exe") ] else []))

let on_path name =
  let sep = if Sys.win32 then ';' else ':' in
  String.split_on_char sep (Option.value (Sys.getenv_opt "PATH") ~default:"") |> List.find_map (fun dir -> program dir name)

(* The installation clang's and LLD's headers and libraries are in. *)
let prefix () =
  let lld =
    match program (ask [ "--bindir" ]) "ld.lld" with
    | Some p -> p
    | None -> ( match on_path "ld.lld" with Some p -> p | None -> failwith "no ld.lld beside LLVM or on PATH")
  in
  Filename.dirname (Filename.dirname lld)

(* A library llvm-config names as a file (`LLVMCore.lib`, as MSVC's builds
   do) is given by its path in the library directory, where it is LLVM's
   own, and as written otherwise, a system library the linker finds. *)
let library libdir word =
  if String.length word > 0 && word.[0] = '-' then word
  else
    let path = Filename.concat libdir word in
    if Sys.file_exists path then path else word

let libs () =
  let libdir = ask [ "--libdir" ] in
  if shared () then
    [ "-L" ^ libdir ] @ (if Sys.win32 then [] else [ "-Wl,-rpath," ^ libdir ]) @ words (ask [ "--link-shared"; "--libs" ])
  else
    List.map (library libdir) (words (ask [ "--link-static"; "--libs" ]))
    @ List.map (library libdir) (words (ask [ "--link-static"; "--system-libs" ]))

let cflags () = [ "-I" ^ ask [ "--includedir" ] ]
let msvc = function "msvc" -> true | "cc" -> false | c -> failwith ("unknown C compiler type " ^ c)
let std ccomp = if msvc ccomp then [ "/std:c++17" ] else [ "-std=c++17" ]

let cxx ~rtti ccomp =
  let no_exceptions, no_rtti = if msvc ccomp then ([ "/EHs-c-"; "-D_HAS_EXCEPTIONS=0" ], [ "/GR-" ]) else ([ "-fno-exceptions" ], [ "-fno-rtti" ]) in
  std ccomp @ no_exceptions @ (if rtti then [] else no_rtti) @ [ "-I" ^ Filename.concat (prefix ()) "include"; "-I" ^ ask [ "--includedir" ] ]

(* The C++ runtime libLLVM and these libraries were built against. MSVC's
   is the one its linker takes by default. *)
let cxx_runtime ccomp = if msvc ccomp then [] else [ "-lstdc++" ]

(* Clang's front end is its shared library where LLVM is shared, and the
   static libraries the front end and its code generation are made of
   otherwise, which LLVM's own static libraries, linked by lib/llvm,
   complete. *)
let clang_static =
  [ "clangCodeGen"; "clangFrontend"; "clangDriver"; "clangParse"; "clangSema"; "clangSerialization"; "clangAnalysis";
    "clangAPINotes"; "clangEdit"; "clangAST"; "clangASTMatchers"; "clangLex"; "clangBasic"; "clangSupport"; "clangRewrite" ]

let lld_static = [ "lldCOFF"; "lldELF"; "lldMachO"; "lldMinGW"; "lldCommon" ]

(* A static library in [dir], by the file name the platform gives it. *)
let static dir name = Filename.concat dir (if Sys.win32 then name ^ ".lib" else "lib" ^ name ^ ".a")

let clang_libs ccomp =
  let lib = Filename.concat (prefix ()) "lib" in
  if shared () then [ "-L" ^ lib; "-lclang-cpp"; "-L" ^ ask [ "--libdir" ]; "-lLLVM" ] @ cxx_runtime ccomp
  else List.map (static lib) clang_static @ cxx_runtime ccomp

(* LLD's archives are static and compress output sections by calling zlib
   and zstd themselves, so those two are named here when LLVM was built with
   them. A shared LLVM reports its system libraries only for its static
   set, and the rest (libxml2, say) libLLVM carries itself; a static one's
   are all linked by lib/llvm. *)
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

(* The text [b] put between the first [a] and the [c] that follows it at
   once. *)
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

(* Jump threading at the end of the first function simplification, once
   each function's locals are in registers, and inductive range check
   elimination after the loop passes that first rotate each loop and hoist
   what it reads. Then the same with runtime loop unrolling off, for tier 1
   (docs/design/tiers.md T2). The `opt` of the LLVM llvm-config describes
   prints it, so it is that LLVM's pipeline. *)
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
   intrinsics), as an OCaml list of each file's name and text, from its
   resource directory. They are written into the cache and named with
   `-resource-dir`, so the C compiler that is asked for the target's headers
   never supplies its own (docs/design/ffi.md F1). Only the top level is
   taken: the subdirectories wrap other languages' headers (CUDA, OpenMP,
   C++). *)
let builtin_headers () =
  let clang = Filename.concat (Filename.concat (prefix ()) "lib") "clang" in
  let dir =
    match Sys.readdir clang |> Array.to_list |> List.sort compare |> List.map (fun v -> Filename.concat (Filename.concat clang v) "include") |> List.filter Sys.file_exists with
    | d :: _ -> d
    | [] -> failwith ("no clang resource directory in " ^ clang)
  in
  print_string "let files = [\n";
  let headers = Sys.readdir dir |> Array.to_list |> List.filter (fun f -> Filename.check_suffix f ".h") |> List.sort compare in
  headers @ [ "module.modulemap" ]
  |> List.filter (fun f -> Sys.file_exists (Filename.concat dir f) && not (Sys.is_directory (Filename.concat dir f)))
  |> List.iter (fun f ->
         Printf.printf "  (%S, {zane_header|%s|zane_header});\n" f (In_channel.with_open_bin (Filename.concat dir f) In_channel.input_all));
  print_string "]\n"

let sexp flags = print_string ("(" ^ String.concat " " (List.map (Printf.sprintf "%S") flags) ^ ")\n")

let () =
  set_binary_mode_out stdout true;
  match Sys.argv with
  | [| _; "cflags" |] -> sexp (cflags ())
  | [| _; "libs" |] -> sexp (libs ())
  | [| _; "std"; c |] -> sexp (std c)
  | [| _; "cxx"; c |] -> sexp (cxx ~rtti:true c)
  | [| _; "cxx-no-rtti"; c |] -> sexp (cxx ~rtti:false c)
  | [| _; "clang-libs"; c |] -> sexp (clang_libs c)
  | [| _; "lld-libs"; c |] -> sexp (lld_libs c)
  | [| _; "o2-pipeline" |] -> o2_pipeline ()
  | [| _; "builtin-headers" |] -> builtin_headers ()
  | _ -> failwith "usage: discover cflags|libs|o2-pipeline|builtin-headers|(std|cxx|cxx-no-rtti|clang-libs|lld-libs) CCOMP"

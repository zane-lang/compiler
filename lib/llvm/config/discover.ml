(* The C flags (`cflags`) or link flags (`libs`) LLVM's OCaml bindings are
   built with, as a dune S-expression, from the LLVM that `LLVM_CONFIG`
   names, or `llvm-config` on PATH. LLVM is linked the way it was built:
   its shared library where it has one, found again at run time through an
   rpath, and its static libraries otherwise, as on Windows, with the
   system libraries they need. *)

let llvm_config = match Sys.getenv_opt "LLVM_CONFIG" with Some p when p <> "" -> p | _ -> "llvm-config"

let ask args =
  let ic = Unix.open_process_args_in llvm_config (Array.of_list (llvm_config :: args)) in
  let out = In_channel.input_all ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> String.trim out
  | _ -> failwith (Printf.sprintf "%s %s failed" llvm_config (String.concat " " args))

let words s = String.split_on_char ' ' s |> List.concat_map (String.split_on_char '\n') |> List.map String.trim |> List.filter (( <> ) "")

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
  match ask [ "--shared-mode" ] with
  | "shared" ->
      [ "-L" ^ libdir ]
      @ (if Sys.win32 then [] else [ "-Wl,-rpath," ^ libdir ])
      @ words (ask [ "--link-shared"; "--libs" ])
  | _ ->
      List.map (library libdir) (words (ask [ "--link-static"; "--libs" ]))
      @ List.map (library libdir) (words (ask [ "--link-static"; "--system-libs" ]))

let cflags () = [ "-I" ^ ask [ "--includedir" ] ]

let () =
  let flags = match Sys.argv with [| _; "cflags" |] -> cflags () | [| _; "libs" |] -> libs () | _ -> failwith "usage: discover cflags|libs" in
  print_string ("(" ^ String.concat " " (List.map (Printf.sprintf "%S") flags) ^ ")\n")

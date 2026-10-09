(* A module to a binary: the target machine writes an object file, and the
   system's C compiler links it with the runtime (docs/design/lowering.md L2, L17). *)

external normalize_triple : string -> string = "zane_normalize_triple"

(* The processor code is tuned for on *triple*, as clang tunes it: on x86-64
   the baseline `x86-64`, on `x86_64h` the Haswell processor that
   architecture names, and LLVM's own default elsewhere. Each allows only the
   instructions every processor of the architecture has, so a program runs
   anywhere its target does; tuning for LLVM's bare `generic` x86 instead
   leaves out choices clang makes, among them dividing by a 32-bit divide
   when both 64-bit operands fit, which makes trialdiv 1.4 times slower
   (#203). *)
let cpu triple =
  match String.split_on_char '-' triple with
  | "x86_64" :: _ | "amd64" :: _ -> "x86-64"
  | "x86_64h" :: _ -> "core-avx2"
  | _ -> ""

(* The machine for *target*, an LLVM triple, or for the host when it is
   absent. The triple is taken in LLVM's normal form, which reads a short
   spelling such as `x86_64-windows-gnu` as the Windows triple it is, where
   LLVM would otherwise take `windows` for the vendor and build for no
   operating system. An unknown triple is an error, not an exception. *)
let target_machine ?target ~optimize () =
  Llvm_all_backends.initialize ();
  let triple =
    match target with
    | Some target -> normalize_triple target
    | None -> Llvm_target.Target.default_triple ()
  in
  let level = Llvm_target.CodeGenOptLevel.(if optimize then Default else None) in
  match Llvm_target.Target.by_triple triple with
  | target ->
      Ok
        ( triple,
          Llvm_target.TargetMachine.create ~triple ~cpu:(cpu triple) ~level
            ~reloc_mode:Llvm_target.RelocMode.PIC target )
  | exception Llvm_target.Error message ->
      Error (Printf.sprintf "cannot compile for the target `%s`: %s" triple message)

external set_own_comdat : Llvm.llmodule -> Llvm.llvalue -> string -> unit
  = "zane_set_own_comdat"

(* Every copy of a shared function, a generic instance, and of a shared
   variable, a package constant's, is kept to one by the linker
   (docs/design/separate-compilation.md C4). An ELF or COFF linker does that
   for a definition in a COMDAT of its own; without one, a COFF linker
   refuses the second copy as a duplicate. Mach-O has no COMDATs, and its
   linker merges the copies by their weak definitions alone. *)
let shared_in_comdats triple m =
  let contains part =
    let n = String.length part in
    let rec at i = i <= String.length triple - n && (String.sub triple i n = part || at (i + 1)) in
    at 0
  in
  let macho = List.exists contains [ "-apple-"; "darwin"; "macos"; "-ios" ] in
  let own v =
    if Llvm.linkage v = Llvm.Linkage.Link_once_odr && not (Llvm.is_declaration v) then
      set_own_comdat m v (Llvm.value_name v)
  in
  if not macho then begin
    Llvm.iter_functions own m;
    Llvm.iter_globals own m
  end

(* The module made ready for *target*: its triple and data layout set and,
   when *optimize*, LLVM's standard `-O2` pipeline run over it. Without it no
   pass runs, which is what makes an unoptimized build fast. A program means
   the same either way (docs/design/lowering.md §7). *)
let prepare ?target ?(optimize = false) m =
  Result.bind (target_machine ?target ~optimize ()) (fun (triple, tm) ->
      Llvm.set_target_triple triple m;
      shared_in_comdats triple m;
      let data_layout = Llvm_target.TargetMachine.data_layout tm in
      Llvm.set_data_layout (Llvm_target.DataLayout.as_string data_layout) m;
      Result.bind (Big_moves.rewrite data_layout m) @@ fun () ->
      if optimize then
        Llvm_passbuilder.run_passes m "default<O2>" tm
          (Llvm_passbuilder.create_passbuilder_options ())
        |> Result.map (fun () -> (triple, tm))
        |> Result.map_error (Printf.sprintf "cannot optimize the module: %s")
      else Ok (triple, tm))

(* The C compiler that links: `ZANE_CC` if set, else `clang`. *)
let cc () = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC")

(* The runtime is written out as it is laid out in runtime/: its two headers
   beside the one translation unit that includes them. *)
let write_runtime dir =
  List.iter
    (fun (name, text) ->
      Out_channel.with_open_bin (Filename.concat dir name) (fun oc -> output_string oc text))
    [
      ("zane.h", Runtime_source.header);
      ("zane_internal.h", Runtime_source.internal);
      ("zane.c", Runtime_source.text);
    ]

(* The module's object file alone, for a package other objects link with
   (docs/design/separate-compilation.md C3): no runtime, and no link. *)
let object_file ?target ?(optimize = false) m output =
  Result.bind (prepare ?target ~optimize m) (fun (_, tm) ->
      match Llvm_target.TargetMachine.emit_to_file m Llvm_target.CodeGenFileType.ObjectFile output tm with
      | () -> Ok ()
      | exception Llvm_target.Error message ->
          Error (Printf.sprintf "cannot write the object file: %s" message))

(* [link] is the objects of the program's stamped dependencies, which the C
   compiler links with it (docs/design/separate-compilation.md C7). *)
let executable ?target ?(optimize = false) ?(link = []) m output =
  match prepare ?target ~optimize m with
  | Error _ as error -> error
  | Ok (_, tm) -> (
      let dir = Filename.temp_dir "zane" "" in
      let obj = Filename.concat dir "program.o" in
      let rt = Filename.concat dir "zane.c" in
      (* The C compiler links for the target as it was written: `zig cc`
         reads its own short triples, and not every normal form. *)
      let target_flag = match target with Some target -> [ "--target=" ^ target ] | None -> [] in
      (* The runtime reads a Windows program's arguments through
         `CommandLineToArgvW`, which shell32 holds. A Windows program's
         main thread gets the 8 MiB of machine stack it has on Linux and
         macOS, where the linker would give it 1 MiB
         (docs/design/platforms.md). *)
      let windows =
        match target with
        | Some target -> List.mem "windows" (String.split_on_char '-' target)
        | None -> Sys.win32
      in
      let link = if windows then link @ [ "-lshell32"; "-Wl,--stack,8388608" ] else link in
      let command =
        String.concat " "
          (List.map Filename.quote
             ([ cc () ] @ target_flag
             @ [ (if optimize then "-O2" else "-O0"); "-pthread"; "-o"; output; obj ]
             @ link @ [ rt ]))
      in
      (* The temporary files go however the build ends, a raise included. A
         failure to write them is an error like any other, not an exception. *)
      Fun.protect
        ~finally:(fun () ->
          List.iter
            (fun f -> try Sys.remove (Filename.concat dir f) with Sys_error _ -> ())
            [ "program.o"; "zane.h"; "zane_internal.h"; "zane.c" ];
          try Sys.rmdir dir with Sys_error _ -> ())
        (fun () ->
          match
            Llvm_target.TargetMachine.emit_to_file m Llvm_target.CodeGenFileType.ObjectFile obj tm;
            write_runtime dir
          with
          | exception Llvm_target.Error message ->
              Error (Printf.sprintf "cannot write the object file: %s" message)
          | exception Sys_error message ->
              Error (Printf.sprintf "cannot write the runtime's sources: %s" message)
          | () -> (
              match Sys.command command with
              | 0 -> Ok ()
              | n -> Error (Printf.sprintf "`%s` exited with %d" command n))))

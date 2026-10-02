(* A module to a binary: the target machine writes an object file, and the
   system's C compiler links it with the runtime (docs/design/lowering.md L2, L17). *)

(* The machine for *target*, an LLVM triple, or for the host when it is
   absent. An unknown triple is an error, not an exception. *)
let target_machine ?target ~optimize () =
  Llvm_all_backends.initialize ();
  let triple = Option.value target ~default:(Llvm_target.Target.default_triple ()) in
  let level = Llvm_target.CodeGenOptLevel.(if optimize then Default else None) in
  match Llvm_target.Target.by_triple triple with
  | target ->
      Ok
        ( triple,
          Llvm_target.TargetMachine.create ~triple ~level ~reloc_mode:Llvm_target.RelocMode.PIC
            target )
  | exception Llvm_target.Error message ->
      Error (Printf.sprintf "cannot compile for the target `%s`: %s" triple message)

(* The module made ready for *target*: its triple and data layout set and,
   when *optimize*, LLVM's standard `-O2` pipeline run over it. Without it no
   pass runs, which is what makes an unoptimized build fast. A program means
   the same either way (docs/design/lowering.md §7). *)
let prepare ?target ?(optimize = false) m =
  Result.bind (target_machine ?target ~optimize ()) (fun (triple, tm) ->
      Llvm.set_target_triple triple m;
      Llvm.set_data_layout
        (Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm))
        m;
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
  | Ok (triple, tm) -> (
      let dir = Filename.temp_dir "zane" "" in
      let obj = Filename.concat dir "program.o" in
      let rt = Filename.concat dir "zane.c" in
      (* The C compiler links for the triple the object was written for. *)
      let target_flag = match target with Some _ -> [ "--target=" ^ triple ] | None -> [] in
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

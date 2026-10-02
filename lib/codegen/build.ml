(* A module to a binary: the target machine writes an object file, and the
   system's C compiler links it with the runtime (docs/design/lowering.md L2, L17). *)

(* The machine for *target*, an LLVM triple, or for the host when it is
   absent. An unknown triple is an error, not an exception. *)
let target_machine ?target () =
  Llvm_all_backends.initialize ();
  let triple = Option.value target ~default:(Llvm_target.Target.default_triple ()) in
  match Llvm_target.Target.by_triple triple with
  | target ->
      Ok (triple, Llvm_target.TargetMachine.create ~triple ~reloc_mode:Llvm_target.RelocMode.PIC target)
  | exception Llvm_target.Error message ->
      Error (Printf.sprintf "cannot compile for the target `%s`: %s" triple message)

let prepare ?target m =
  Result.map
    (fun (triple, tm) ->
      Llvm.set_target_triple triple m;
      Llvm.set_data_layout
        (Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm))
        m;
      (triple, tm))
    (target_machine ?target ())

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

let executable ?target m output =
  match prepare ?target m with
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
             ([ cc () ] @ target_flag @ [ "-O2"; "-pthread"; "-o"; output; obj; rt ]))
      in
      (* The temporary files go however the build ends, a raise included. *)
      let status =
        Fun.protect
          ~finally:(fun () ->
            List.iter
              (fun f -> try Sys.remove (Filename.concat dir f) with Sys_error _ -> ())
              [ "program.o"; "zane.h"; "zane_internal.h"; "zane.c" ];
            try Sys.rmdir dir with Sys_error _ -> ())
          (fun () ->
            Llvm_target.TargetMachine.emit_to_file m Llvm_target.CodeGenFileType.ObjectFile obj tm;
            write_runtime dir;
            Sys.command command)
      in
      match status with
      | 0 -> Ok ()
      | n -> Error (Printf.sprintf "`%s` exited with %d" command n))

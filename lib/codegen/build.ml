(* A module to a binary: the target machine writes an object file, and the
   system's C compiler links it with the runtime (docs/design/lowering.md L2, L17). *)

let target_machine () =
  Llvm_all_backends.initialize ();
  let triple = Llvm_target.Target.default_triple () in
  let target = Llvm_target.Target.by_triple triple in
  (triple, Llvm_target.TargetMachine.create ~triple ~reloc_mode:Llvm_target.RelocMode.PIC target)

let prepare m =
  let triple, tm = target_machine () in
  Llvm.set_target_triple triple m;
  Llvm.set_data_layout
    (Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm))
    m;
  tm

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

let executable m output =
  let tm = prepare m in
  let dir = Filename.temp_dir "zane" "" in
  let obj = Filename.concat dir "program.o" in
  let rt = Filename.concat dir "zane.c" in
  let command =
    String.concat " " (List.map Filename.quote [ cc (); "-O2"; "-pthread"; "-o"; output; obj; rt ])
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
  | n -> Error (Printf.sprintf "`%s` exited with %d" command n)

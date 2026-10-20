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

(* Whether [triple], whose data layout is [layout], is a target this
   compiler builds for (docs/design/platforms.md, "64-bit targets only").
   Lowering lays out every type, and the runtime its records, for 8-byte
   pointers with `i64` and `double` aligned to 8 bytes; a target that
   differs would get offsets that disagree with what LLVM and the C
   compiler lay out. Byte order is not checked: nothing here depends on it,
   since every value is read at the width it was written, and the object
   rewriters read both byte orders. *)
let sixty_four_bit triple layout =
  let ctx = Llvm.global_context () in
  let align t = Llvm_target.DataLayout.abi_align t layout in
  let pointer = Llvm_target.DataLayout.pointer_size layout in
  let refused = Printf.sprintf "the target `%s` %s; this compiler builds for 64-bit targets only" triple in
  if pointer <> 8 then Error (refused (Printf.sprintf "has %d-byte pointers" pointer))
  else
    match
      List.find_opt
        (fun (_, t) -> align t <> 8)
        [ ("i64", Llvm.i64_type ctx); ("double", Llvm.double_type ctx) ]
    with
    | Some (name, t) -> Error (refused (Printf.sprintf "aligns `%s` to %d bytes" name (align t)))
    | None -> Ok ()

(* The machine for *target*, an LLVM triple, or for the host when it is
   absent. The triple is taken in LLVM's normal form, which reads a short
   spelling such as `x86_64-windows-gnu` as the Windows triple it is, where
   LLVM would otherwise take `windows` for the vendor and build for no
   operating system. An unknown triple, or one that is not 64-bit, is an
   error, not an exception. *)
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
      let tm =
        Llvm_target.TargetMachine.create ~triple ~cpu:(cpu triple) ~level
          ~reloc_mode:Llvm_target.RelocMode.PIC target
      in
      Result.map (fun () -> (triple, tm)) (sixty_four_bit triple (Llvm_target.TargetMachine.data_layout tm))
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

(* A function whose locals take more than a page of machine stack touches
   each page in turn as it takes them, so a stack that runs out faults in
   the page that guards it, which the runtime reports, rather than past it
   in whatever lies below. Windows code does so already, through the
   `__chkstk` its C library supplies, and LLVM reads the attribute there as
   the name of a function to call in its place. *)
let probe_stack triple m =
  if not (List.mem "windows" (String.split_on_char '-' triple)) then begin
    let probe = Llvm.create_string_attr (Llvm.module_context m) "probe-stack" "inline-asm" in
    Llvm.iter_functions
      (fun f -> if not (Llvm.is_declaration f) then Llvm.add_function_attr f probe Llvm.AttrIndex.Function)
      m
  end

(* The module emitted for *target* made ready to be written: its shared
   functions in COMDATs, its stack probed and, when *optimize*, LLVM's
   standard `-O2` pipeline run over it. Without it no pass runs, which is
   what makes an unoptimized build fast. A program means the same either way
   (docs/design/lowering.md §7). *)
let prepare ?target ?(optimize = false) m =
  Result.bind (target_machine ?target ~optimize ()) (fun (triple, tm) ->
      shared_in_comdats triple m;
      probe_stack triple m;
      let data_layout = Llvm_target.TargetMachine.data_layout tm in
      Result.bind (Big_moves.rewrite data_layout m) @@ fun () ->
      if optimize then
        Llvm_passbuilder.run_passes m "default<O2>" tm
          (Llvm_passbuilder.create_passbuilder_options ())
        |> Result.map (fun () -> (triple, tm))
        |> Result.map_error (Printf.sprintf "cannot optimize the module: %s")
      else Ok (triple, tm))

(* The C compiler that links: `ZANE_CC` if set, else `clang`. *)
let cc () = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC")

(* The runtime as it is laid out in runtime/: its three headers beside the
   one translation unit that includes them. *)
let runtime_files =
  [
    ("zane.h", Runtime_source.header);
    ("zane_abi.h", Runtime_source.abi);
    ("zane_internal.h", Runtime_source.internal);
    ("zane.c", Runtime_source.text);
  ]

let write_runtime dir =
  List.iter
    (fun (name, text) ->
      Out_channel.with_open_bin (Filename.concat dir name) (fun oc -> output_string oc text))
    runtime_files

(* Where compiled runtimes are kept between builds: `ZANE_CACHE_DIR` if set,
   else the platform's cache directory, or nowhere when it has none. *)
let cache_dir () =
  let set name = match Sys.getenv_opt name with Some "" | None -> None | Some dir -> Some dir in
  match set "ZANE_CACHE_DIR" with
  | Some dir -> Some dir
  | None -> (
      let zane base = Some (Filename.concat base "zane") in
      if Sys.win32 then Option.bind (set "LOCALAPPDATA") zane
      else
        match set "XDG_CACHE_HOME" with
        | Some base when not (Filename.is_relative base) -> zane base
        | _ -> Option.bind (set "HOME") (fun home -> zane (Filename.concat home ".cache")))

(* A root that does not exist, as a drive not mounted, is its own parent:
   the mkdir below fails there rather than climbing forever. *)
let rec make_dirs dir =
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if parent <> dir then make_dirs parent;
    try Sys.mkdir dir 0o755 with Sys_error _ when Sys.file_exists dir -> ()
  end

(* What *cc* says it is, written to a file in [dir]; [None] when it will not
   say, and then nothing it compiles is kept. *)
let identity cc dir =
  let file = Filename.concat dir "cc-version" in
  match Sys.command (Filename.quote_command cc ~stdout:file ~stderr:file [ "--version" ]) with
  | 0 -> ( try Some (In_channel.with_open_bin file In_channel.input_all) with Sys_error _ -> None)
  | _ -> None

(* The runtime's files, each name and then its text, as the keys hash them. *)
let sources = List.concat_map (fun (name, text) -> [ name; text ]) runtime_files

(* The flags besides the target's that the runtime is compiled and the
   program linked with, optimizing or not. *)
let level ~optimize = [ (if optimize then "-O2" else "-O0"); "-pthread" ]

(* The C compiler links for the target as it was written: `zig cc` reads
   its own short triples, and not every normal form. *)
let target_flag = function Some target -> [ "--target=" ^ target ] | None -> []

(* The name a runtime compiled by *cc*, which says it is [identity], with
   [flags] for [triple] is kept under: everything that changes the object is
   in it. The triple is the build's own, given or the host's, so a build that
   names no target still keys its runtime by the one it links for. *)
let runtime_key ~cc ~identity ~triple flags =
  Digest.to_hex (Digest.string (String.concat "\000" ((cc :: identity :: triple :: flags) @ sources)))

(* Where a released toolchain keeps the runtimes it was released with:
   `ZANE_RUNTIME_OBJECTS`, which its `zanec` sets only when it also sets the
   C compiler, to the `zig cc` beside it that compiled them. *)
let bundled_dir () = match Sys.getenv_opt "ZANE_RUNTIME_OBJECTS" with Some "" | None -> None | Some dir -> Some dir

(* The name a runtime compiled with [level] for [triple] is bundled under.
   It names no C compiler, since a bundle is used only with the one that
   compiled it, and the target only in LLVM's normal form, so spellings that
   normalize alike, and a build for the host that names none, link the same
   object. *)
let bundled_name ~triple level =
  Digest.to_hex (Digest.string (String.concat "\000" ((triple :: level) @ sources))) ^ ".o"

(* [object_] copied into the cache as [kept], through a temporary beside it
   renamed into place, so a build reading the cache never sees half an
   object. Keeping it is an optimization: any failure leaves the cache as it
   was and the build goes on. *)
let keep ~random ~object_ ~kept =
  let temporary =
    Filename.concat (Filename.dirname kept)
      (Printf.sprintf ".%s.%08x" (Filename.basename kept) (Random.State.bits random))
  in
  try
    make_dirs (Filename.dirname kept);
    let contents = In_channel.with_open_bin object_ In_channel.input_all in
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o644 temporary
      (fun oc -> output_string oc contents);
    Sys.rename temporary kept
  with Sys_error _ -> ( try Sys.remove temporary with Sys_error _ -> ())

(* The runtime's sources in [dir] compiled by *cc* with [flags] into
   [output]. *)
let compile ~cc flags dir output =
  let command = Filename.quote_command cc (flags @ [ "-c"; "-o"; output; Filename.concat dir "zane.c" ]) in
  match Sys.command command with
  | 0 -> Ok output
  | n -> Error (Printf.sprintf "`%s` exited with %d" command n)

(* The runtime compiled for a build for [triple], named [target] when one
   was, from the sources already written to [dir]. The same compiler with the
   same flags for the same triple always makes the same object of the same
   runtime, so one compiled before is taken from [bundled], the toolchain's
   own, or from [cache] when either has it, and one compiled now is kept in
   [cache]; compiling it costs more than the rest of a small program's
   build. *)
let runtime_object ?bundled ?cache ~cc ~triple ?target ~optimize dir =
  let level = level ~optimize in
  let flags = target_flag target @ level in
  let fresh = Filename.concat dir "runtime.o" in
  match Option.map (fun bundled -> Filename.concat bundled (bundled_name ~triple level)) bundled with
  | Some object_ when Sys.file_exists object_ -> Ok object_
  | _ -> (
      match Option.bind cache (fun cache -> Option.map (fun id -> (cache, id)) (identity cc dir)) with
      | None -> compile ~cc flags dir fresh
      | Some (cache, identity) ->
          let kept =
            Filename.concat (Filename.concat cache "runtime") (runtime_key ~cc ~identity ~triple flags ^ ".o")
          in
          if Sys.file_exists kept then Ok kept
          else
            Result.map
              (fun object_ ->
                keep ~random:(Random.State.make_self_init ()) ~object_ ~kept;
                object_)
              (compile ~cc flags dir fresh))

(* A directory of its own for a build's temporary files, given to [f] and
   removed with them however [f] ends, a raise included. *)
let in_work_dir f =
  let dir = Filename.temp_dir "zane" "" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun f -> try Sys.remove (Filename.concat dir f) with Sys_error _ -> ())
        ([ "program.o"; "runtime.o"; "cc-version" ] @ List.map fst runtime_files);
      try Sys.rmdir dir with Sys_error _ -> ())
    (fun () -> f dir)

(* The runtime compiled for [target], with or without optimizing, into
   [dir] under the name a build for that target looks for there
   ([bundled_name]): what a release bundles for each target it ships
   (docs/design/lowering.md §7). A target is required, since a C compiler
   given none compiles for the processor it runs on. *)
let bundle_runtime ~target ~optimize dir =
  Result.bind (target_machine ~target ~optimize ()) @@ fun (triple, _) ->
  in_work_dir @@ fun work ->
  match
    write_runtime work;
    make_dirs dir
  with
  | exception Sys_error message -> Error (Printf.sprintf "cannot write the runtime: %s" message)
  | () ->
      let level = level ~optimize in
      Result.map ignore
        (compile ~cc:(cc ()) (target_flag (Some target) @ level) work
           (Filename.concat dir (bundled_name ~triple level)))

(* The module's object file alone, for a package other objects link with
   (docs/design/separate-compilation.md C3): no runtime, and no link. *)
let object_file ?target ?(optimize = false) m output =
  Result.bind (prepare ?target ~optimize m) (fun (_, tm) ->
      match Llvm_target.TargetMachine.emit_to_file m Llvm_target.CodeGenFileType.ObjectFile output tm with
      | () -> Ok ()
      | exception Llvm_target.Error message ->
          Error (Printf.sprintf "cannot write the object file: %s" message))

(* [link] is the objects of the program's stamped dependencies, which the C
   compiler links with it (docs/design/separate-compilation.md C7). [cache]
   is where the compiled runtime is kept, [cache_dir ()] unless given, and
   [bundled] where the toolchain keeps its own, [bundled_dir ()] unless
   given. *)
let executable ?target ?(optimize = false) ?(link = []) ?(bundled = bundled_dir ()) ?(cache = cache_dir ()) m
    output =
  match prepare ?target ~optimize m with
  | Error _ as error -> error
  | Ok (triple, tm) -> (
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
      (* The approximate math functions are the C math library's
         (math.md §2.6). Windows' C runtime and macOS's libSystem hold it;
         on Linux it is a library of its own. *)
      let link = if windows then link @ [ "-lshell32"; "-Wl,--stack,8388608" ] else link @ [ "-lm" ] in
      let cc = cc () in
      let flags = target_flag target @ level ~optimize in
      let command obj runtime = Filename.quote_command cc (flags @ [ "-o"; output; obj ] @ link @ [ runtime ]) in
      (* A failure to write the temporary files is an error like any other,
         not an exception. *)
      in_work_dir @@ fun dir ->
      let obj = Filename.concat dir "program.o" in
      match
        Llvm_target.TargetMachine.emit_to_file m Llvm_target.CodeGenFileType.ObjectFile obj tm;
        write_runtime dir
      with
      | exception Llvm_target.Error message -> Error (Printf.sprintf "cannot write the object file: %s" message)
      | exception Sys_error message -> Error (Printf.sprintf "cannot write the runtime's sources: %s" message)
      | () -> (
          match runtime_object ?bundled ?cache ~cc ~triple ?target ~optimize dir with
          | Error _ as error -> error
          | Ok runtime -> (
              let command = command obj runtime in
              match Sys.command command with
              | 0 -> Ok ()
              | n -> Error (Printf.sprintf "`%s` exited with %d" command n))))

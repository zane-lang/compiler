(* A module to a binary: the target machine writes an object file, and the
   system's C compiler links it with the runtime (docs/design/lowering.md L2, L17). *)

external normalize_triple : string -> string = "zane_normalize_triple"

(* LLVM's own options, as its command line would give them; once per
   process, since LLVM reads them only once (llvm_stubs.c). *)
external llvm_options : string array -> unit = "zane_llvm_options"

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

(* Whether [triple] is one of Apple's, whose objects are Mach-O. *)
let macho triple =
  let contains part =
    let n = String.length part in
    let rec at i = i <= String.length triple - n && (String.sub triple i n = part || at (i + 1)) in
    at 0
  in
  List.exists contains [ "-apple-"; "darwin"; "macos"; "-ios" ]

(* Every copy of a shared function, a generic instance, and of a shared
   variable, a package constant's, is kept to one by the linker
   (docs/design/separate-compilation.md C4). An ELF or COFF linker does that
   for a definition in a COMDAT of its own; without one, a COFF linker
   refuses the second copy as a duplicate. Mach-O has no COMDATs, and its
   linker merges the copies by their weak definitions alone. *)
let shared_in_comdats triple m =
  let macho = macho triple in
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

(* The C compiler that links: `ZANE_CC` if set, else `clang`. *)
let cc () = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC")

(* The C compiler that compiles the runtime's bitcode, `ZANE_BITCODE_CC`
   when it is set and *cc* otherwise: a release's, whose own C compiler
   writes bitcode newer than this LLVM reads (docs/design/lowering.md §7). *)
let bitcode_cc () =
  match Sys.getenv_opt "ZANE_BITCODE_CC" with Some "" | None -> cc () | Some cc -> cc

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

(* The file *cc* runs: itself when it names a directory, else the first file
   of its name in a directory on the path that the shell would run, an empty
   entry being the current directory; [None] when there is none. On Windows,
   where the command's search also tries the current directory and each of
   `PATHEXT`'s extensions, it is [None], and the compiler is asked every
   time. *)
let located cc =
  if Sys.win32 then None
  else if Filename.basename cc <> cc then Some cc
  else
    let dirs =
      match Sys.getenv_opt "PATH" with Some path -> String.split_on_char ':' path | None -> []
    in
    let runs path =
      match Unix.access path [ Unix.X_OK ] with () -> true | exception Unix.Unix_error _ -> false
    in
    List.find_map
      (fun dir ->
        let path = Filename.concat (if dir = "" then Filename.current_dir_name else dir) cc in
        if Sys.file_exists path && (not (Sys.is_directory path)) && runs path then Some path
        else None)
      dirs

(* What *cc* says it is, written to a file in [dir]; [None] when it will not
   say, and then nothing it compiles is kept. Asking costs a run of the C
   compiler, about as long as the rest of a small unoptimized build, so the
   answer is kept in [cache] under the file *cc* runs, its size, the time it
   was last changed and where it is on disk, and asked again only when one
   of those changes. *)
let identity ~cache cc dir =
  let file = Filename.concat dir "cc-version" in
  let read path = try Some (In_channel.with_open_bin path In_channel.input_all) with Sys_error _ -> None in
  let asked () =
    match Sys.command (Filename.quote_command cc ~stdout:file ~stderr:file [ "--version" ]) with
    | 0 -> read file
    | _ -> None
  in
  match Option.bind (located cc) (fun path -> try Some (path, Unix.stat path) with Unix.Unix_error _ -> None) with
  | None -> asked ()
  | Some (path, stat) -> (
      let stamp =
        [
          path;
          string_of_int stat.Unix.st_size;
          Printf.sprintf "%h" stat.Unix.st_mtime;
          string_of_int stat.Unix.st_ino;
          string_of_int stat.Unix.st_dev;
        ]
      in
      let kept =
        Filename.concat (Filename.concat cache "cc") (Digest.to_hex (Digest.string (String.concat "\000" stamp)))
      in
      match read kept with
      | Some answer -> Some answer
      | None ->
          let answer = asked () in
          if Option.is_some answer then keep ~random:(Random.State.make_self_init ()) ~object_:file ~kept;
          answer)

(* LLD, linked into the compiler (lld_stubs.cpp): the linker its first
   argument names run on the rest, and its exit code, whether it can run
   again in this process, and what it wrote. *)
external lld_link : string array -> int * bool * string = "zane_lld_link"

(* Whether LLD may run again in this process: it may not once it has
   recovered from a crash. *)
let lld_usable = ref true

(* The words of a command as a C compiler's `-###` prints it: clang puts
   each in double quotes with backslash escapes, `zig cc` separates them
   with spaces. *)
let words line =
  let b = Buffer.create 64 and found = ref [] and n = String.length line in
  let flush () =
    if Buffer.length b > 0 then begin
      found := Buffer.contents b :: !found;
      Buffer.clear b
    end
  in
  let rec plain i =
    if i >= n then flush ()
    else
      match line.[i] with
      | ' ' | '\t' | '\r' ->
          flush ();
          plain (i + 1)
      | '"' -> quoted (i + 1)
      | c ->
          Buffer.add_char b c;
          plain (i + 1)
  and quoted i =
    if i >= n then flush ()
    else
      match line.[i] with
      | '"' -> plain (i + 1)
      | '\\' when i + 1 < n ->
          Buffer.add_char b line.[i + 1];
          quoted (i + 2)
      | c ->
          Buffer.add_char b c;
          quoted (i + 1)
  in
  plain 0;
  List.rev !found

(* The LLD a C compiler's linker is, by the name it runs it by, or [None]
   for any other linker. *)
let lld_named program =
  let name = Filename.basename program in
  match if Filename.check_suffix name ".exe" then Filename.chop_suffix name ".exe" else name with
  | ("ld.lld" | "ld64.lld" | "lld-link") as name -> Some name
  | _ -> None

(* The architecture [triple] names, as ld64 spells it. *)
let darwin_arch triple =
  match String.split_on_char '-' triple with
  | "aarch64" :: _ | "arm64" :: _ -> "arm64"
  | arch :: _ -> arch
  | [] -> triple

(* The linker command a line of *cc*'s `-###` runs, as LLD in the compiler
   runs it: LLD's own, GCC's `collect2`, which takes the linker's arguments
   and runs the linker with them, as `ld.lld` without the LTO plugin GCC
   names, or `zig ld`, Zig's Mach-O linker, which takes ld64's, as
   `ld64.lld` for [triple]'s architecture with Zig's own `libSystem` stubs,
   which [system] finds; [None] for any other line. LTO's `-mllvm` options,
   `-MLLVM:` to `lld-link`, are left out: they would set options of the
   compiler's own LLVM, and nothing here is LTO. *)
let linker_line ~triple ~system line =
  let rec without_mllvm = function
    | "-mllvm" :: _ :: rest -> without_mllvm rest
    | arg :: rest when String.starts_with ~prefix:"-MLLVM:" arg -> without_mllvm rest
    | arg :: rest -> arg :: without_mllvm rest
    | [] -> []
  in
  let rec without_plugin = function
    | "-plugin" :: _ :: rest -> without_plugin rest
    | arg :: rest when String.starts_with ~prefix:"-plugin-opt=" arg -> without_plugin rest
    | arg :: rest -> arg :: without_plugin rest
    | [] -> []
  in
  let named program = Filename.remove_extension (Filename.basename program) in
  (* `zig cc` names no entry for a MinGW DLL, which `lld-link` then takes
     to be MSVC's; MinGW's is `DllMainCRTStartup`, as its own `ld` driver
     names it. *)
  let mingw_entry args =
    if
      List.mem "-lldmingw" args && List.mem "-DLL" args
      && not (List.exists (fun a -> String.starts_with ~prefix:"-ENTRY:" (String.uppercase_ascii a)) args)
    then args @ [ "-ENTRY:DllMainCRTStartup" ]
    else args
  in
  match words line with
  | program :: rest when Option.is_some (lld_named program) ->
      Option.map (fun name -> name :: mingw_entry (without_mllvm rest)) (lld_named program)
  | program :: rest when named program = "collect2" -> Some ("ld.lld" :: without_plugin rest)
  | program :: "ld" :: rest when named program = "zig" ->
      Option.map
        (fun system ->
          "ld64.lld" :: "-arch" :: darwin_arch triple
          :: List.map (fun w -> if w = "-lSystem" then system else w) rest)
        (system ())
  | _ -> None

(* The linker command *cc* runs for [args], as LLD in the compiler runs it
   ([linker_line]), or [None] when its linker is none of those; an error
   when *cc* does not say. A C compiler whose own linker is another, such as
   clang with the system's `ld`, is asked again with `-fuse-ld=lld`: it then
   names its files for LLD. *)
let asked_link ~cc ~triple args dir =
  let file = Filename.concat dir "cc-link" in
  let ask args =
    let shown = List.nth args (List.length args - 1) in
    match Sys.command (Filename.quote_command cc ~stdout:file ~stderr:file args) with
    | 0 -> (
        match In_channel.with_open_bin file In_channel.input_all with
        | exception Sys_error _ -> Error (Printf.sprintf "its `%s` could not be read" shown)
        | text -> Ok (List.rev (String.split_on_char '\n' text)))
    | n -> Error (Printf.sprintf "its `%s` exited with %d" shown n)
  in
  (* Zig's install directory, where its `libSystem` stubs are. *)
  let system () =
    match ask [ "-print-search-dirs" ] with
    | Error _ -> None
    | Ok lines ->
        List.find_map
          (fun line ->
            Option.bind (String.index_opt line '=') (fun i ->
                if String.starts_with ~prefix:"programs:" line then
                  List.find_map
                    (fun dir ->
                      let tbd =
                        List.fold_left Filename.concat (String.trim dir) [ "lib"; "libc"; "darwin"; "libSystem.tbd" ]
                      in
                      if Sys.file_exists tbd then Some tbd else None)
                    (String.split_on_char ':' (String.sub line (i + 1) (String.length line - i - 1)))
                else None))
          lines
  in
  let found lines = List.find_map (linker_line ~triple ~system) lines in
  match ask (args @ [ "-###" ]) with
  | Error _ as error -> error
  | Ok lines -> (
      match found lines with
      | Some _ as command -> Ok command
      | None -> Ok (match ask (args @ [ "-fuse-ld=lld"; "-###" ]) with Ok lines -> found lines | Error _ -> None))

(* Where the command a build links with came from: asked for now and not
   kept, asked for now and [Kept] in the cache, kept by an earlier build
   ([Known]), or [Bundled] with a released toolchain. *)
type source = Asked | Kept of string | Known of string | Bundled

(* How a build links: by the LLD in the compiler with [command], or by the
   C compiler, for [why]. *)
type plan = Lld of { command : string list; source : source } | Cc of string

(* [text] kept in [kept], through a file of [dir]'s. A kept file holds a
   command's words, or `\001` and why the C compiler links. *)
let keep_text ~dir ~kept text =
  let file = Filename.concat dir "cc-link-words" in
  try
    Out_channel.with_open_bin file (fun oc -> output_string oc text);
    keep ~random:(Random.State.make_self_init ()) ~object_:file ~kept
  with Sys_error _ -> ()

(* A word of a linker command as an option that names a file after its
   `:`, as `lld-link` takes them (`-OUT:hello.exe`), and the rest. *)
let option_split w =
  match String.index_opt w ':' with
  | Some i when String.length w > 1 && w.[0] = '-' && i > 1 ->
      (String.sub w 0 (i + 1), String.sub w (i + 1) (String.length w - i - 1))
  | _ -> ("", w)

(* For a build of [obj] and [runtime] into [output]: a word of its linker
   command with the build's files marked, so the command can be kept, and
   one with a kept command's marks filled in with this build's files. A
   file is named by a word of its own, or after an option's `:`, and the
   files a COFF link writes beside the executable are named for it
   (`-PDB:hello.pdb`, `-PDBALTPATH:hello.pdb`). [bundle] is filled in for
   a bundled command's `\001bundle`. *)
let link_marks ?(bundle = "") ~obj ~runtime ~output () =
  let stem = Filename.remove_extension output in
  let marks =
    [
      ("\001obj", obj);
      ("\001runtime", runtime);
      ("\001output", output);
      ("\001stem", stem);
      ("\001nearstem", Filename.concat (Filename.dirname output) (Filename.basename stem));
      ("\001basestem", Filename.basename stem);
    ]
    (* A shared library links no runtime (docs/design/tiers.md). *)
    |> List.filter (fun (_, file) -> file <> "")
  in
  let stems = [ "\001stem"; "\001nearstem"; "\001basestem" ] in
  let mark w =
    let option, path = option_split w in
    (* The path a COFF executable records for its PDB is the PDB's bare
       name, which for an output with no directory is also its stem. *)
    let marks =
      if option = "-PDBALTPATH:" then List.filter (fun (m, _) -> m = "\001basestem") marks @ marks else marks
    in
    let named =
      List.find_map
        (fun (m, file) ->
          if path = file && not (List.mem m stems) then Some m
          else if List.mem m stems && stem <> output && String.starts_with ~prefix:(file ^ ".") path then
            Some (m ^ String.sub path (String.length file) (String.length path - String.length file))
          else None)
        marks
    in
    match named with Some m -> option ^ m | None -> w
  in
  let fill w =
    let option, path = option_split w in
    match List.find_opt (fun (m, _) -> String.starts_with ~prefix:m path) (("\001bundle", bundle) :: marks) with
    | Some (m, file) -> option ^ file ^ String.sub path (String.length m) (String.length path - String.length m)
    | None -> w
  in
  (mark, fill)

(* The linker command *cc* prints for a build of [obj] and [runtime] into
   [output] with [args], with the build's files marked ([link_marks]):
   [`Lld] when LLD in the compiler can run it, [`Other] when it cannot, and
   [`Unasked] when *cc* would not say. *)
let marked_link ~cc ~triple ~args ~obj ~runtime ~output dir =
  let mark, _ = link_marks ~obj ~runtime ~output () in
  let named m = List.exists (fun w -> String.starts_with ~prefix:m (snd (option_split w))) in
  match asked_link ~cc ~triple args dir with
  | Error why -> `Unasked why
  | Ok None -> `Other "its linker is not LLD"
  | Ok (Some command) ->
      let command = List.map mark command in
      let files = [ "\001obj"; "\001output" ] @ if runtime = "" then [] else [ "\001runtime" ] in
      if List.for_all (fun m -> named m command) files then `Lld command
      else `Other "its link command does not name the program's files"

(* The linker command for a build of [obj] and [runtime] into [output] with
   [args]: what *cc* prints for these, the first time, and then what was
   kept in [cache] for the same compiler, target, flags and objects to link,
   with this build's files put in. That *cc* cannot link through LLD in the
   compiler is kept too, so it is asked once; that it would not say is not. *)
let link_command ?cache ~cc ~triple ~args ~obj ~runtime ~output dir =
  let mark, fill = link_marks ~obj ~runtime ~output () in
  let filled = List.map fill in
  let fresh () = marked_link ~cc ~triple ~args ~obj ~runtime ~output dir in
  match Option.bind cache (fun cache -> Option.map (fun id -> (cache, id)) (identity ~cache cc dir)) with
  | None -> (
      match fresh () with
      | `Lld command -> Lld { command = filled command; source = Asked }
      | `Other why | `Unasked why -> Cc why)
  | Some (cache, identity) -> (
      let key = List.map mark args in
      let kept =
        Filename.concat (Filename.concat cache "link")
          (Digest.to_hex (Digest.string (String.concat "\000" (cc :: identity :: triple :: key))))
      in
      match In_channel.with_open_bin kept In_channel.input_all with
      | text when String.starts_with ~prefix:"\001" text -> Cc (String.sub text 1 (String.length text - 1))
      | text -> Lld { command = filled (String.split_on_char '\000' text); source = Known kept }
      | exception Sys_error _ -> (
          match fresh () with
          | `Lld command ->
              keep_text ~dir ~kept (String.concat "\000" command);
              Lld { command = filled command; source = Kept kept }
          | `Other why ->
              keep_text ~dir ~kept ("\001" ^ why);
              Cc why
          | `Unasked why -> Cc why))

(* The name the linker command a release bundles for [triple], linking with
   [level] and the [system] libraries, is kept under in its `link/`. *)
let bundled_link_name ~triple level system =
  Digest.to_hex (Digest.string (String.concat "\000" (("link" :: triple :: level) @ system)))

(* Whether [target], or the host when there is none, is macOS, whose
   libSystem holds the dynamic loader's functions. *)
let darwin = function
  | Some target ->
      List.exists (fun p -> List.mem p (String.split_on_char '-' target)) [ "macos"; "darwin"; "apple" ]
      || List.exists (fun p -> String.starts_with ~prefix:"macos" p || String.starts_with ~prefix:"darwin" p)
           (String.split_on_char '-' target)
  | None -> Sys.os_type = "Unix" && Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist"

(* Whether [target], or the host when there is none, is Windows. *)
let windows = function
  | Some target -> List.mem "windows" (String.split_on_char '-' target)
  | None -> Sys.win32

(* The libraries a shared library for [target] links with besides libc:
   tier 1 of a tiered build, which takes the math library's functions from
   the program and links it only for what LLVM itself calls. *)
let shared_libraries target = if windows target then [] else [ "-lm" ]

(* The flags that make a shared library rather than a program. *)
let shared = [ "-shared" ]

(* What a shared library is named with for [triple], in LLVM's normal
   form. *)
let shared_extension triple =
  let parts = String.split_on_char '-' triple in
  let has part = List.exists (fun p -> String.starts_with ~prefix:part p) parts in
  if has "windows" then ".dll" else if has "darwin" || has "macos" || has "apple" then ".dylib" else ".so"

(* The libraries every program for [target] links with besides libc. The
   approximate math functions are the C math library's (math.md §2.6):
   Windows' C runtime and macOS's libSystem hold it, and on Linux it is a
   library of its own. The runtime reads a Windows program's arguments
   through `CommandLineToArgvW`, which shell32 holds, and a Windows
   program's main thread gets the 8 MiB of machine stack it has on Linux
   and macOS, where the linker would give it 1 MiB
   (docs/design/platforms.md). The runtime loads tier 1 of a tiered build
   with `dlopen` (docs/design/tiers.md), which glibc before 2.34 keeps in
   libdl. That is linked only as needed: a later glibc's libdl defines
   nothing a program takes, and the loader would still open it on every
   run. *)
let system_libraries target =
  if windows target then [ "-lshell32"; "-Wl,--stack,8388608" ] else if darwin target then [ "-lm" ] else [ "-lm"; "-Wl,--as-needed"; "-ldl"; "-Wl,--no-as-needed" ]

(* [command] run by the LLD in the compiler; what it wrote when it fails. *)
let lld_run command =
  let code, again, text = lld_link (Array.of_list command) in
  lld_usable := again;
  if code = 0 then begin
    prerr_string text;
    Ok ()
  end
  else Error text

(* Whether to say how a build links: `ZANE_VERBOSE` is set. *)
let verbose () = match Sys.getenv_opt "ZANE_VERBOSE" with Some "" | None -> false | Some _ -> true

(* [args] linked by the LLD in the compiler with the command [bundled]
   holds, when a released toolchain bundles one, with [deps], the program's
   other objects, after [obj]; else with the command *cc* gives, when LLD
   can run it, and else by *cc*, which [say]s why under `ZANE_VERBOSE`. A
   command LLD fails on where *cc* links is warned of: one kept by an
   earlier build may have gone stale, and is asked for again next build;
   one just asked for is not, so *cc* links from then on. When *cc* fails
   too, the program does not link, and nothing is forgotten. [lld] runs the
   LLD. *)
let link_program ?cache ?bundled ?(lld = lld_run) ?(say = prerr_string) ~cc ~triple ~args ~deps ~obj ~runtime
    ~output dir =
  let through_cc why =
    if verbose () then say (Printf.sprintf "zanec: `%s` links: %s\n" cc why);
    let command = Filename.quote_command cc args in
    match Sys.command command with 0 -> Ok () | n -> Error (Printf.sprintf "`%s` exited with %d" command n)
  in
  let from_bundle file =
    match In_channel.with_open_bin file In_channel.input_all with
    | exception Sys_error _ -> None
    | text ->
        let _, fill = link_marks ~bundle:(Filename.dirname file) ~obj ~runtime ~output () in
        Some
          (List.concat_map
             (fun w -> if w = "\001obj" then obj :: deps else [ fill w ])
             (String.split_on_char '\000' text))
  in
  let plan =
    match Option.bind bundled from_bundle with
    | Some command -> Lld { command; source = Bundled }
    | None -> link_command ?cache ~cc ~triple ~args ~obj ~runtime ~output dir
  in
  match plan with
  | Cc why -> through_cc why
  | Lld _ when not !lld_usable -> through_cc "the built-in LLD cannot run again in this process"
  | Lld { command; source } -> (
      match lld command with
      | Ok () -> Ok ()
      | Error text -> (
          match through_cc "the built-in LLD could not link" with
          | Error _ as error -> error
          | Ok () ->
              let failed = "zanec: warning: the built-in LLD could not link with the command" in
              (match source with
              | Known kept ->
                  (try Sys.remove kept with Sys_error _ -> ());
                  say
                    (Printf.sprintf "%s kept for `%s`, so it linked instead; it is asked again next build\n"
                       failed cc)
              | Kept kept ->
                  keep_text ~dir ~kept "\001the built-in LLD could not link with its command";
                  say
                    (Printf.sprintf
                       "%s `%s` gave, so it linked instead, as it will for this target and these flags \
                        until %s is removed\n"
                       failed cc kept)
              | Asked -> say (Printf.sprintf "%s `%s` gave, so it linked instead\n" failed cc)
              | Bundled ->
                  say (Printf.sprintf "%s the toolchain bundles for this target, so `%s` linked instead\n" failed cc));
              say text;
              Ok ()))

(* What the runtime is compiled with besides [flags], whatever the C
   compiler would add by itself: no clearing of the registers a function
   used before it returns, and, but on Apple's targets, whose ABI keeps
   them, no frame pointers. Some toolchains add both by default, Nix's
   hardened clang among them, and they cost the runtime's small, hot
   functions more than anything else in them (docs/optimizations.md). *)
let tuning ~triple =
  let coff = List.mem "windows" (String.split_on_char '-' triple) in
  [ "-fzero-call-used-regs=skip"; "-fno-stack-protector"; "-fno-stack-clash-protection"; "-fno-wrapv" ]
  @ (if macho triple then [] else [ "-fomit-frame-pointer" ])
  @ if macho triple || coff then [] else [ "-ftls-model=local-exec" ]

(* The runtime's sources in [dir] compiled by *cc* with [flags] and the
   [tuning] for [triple] into [output], or with [flags] alone by a C
   compiler that does not take the tuning, which it says nothing of. *)
let compile ~cc ~triple flags dir output =
  let command ?stderr flags =
    Filename.quote_command ?stderr cc (flags @ [ "-c"; "-o"; output; Filename.concat dir "zane.c" ])
  in
  match Sys.command (command ~stderr:Filename.null (flags @ tuning ~triple)) with
  | 0 -> Ok output
  | _ -> (
      let command = command flags in
      match Sys.command command with 0 -> Ok output | n -> Error (Printf.sprintf "`%s` exited with %d" command n))

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
      match Option.bind cache (fun cache -> Option.map (fun id -> (cache, id)) (identity ~cache cc dir)) with
      | None -> compile ~cc ~triple flags dir fresh
      | Some (cache, identity) ->
          let kept =
            Filename.concat (Filename.concat cache "runtime")
              (runtime_key ~cc ~identity ~triple (flags @ tuning ~triple) ^ ".o")
          in
          if Sys.file_exists kept then Ok kept
          else
            Result.map
              (fun object_ ->
                keep ~random:(Random.State.make_self_init ()) ~object_ ~kept;
                object_)
              (compile ~cc ~triple flags dir fresh))

(* A directory of its own for a build's temporary files, given to [f] and
   removed with them however [f] ends, a raise included. *)
let in_work_dir f =
  let dir = Filename.temp_dir "zane" "" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun f -> try Sys.remove (Filename.concat dir f) with Sys_error _ -> ())
        ([ "program.o"; "program"; "program.exe"; "program.pdb"; "program.lib"; "runtime.o"; "runtime.bc" ]
        @ [ "library.o"; "library.so"; "library.dylib"; "library.dll"; "library.pdb"; "library.lib" ]
        @ [ "cc-version"; "cc-link"; "cc-link-words" ]
        @ List.map fst runtime_files);
      try Sys.rmdir dir with Sys_error _ -> ())
    (fun () -> f dir)

let bitcode_flags ~triple target =
  let coff = List.mem "windows" (String.split_on_char '-' triple) in
  target_flag target @ level ~optimize:true @ (if macho triple || coff then [] else [ "-fPIC" ]) @ [ "-emit-llvm" ]

let bundled_bitcode_name ~triple = Filename.chop_suffix (bundled_name ~triple (level ~optimize:true)) ".o" ^ ".bc"

(* [use] given the runtime as LLVM bitcode for [triple], compiled by *cc*
   with the flags of an optimized runtime and position-independent, so no
   definition in it is taken to be the program's own ([Runtime_bodies]), or
   [None] when *cc* cannot make bitcode this LLVM reads. It is kept in
   [cache] beside the objects, and a C compiler that could not make it as an
   empty file, so it is asked once. A released toolchain compiles nothing: it has the bitcode
   it bundles, or none. *)
let with_runtime_bitcode ?bundled ?cache ~cc ~triple ?target use =
  let flags = bitcode_flags ~triple target in
  let present path = if (try (Unix.stat path).Unix.st_size > 0 with Unix.Unix_error _ -> false) then Some path else None in
  match bundled with
  | Some dir -> use (present (Filename.concat dir (bundled_bitcode_name ~triple)))
  | None -> (
      in_work_dir @@ fun dir ->
      match write_runtime dir with
      | exception Sys_error _ -> use None
      | () -> (
          let fresh = Filename.concat dir "runtime.bc" in
          let compiled () = Result.is_ok (compile ~cc ~triple flags dir fresh) && Runtime_bodies.readable fresh in
          match Option.bind cache (fun cache -> Option.map (fun id -> (cache, id)) (identity ~cache cc dir)) with
          | None -> use (if compiled () then present fresh else None)
          | Some (cache, identity) ->
              let kept =
                Filename.concat (Filename.concat cache "runtime")
                  (runtime_key ~cc ~identity ~triple (flags @ tuning ~triple) ^ ".bc")
              in
              if not (Sys.file_exists kept) then begin
                if not (compiled ()) then Out_channel.with_open_bin fresh (fun _ -> ());
                keep ~random:(Random.State.make_self_init ()) ~object_:fresh ~kept
              end;
              use (match present kept with Some _ as kept -> kept | None -> present fresh)))

(* The module emitted for *target* made ready to be written: its shared
   functions in COMDATs, its stack probed, and its passes run, the optimized
   ones when *optimize* and tier 1's for [Tier1] ([Passes.pipeline]). A program means the same either way
   (docs/design/lowering.md §7). A [tier] of a tiered build is fingerprinted
   first, then made tier 0 or tier 1 around its passes (docs/design/tiers.md);
   tier 1 runs the optimized ones. An optimized module, and both tiers, take
   the runtime's bodies for LLVM to inline first ([Runtime_bodies]), the
   tiers the same ones, so tier 0 exports what tier 1's may import. *)
let prepare_whole ?target ?(optimize = false) ?(tier = Tiers.Plain) ?fingerprint ?(bundled = bundled_dir ())
    ?(cache = cache_dir ()) ?whole m =
  let optimize = optimize || tier = Tiers.Tier1 in
  Result.bind (target_machine ?target ~optimize ()) (fun (triple, tm) ->
      let hash =
        match (tier, fingerprint) with
        | Tiers.Plain, _ -> ""
        | _, Some hash -> hash
        | _, None -> Tiers.fingerprint m
      in
      let whole =
        match whole with
        | Some exported when optimize && tier = Tiers.Plain ->
            with_runtime_bitcode ?bundled ?cache ~cc:(bitcode_cc ()) ~triple ?target (function
              | Some path -> Runtime_bodies.whole ~exported path m
              | None -> false)
        | _ -> false
      in
      if (optimize || tier = Tiers.Tier0) && not whole then
        with_runtime_bitcode ?bundled ?cache ~cc:(bitcode_cc ()) ~triple ?target
          (Option.iter (fun path -> ignore (Runtime_bodies.add ~tiered:(tier <> Tiers.Plain) path m)));
      let exports = if tier = Tiers.Tier0 then Some (Tiers.exports m) else None in
      let definitions = if tier = Tiers.Tier1 then Some (Tiers.tier1_definitions m) else None in
      shared_in_comdats triple m;
      probe_stack triple m;
      let data_layout = Llvm_target.TargetMachine.data_layout tm in
      Result.bind (Big_moves.rewrite data_layout m) @@ fun () ->
      if not optimize then Wrappers.mark data_layout m;
      if optimize then llvm_options (Array.of_list ("zanec" :: Passes.llvm_options));
      Llvm_passbuilder.run_passes m (Passes.pipeline ~optimize ~tier1:(tier = Tiers.Tier1)) tm (Llvm_passbuilder.create_passbuilder_options ())
      |> Result.map_error (Printf.sprintf "cannot optimize the module: %s")
      |> Fun.flip Result.bind (fun () ->
             match (exports, definitions) with
             | Some exports, _ -> Ok (Tiers.tier0 m ~hash ~exports)
             | _, Some definitions ->
                 Result.bind (Tiers.tier1_imports m ~hash definitions) (fun () ->
                     match Llvm_analysis.verify_module m with
                     | None -> Ok ()
                     | Some why -> Error (Printf.sprintf "tier 1 is not a valid module: %s" why))
             | None, None -> Ok ())
      |> Result.map (fun () -> (triple, tm, whole)))

let prepare ?target ?optimize ?tier ?fingerprint ?bundled ?cache m =
  Result.map (fun (triple, tm, _) -> (triple, tm)) (prepare_whole ?target ?optimize ?tier ?fingerprint ?bundled ?cache m)

(* The linker command *cc* gives for a program for [target], [triple] in
   LLVM's normal form, linking with [level] and the [runtime] bundled for
   it, kept in [dir]'s `link/` under [bundled_link_name], with every file it
   links besides the program's own copied into `link/files/`, named for its
   contents. A released toolchain then links for [target] without running
   *cc* at all. The loader a program names (`--dynamic-linker`) is a path
   on the machine it runs on, not a file to copy. *)
(* An object for [triple] holding what [fill] puts in a module, for a
   bundled link to name. *)
let stub_object ~triple ~tm obj fill =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "program" in
  Llvm.set_target_triple triple m;
  Llvm.set_data_layout (Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm)) m;
  fill ctx m;
  Llvm_target.TargetMachine.emit_to_file m Llvm_target.CodeGenFileType.ObjectFile obj tm;
  Llvm.dispose_module m;
  Llvm.dispose_context ctx

(* The command *cc* gives for [args], kept in [dir]'s `link/` under
   [name], with every file it links besides [obj] copied into
   `link/files/`, named for its contents. The loader a program names
   (`--dynamic-linker`) is a path on the machine it runs on, not a file to
   copy. *)
let bundle_command ~cc ~target ~triple ~args ~obj ~runtime ~output ~name dir work =
  match marked_link ~cc ~triple ~args ~obj ~runtime ~output work with
  | `Other why | `Unasked why -> Error (Printf.sprintf "cannot bundle the link for `%s`: `%s`: %s" target cc why)
  | `Lld command ->
      let link = Filename.concat dir "link" in
      let files = Filename.concat link "files" in
      make_dirs files;
      let random = Random.State.make_self_init () in
      let rec bundled previous = function
        | [] -> []
        | w :: rest ->
            let option, path = option_split w in
            let copied =
              if
                previous <> "--dynamic-linker"
                && previous <> "-dynamic-linker"
                && (not (Filename.is_relative path))
                && Sys.file_exists path
                && not (Sys.is_directory path)
              then begin
                let name = Digest.to_hex (Digest.file path) ^ "-" ^ Filename.basename path in
                let kept = Filename.concat files name in
                if not (Sys.file_exists kept) then keep ~random ~object_:path ~kept;
                if not (Sys.file_exists kept) then raise (Sys_error (Printf.sprintf "cannot copy %s" path));
                option ^ "\001bundle/files/" ^ name
              end
              else w
            in
            copied :: bundled w rest
      in
      keep_text ~dir:work ~kept:(Filename.concat link name) (String.concat "\000" (bundled "" command));
      Ok ()

let bundle_link ~cc ~target ~triple ~tm level dir work runtime =
  let system = system_libraries (Some target) in
  let obj = Filename.concat work "program.o"
  and output = Filename.concat work (if windows (Some target) then "program.exe" else "program") in
  (* A program as small as the runtime links with (runtime/zane.h), for a
     C compiler such as `zig cc` that links what it prints. *)
  stub_object ~triple ~tm obj (fun ctx m ->
      let main = Llvm.define_function "zane_main" (Llvm.function_type (Llvm.void_type ctx) [||]) m in
      ignore (Llvm.build_ret_void (Llvm.builder_at_end ctx (Llvm.entry_block main)));
      List.iter
        (fun name -> ignore (Llvm.define_global name (Llvm.const_int (Llvm.i64_type ctx) 0) m))
        [ "zane_fixed_region"; "zane_spawned_fixed_region" ]);
  let args = target_flag (Some target) @ level @ [ "-o"; output; obj; runtime ] @ system in
  bundle_command ~cc ~target ~triple ~args ~obj ~runtime ~output ~name:(bundled_link_name ~triple level system) dir work

(* The linker command *cc* gives for tier 1 of a tiered build for [target]
   (docs/design/tiers.md), a shared library linked with [level], kept as
   [bundle_link] keeps a program's, so a released toolchain links tier 1
   without running *cc* either. *)
let bundle_shared_link ~cc ~target ~triple ~tm level dir work =
  let system = shared_libraries (Some target) in
  let obj = Filename.concat work "library.o"
  and output = Filename.concat work ("library" ^ shared_extension triple) in
  stub_object ~triple ~tm obj (fun ctx m ->
      let g = Llvm.define_global "__zane_tier1" (Llvm.const_int (Llvm.i64_type ctx) 0) m in
      Llvm.set_dll_storage_class Llvm.DLLStorageClass.DLLExport g);
  let args = target_flag (Some target) @ level @ shared @ [ "-o"; output; obj ] @ system in
  bundle_command ~cc ~target ~triple ~args ~obj ~runtime:"" ~output
    ~name:(bundled_link_name ~triple (shared @ level) system)
    dir work

(* The runtime's bitcode for [triple] beside its optimized object, under the
   name a build looks for there ([with_runtime_bitcode]), when *cc* makes
   bitcode this LLVM reads. One newer than it writes bitcode it cannot, and
   the release then bundles none: its builds call the runtime's functions
   rather than inline them. *)
let bundle_bitcode ~cc ~triple ~target dir work =
  let path = Filename.concat dir (bundled_bitcode_name ~triple) in
  match compile ~cc ~triple (bitcode_flags ~triple (Some target)) work path with
  | Ok _ when Runtime_bodies.readable path -> ()
  | Ok _ | Error _ -> ( try Sys.remove path with Sys_error _ -> ())

(* The runtime compiled for [target], with or without optimizing, into
   [dir] under the name a build for that target looks for there
   ([bundled_name]), and the linker command and files that link a program
   with it ([bundle_link]), and an optimized one's bitcode
   ([bundle_bitcode]): what a release bundles for each target it ships
   (docs/design/lowering.md §7). A target is required, since a C compiler
   given none compiles for the processor it runs on. *)
let bundle_runtime ~target ~optimize dir =
  Result.bind (target_machine ~target ~optimize ()) @@ fun (triple, tm) ->
  in_work_dir @@ fun work ->
  match
    write_runtime work;
    make_dirs dir
  with
  | exception Sys_error message -> Error (Printf.sprintf "cannot write the runtime: %s" message)
  | () -> (
      let level = level ~optimize and cc = cc () in
      let runtime = Filename.concat dir (bundled_name ~triple level) in
      match compile ~cc ~triple (target_flag (Some target) @ level) work runtime with
      | Error _ as error -> error
      | Ok _ -> (
          if optimize then bundle_bitcode ~cc:(bitcode_cc ()) ~triple ~target dir work;
          match
            Result.bind (bundle_link ~cc ~target ~triple ~tm level dir work runtime) (fun () ->
                if optimize then bundle_shared_link ~cc ~target ~triple ~tm level dir work else Ok ())
          with
          | result -> result
          | exception Sys_error message -> Error (Printf.sprintf "cannot bundle the link: %s" message)
          | exception Llvm_target.Error message -> Error (Printf.sprintf "cannot bundle the link: %s" message)))

(* The module's object file alone, for a package other objects link with
   (docs/design/separate-compilation.md C3): no runtime, and no link. *)
let object_file ?target ?(optimize = false) ?tier m output =
  Result.bind (prepare ?target ~optimize ?tier m) (fun (_, tm) ->
      match Llvm_target.TargetMachine.emit_to_file m Llvm_target.CodeGenFileType.ObjectFile output tm with
      | () -> Ok ()
      | exception Llvm_target.Error message ->
          Error (Printf.sprintf "cannot write the object file: %s" message))

(* An object of nothing, linked where the runtime would be when the
   program's module holds the whole runtime ([Runtime_bodies.whole]). *)
let empty_object ~triple tm path =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "runtime" in
  Llvm.set_target_triple triple m;
  let result =
    match Llvm_target.TargetMachine.emit_to_file m Llvm_target.CodeGenFileType.ObjectFile path tm with
    | () -> Ok path
    | exception Llvm_target.Error message -> Error (Printf.sprintf "cannot write the object file: %s" message)
  in
  Llvm.dispose_module m;
  Llvm.dispose_context ctx;
  result

(* [link] is the objects of the program's stamped dependencies, which the C
   compiler links with it (docs/design/separate-compilation.md C7). [cache]
   is where the compiled runtime is kept, [cache_dir ()] unless given, and
   [bundled] where the toolchain keeps its own, [bundled_dir ()] unless
   given. *)
let executable ?target ?(optimize = false) ?tier ?(link = []) ?(bundled = bundled_dir ()) ?(cache = cache_dir ())
    m output =
  match prepare_whole ?target ~optimize ?tier ~whole:(link <> []) m with
  | Error _ as error -> error
  | Ok (triple, tm, whole) -> (
      let cc = cc () in
      let level = level ~optimize and system = system_libraries target in
      let flags = target_flag target @ level in
      let args obj runtime = flags @ [ "-o"; output; obj ] @ link @ [ runtime ] @ system in
      let bundled_link =
        Option.map
          (fun dir -> List.fold_left Filename.concat dir [ "link"; bundled_link_name ~triple level system ])
          bundled
      in
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
          (* Tier 1 calls tier 0's runtime (docs/design/tiers.md T5), so tier
             0 links the optimized one. *)
          let optimize = optimize || tier = Some Tiers.Tier0 in
          let runtime =
            if whole then empty_object ~triple tm (Filename.concat dir "runtime.o")
            else runtime_object ?bundled ?cache ~cc ~triple ?target ~optimize dir
          in
          match runtime with
          | Error _ as error -> error
          | Ok runtime -> (
              link_program ?cache ?bundled:bundled_link ~cc ~triple ~args:(args obj runtime) ~deps:link ~obj
                ~runtime ~output dir)))

(* How many tier-1 libraries the cache keeps: the newest, so an edit loop
   does not fill the disk with every version it built. *)
let kept_tiers = 32

(* The compiler itself, as the cache tells one build of it from another:
   the file that runs, its size and when it last changed. *)
let compiler_identity () =
  let path = Sys.executable_name in
  match Unix.stat path with
  | stat -> String.concat "\000" [ path; string_of_int stat.Unix.st_size; Printf.sprintf "%h" stat.Unix.st_mtime ]
  | exception Unix.Unix_error _ -> path

(* The oldest of [dir]'s files removed until [keep] are left. *)
let trim dir keep =
  match Sys.readdir dir with
  | exception Sys_error _ -> ()
  | names ->
      let files =
        Array.to_list names
        |> List.filter (fun n -> not (String.starts_with ~prefix:"." n))
        |> List.filter_map (fun n ->
               let path = Filename.concat dir n in
               match Unix.stat path with stat -> Some (stat.Unix.st_mtime, path) | exception Unix.Unix_error _ -> None)
        |> List.sort (fun (a, _) (b, _) -> compare b a)
      in
      List.iteri (fun i (_, path) -> if i >= keep then try Sys.remove path with Sys_error _ -> ()) files

(* [file] put at [output] whole: copied beside it and renamed into place,
   so a reader never sees half of it. *)
let install ~file ~output =
  let temporary = output ^ ".partial" in
  match
    let contents = In_channel.with_open_bin file In_channel.input_all in
    Out_channel.with_open_bin temporary (fun oc -> output_string oc contents);
    Sys.rename temporary output
  with
  | () -> Ok ()
  | exception Sys_error message ->
      (try Sys.remove temporary with Sys_error _ -> ());
      Error (Printf.sprintf "cannot write %s: %s" output message)

(* [path] and everything in it removed, as far as it can be. A link is
   removed itself, never what it points to. *)
let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> (
      (match Sys.readdir path with
      | names -> Array.iter (fun n -> remove_tree (Filename.concat path n)) names
      | exception Sys_error _ -> ());
      try Sys.rmdir path with Sys_error _ -> ())
  | _ -> ( try Sys.remove path with Sys_error _ -> ())
  | exception Unix.Unix_error _ -> ()

(* Tier 1 of a tiered build (docs/design/tiers.md): the module made tier 1
   and linked into the shared library [output], against the C library only.
   Its files are made in `OUTPUT.work/`, which is removed after, and the
   library is renamed into place, so the program waiting for it never loads
   half of one. The library is kept in [cache]'s `tier/` under the module's
   fingerprint, the target, the C compiler and this compiler, and a later
   build of the same module takes it from there without optimizing or
   linking. *)
let shared_library ?target ?(bundled = bundled_dir ()) ?(cache = cache_dir ()) m output =
  let work = output ^ ".work" in
  remove_tree work;
  match make_dirs work with
  | exception Sys_error message -> Error (Printf.sprintf "cannot make %s: %s" work message)
  | () ->
      Fun.protect ~finally:(fun () -> remove_tree work) @@ fun () ->
      let cc = cc () in
      let fingerprint = Tiers.fingerprint m in
      let triple = Llvm.target_triple m in
      (* A released toolchain's bundle is used only with the C compiler that
         made it, so it names that compiler without asking it. *)
      let cc_identity cache =
        match bundled with Some dir -> Some ("bundled " ^ dir) | None -> identity ~cache cc work
      in
      let kept =
        Option.bind cache (fun cache ->
            Option.map
              (fun identity ->
                let key =
                  String.concat "\000"
                    ([ fingerprint; triple; cc; identity; compiler_identity (); Passes.tier1 ]
                    @ Passes.llvm_options)
                in
                Filename.concat (Filename.concat cache "tier")
                  (Digest.to_hex (Digest.string key) ^ shared_extension triple))
              (cc_identity cache))
      in
      match kept with
      | Some kept when Sys.file_exists kept ->
          (* Taken now, it is the newest the cache holds. *)
          (try Unix.utimes kept 0. 0. with Unix.Unix_error _ -> ());
          install ~file:kept ~output
      | _ -> (
          match prepare ?target ~tier:Tiers.Tier1 ~fingerprint m with
          | Error _ as error -> error
          | Ok (triple, tm) -> (
              let obj = Filename.concat work "library.o" in
              let library = Filename.concat work ("library" ^ shared_extension triple) in
              match Llvm_target.TargetMachine.emit_to_file m Llvm_target.CodeGenFileType.ObjectFile obj tm with
              | exception Llvm_target.Error message -> Error (Printf.sprintf "cannot write the object file: %s" message)
              | () -> (
                  let level = level ~optimize:true and system = shared_libraries target in
                  let args = target_flag target @ level @ shared @ [ "-o"; library; obj ] @ system in
                  let bundled_link =
                    Option.map
                      (fun dir ->
                        List.fold_left Filename.concat dir
                          [ "link"; bundled_link_name ~triple (shared @ level) system ])
                      bundled
                  in
                  match
                    link_program ?cache ?bundled:bundled_link ~cc ~triple ~args ~deps:[] ~obj ~runtime:""
                      ~output:library work
                  with
                  | Error _ as error -> error
                  | Ok () ->
                      Option.iter
                        (fun kept ->
                          keep ~random:(Random.State.make_self_init ()) ~object_:library ~kept;
                          trim (Filename.dirname kept) kept_tiers)
                        kept;
                      install ~file:library ~output)))

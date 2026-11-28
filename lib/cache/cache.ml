(* The directory where builds keep compiled files, and how a file is
   written there. Codegen keeps the runtime and links there
   (docs/design/lowering.md §7), and the C front end keeps include
   directories, headers and modules (docs/design/ffi.md F1, F3). The cache
   is an optimization, so every write here may fail, and the build then
   compiles the file again. *)

(* The directory that keeps compiled files between builds: `ZANE_CACHE_DIR` if
   set, else the platform's cache directory, or [None] when the platform has
   none. *)
let dir () =
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

(* A root directory that does not exist, such as an unmounted drive, is its own
   parent, so the mkdir below fails there instead of climbing forever. *)
let rec make_dirs dir =
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if parent <> dir then make_dirs parent;
    try Sys.mkdir dir 0o755 with Sys_error _ when Sys.file_exists dir -> ()
  end

(* Copies [object_] into the cache as [kept]. The copy is written to a temporary
   file beside [kept] and renamed into place, so a build reading the cache never
   sees half an object. The cache is an optimization: any failure leaves the
   cache unchanged and the build goes on. *)
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

(* The executable that the command *cc* runs. When *cc* contains a directory,
   it is *cc* itself. Otherwise it is the first executable file named *cc* in a
   directory on `PATH`, where an empty entry is the current directory, and
   [None] when no directory has one. On Windows the command search also checks
   the current directory and each extension in `PATHEXT`, so this function
   returns [None] there, and the compiler's version is asked every time. *)
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

(* The version string that *cc* reports, written to a file in [dir], or [None]
   when *cc* reports none; then nothing *cc* compiles is kept. Asking costs a
   run of the C compiler, about as long as the rest of a small unoptimized
   build, so the answer is kept in [cache]. Its key is the executable *cc* runs,
   with that file's size, modification time, inode and device, and this
   function runs the compiler again only when one of those changes. *)
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

(* Keeps [text] in the cache as [kept], by first writing it to a file in
   [dir]. *)
let keep_string ~dir ~kept text =
  let random = Random.State.make_self_init () in
  let file = Filename.concat dir (Printf.sprintf "kept-%08x" (Random.State.bits random)) in
  try
    make_dirs dir;
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o644 file (fun oc ->
        output_string oc text);
    keep ~random ~object_:file ~kept;
    Sys.remove file
  with Sys_error _ -> ( try Sys.remove file with Sys_error _ -> ())

(* The contents of [path], or [None] when it cannot be read. *)
let read path = try Some (In_channel.with_open_bin path In_channel.input_all) with Sys_error _ -> None

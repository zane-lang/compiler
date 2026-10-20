(* How a build keeps its compiled runtime, finds the one a release bundles,
   and links: through the LLD in the compiler with the command its C
   compiler gives or the release bundles, or through the C compiler. *)

open Support

(* A build compiles the runtime once for each compiler and set of flags and
   takes it from the cache after that; a cache it cannot write to costs the
   build nothing but the time. *)
let cached_runtime () =
  let module Build = Codegen__Build in
  let directory = Filename.temp_dir "zane-runtime" "" in
  Fun.protect ~finally:(fun () -> remove_tree directory) @@ fun () ->
  let work = Filename.concat directory "work" and cache = Filename.concat directory "cache" in
  Sys.mkdir work 0o755;
  Build.write_runtime work;
  let cc = Build.cc () in
  let kept () =
    match Sys.readdir (Filename.concat cache "runtime") with
    | names -> List.filter (fun n -> Filename.check_suffix n ".o") (Array.to_list names)
    | exception Sys_error _ -> []
  in
  let host = Llvm_target.Target.default_triple () in
  let compiled ?(triple = host) ?(optimize = false) () = Build.runtime_object ~cache ~cc ~triple ~optimize work in
  let in_cache = function
    | Ok path -> String.starts_with ~prefix:cache path
    | Error _ -> false
  in
  let first = compiled () in
  check "a runtime not yet kept is compiled" (Result.is_ok first && not (in_cache first));
  check "and kept" (List.length (kept ()) = 1);
  let second = compiled () in
  check "the same flags take it from the cache" (in_cache second);
  check "and keep no second copy" (List.length (kept ()) = 1);
  let other = compiled ~optimize:true () in
  check "other flags compile their own" (Result.is_ok other && not (in_cache other));
  check "and keep it beside the first" (List.length (kept ()) = 2);
  let elsewhere = compiled ~triple:"x86_64-unknown-linux-musl" () in
  check "another triple compiles its own, though the flags name none"
    (Result.is_ok elsewhere && not (in_cache elsewhere) && List.length (kept ()) = 3);
  let blocked = Filename.concat directory "file" in
  write_all blocked "not a directory";
  let unwritable =
    Build.runtime_object ~cache:(Filename.concat blocked "cache") ~cc ~triple:host ~optimize:false work
  in
  check "a cache that cannot be made still compiles the runtime" (Result.is_ok unwritable);
  let uncached = Build.runtime_object ~cc ~triple:host ~optimize:false work in
  check "no cache compiles the runtime" (Result.is_ok uncached && not (in_cache uncached));
  (* What a C compiler says it is is asked once, and again only once the
     file it runs has changed. *)
  if Sys.unix then begin
    let asked = Filename.concat directory "asked" and fake = Filename.concat directory "fake-cc" in
    let script extra =
      write_all fake
        (Printf.sprintf "#!/bin/sh\n[ \"$1\" = --version ] && echo asked >> %s\necho fake 1.0%s\n"
           (Filename.quote asked) extra);
      Unix.chmod fake 0o755
    in
    let times () = match read_all asked with Some s -> List.length (String.split_on_char '\n' s) - 1 | None -> 0 in
    script "";
    let first = Build.identity ~cache fake work in
    check "a C compiler's identity is asked the first time" (first = Some "fake 1.0\n" && times () = 1);
    let again = Build.identity ~cache fake work in
    check "and kept after that" (again = first && times () = 1);
    script " changed";
    let changed = Build.identity ~cache fake work in
    check "a changed C compiler is asked again" (changed = Some "fake 1.0 changed\n" && times () = 2);
    check "one found nowhere has none"
      (Build.identity ~cache "zane-no-such-compiler" work = None);
    (* A name on the path is found where the shell would run it: a file of
       the name that cannot run is passed over. *)
    let first = Filename.concat directory "first" and second = Filename.concat directory "second" in
    Sys.mkdir first 0o755;
    Sys.mkdir second 0o755;
    write_all (Filename.concat first "zane-cc") "not a program";
    write_all (Filename.concat second "zane-cc") "#!/bin/sh\n";
    Unix.chmod (Filename.concat second "zane-cc") 0o755;
    let path = Sys.getenv_opt "PATH" in
    Unix.putenv "PATH" (first ^ ":" ^ second);
    let found = Build.located "zane-cc" in
    Unix.putenv "PATH" (Option.value ~default:"" path);
    check "a file on the path that cannot run is passed over"
      (found = Some (Filename.concat second "zane-cc"))
  end

(* A link runs the LLD in the compiler with the command the C compiler
   prints for it with `-###`, asked once for a compiler, target and flags and
   kept, with each build's own files put in: as words of their own, as
   `ld.lld` takes them, or after an option's `:`, as `lld-link` does, with the
   files a COFF link writes beside the executable named for it. A C compiler
   whose linker is not LLD links itself. *)
let linked_in_process () =
  if Sys.unix then begin
    let module Build = Codegen__Build in
    let directory = Filename.temp_dir "zane-link" "" in
    Fun.protect ~finally:(fun () -> remove_tree directory) @@ fun () ->
    let cache = Filename.concat directory "cache" and work = Filename.concat directory "work" in
    Sys.mkdir work 0o755;
    let asked = Filename.concat directory "asked" in
    let fake ?(links = true) name linker =
      let path = Filename.concat directory name in
      write_all path
        (Printf.sprintf
           "#!/bin/sh\n\
            case \" $* \" in *' -### '*|*' -print-search-dirs '*) ;; *' --version '*) echo fake 1.0; exit 0;; *) exit %d;; esac\n\
            echo asked >> %s\n\
            %s >&2\n"
           (if links then 0 else 1)
           (Filename.quote asked) linker);
      Unix.chmod path 0o755;
      path
    in
    let times () = match read_all asked with Some s -> List.length (String.split_on_char '\n' s) - 1 | None -> 0 in
    let args ~obj ~runtime ~output = [ "-O0"; "-o"; output; obj; "-lm"; runtime ] in
    let command cc ~obj ~runtime ~output =
      match Build.link_command ~cache ~cc ~triple:"t" ~args:(args ~obj ~runtime ~output) ~obj ~runtime ~output work with
      | Build.Lld { command; _ } -> Some command
      | Build.Cc _ -> None
    in
    let elf =
      fake "elf-cc"
        {|printf 'clang version 1\n'; printf ' "/x/ld.lld" "-z" "now"'; for a; do [ "$a" = -### ] || printf ' "%s"' "$a"; done; printf '\n'|}
    in
    let first = command elf ~obj:"/w1/program.o" ~runtime:"/r/runtime.o" ~output:"out one" in
    check "an ELF link is LLD's, as the C compiler prints it"
      (first = Some [ "ld.lld"; "-z"; "now"; "-O0"; "-o"; "out one"; "/w1/program.o"; "-lm"; "/r/runtime.o" ]
      && times () = 1);
    let second = command elf ~obj:"/w2/program.o" ~runtime:"/r/runtime.o" ~output:"two" in
    check "and is kept, with the next build's files put in"
      (second = Some [ "ld.lld"; "-z"; "now"; "-O0"; "-o"; "two"; "/w2/program.o"; "-lm"; "/r/runtime.o" ]
      && times () = 1);
    let coff =
      fake "coff-cc"
        {|for a; do case "$a" in -o) out=1;; -###|-O0|-lm) ;; *) if [ -n "$out" ]; then o="$a"; out=; else objs="$objs $a"; fi;; esac; done; s="${o%.exe}"; echo "lld-link -MLLVM:-float-abi=hard -OUT:$o -PDB:$s.pdb -PDBALTPATH:$(basename "$s").pdb -IMPLIB:./$s.lib$objs"|}
    in
    ignore (command coff ~obj:"/w1/program.o" ~runtime:"/r/runtime.o" ~output:"hello.exe");
    let again = command coff ~obj:"/w2/program.o" ~runtime:"/r/runtime.o" ~output:"/b/bye.exe" in
    check "a COFF link names its files after an option's colon, and drops LLVM's options"
      (again
      = Some
          [ "lld-link"; "-OUT:/b/bye.exe"; "-PDB:/b/bye.pdb"; "-PDBALTPATH:bye.pdb"; "-IMPLIB:/b/bye.lib"; "/w2/program.o"; "/r/runtime.o" ]);
    let gnu = fake "gnu-cc" {|printf ' "/usr/bin/ld" "-o" "x"\n'|} in
    let before = times () in
    check "a linker that is not LLD links as a program of its own"
      (command gnu ~obj:"/w/program.o" ~runtime:"/r/runtime.o" ~output:"x" = None);
    check "and is asked about once, plainly and for LLD"
      (command gnu ~obj:"/w2/program.o" ~runtime:"/r/runtime.o" ~output:"y" = None && times () = before + 2);
    let said = Buffer.create 64 in
    let linked ?(lld = fun _ -> Error "lld: error: stale\n") cc ~output =
      Buffer.clear said;
      let obj = "/w/program.o" and runtime = "/r/runtime.o" in
      Build.link_program ~cache ~lld ~say:(Buffer.add_string said) ~cc ~triple:"t" ~deps:[]
        ~args:(args ~obj ~runtime ~output) ~obj ~runtime ~output work
    in
    let warned () =
      String.starts_with ~prefix:"zanec: warning:" (Buffer.contents said)
      && String.ends_with ~suffix:"lld: error: stale\n" (Buffer.contents said)
    in
    let before = times () in
    check "a kept command LLD fails on, where the C compiler links, is warned of"
      (Result.is_ok (linked elf ~output:"three") && warned ());
    check "and asked for again"
      (command elf ~obj:"/w/program.o" ~runtime:"/r/runtime.o" ~output:"three" <> None
      && times () = before + 1);
    let echoing =
      {|printf ' "/x/ld.lld"'; for a; do [ "$a" = -### ] || printf ' "%s"' "$a"; done; printf '\n'|}
    in
    let fresh = fake "fresh-cc" echoing in
    check "a command just asked for that LLD fails on is warned of"
      (Result.is_ok (linked fresh ~output:"four") && warned ());
    let before = times () in
    check "and the C compiler links from then on"
      (command fresh ~obj:"/w/program.o" ~runtime:"/r/runtime.o" ~output:"four" = None && times () = before);
    let failing = fake ~links:false "failing-cc" echoing in
    let before = times () in
    check "a program neither links is an error, and not warned of"
      (Result.is_error (linked failing ~output:"five") && Buffer.length said = 0);
    check "and its command is kept"
      (command failing ~obj:"/w/program.o" ~runtime:"/r/runtime.o" ~output:"five" <> None && times () = before + 1);
    Unix.putenv "ZANE_VERBOSE" "1";
    let quiet = linked gnu ~output:"x" in
    Unix.putenv "ZANE_VERBOSE" "";
    check "ZANE_VERBOSE says why the C compiler links"
      (Result.is_ok quiet && Buffer.contents said = Printf.sprintf "zanec: `%s` links: its linker is not LLD\n" gnu);
    check "and is quiet when LLD links"
      (Result.is_ok (linked ~lld:(fun _ -> Ok ()) elf ~output:"six") && Buffer.length said = 0);
    let gcc =
      fake "gcc-cc"
        {|printf ' /usr/libexec/gcc/13/collect2 -plugin /p/lto.so -plugin-opt=-pass-through=-lgcc -m elf_x86_64'; for a; do [ "$a" = -### ] || printf ' %s' "$a"; done; printf '\n'|}
    in
    check "GCC's collect2 runs as ld.lld, without its LTO plugin"
      (command gcc ~obj:"/w/program.o" ~runtime:"/r/runtime.o" ~output:"g"
      = Some [ "ld.lld"; "-m"; "elf_x86_64"; "-O0"; "-o"; "g"; "/w/program.o"; "-lm"; "/r/runtime.o" ]);
    let system_ld =
      fake "ld-cc"
        {|case " $* " in *' -fuse-ld=lld '*) l=/u/ld.lld;; *) l=/usr/bin/ld;; esac; printf ' "%s"' "$l"; for a; do case "$a" in -###|-fuse-ld=lld) ;; *) printf ' "%s"' "$a";; esac; done; printf '\n'|}
    in
    check "a C compiler with another linker is asked for LLD's command"
      (command system_ld ~obj:"/w/program.o" ~runtime:"/r/runtime.o" ~output:"s"
      = Some [ "ld.lld"; "-O0"; "-o"; "s"; "/w/program.o"; "-lm"; "/r/runtime.o" ]);
    let zig = Filename.concat directory "zig" in
    List.iter (fun d -> Sys.mkdir d 0o755)
      (List.map (List.fold_left Filename.concat zig) [ []; [ "lib" ]; [ "lib"; "libc" ]; [ "lib"; "libc"; "darwin" ] ]);
    let tbd = List.fold_left Filename.concat zig [ "lib"; "libc"; "darwin"; "libSystem.tbd" ] in
    write_all tbd "--- !tapi-tbd\n";
    let macos =
      fake "macos-cc"
        (Printf.sprintf
           {|case " $* " in *' -print-search-dirs '*) echo "programs: =/nowhere:%s"; exit 0;; esac; printf 'zig ld -dynamic -e _main'; for a; do [ "$a" = -### ] || printf ' %%s' "$a"; done; printf ' -lSystem\n'|}
           zig)
    in
    check "Zig's Mach-O linker runs as ld64.lld, with Zig's libSystem"
      (match
         Build.link_command ~cache ~cc:macos ~triple:"arm64-apple-macosx"
           ~args:(args ~obj:"/w/program.o" ~runtime:"/r/runtime.o" ~output:"m")
           ~obj:"/w/program.o" ~runtime:"/r/runtime.o" ~output:"m" work
       with
      | Build.Lld { command; _ } ->
          command
          = [ "ld64.lld"; "-arch"; "arm64"; "-dynamic"; "-e"; "_main"; "-O0"; "-o"; "m"; "/w/program.o"; "-lm"; "/r/runtime.o"; tbd ]
      | Build.Cc _ -> false);
    check "clang's quoted words and zig's plain ones are both read"
      (Build.words {| "/a b/ld.lld" "-o" "x\"y"|} = [ "/a b/ld.lld"; "-o"; {|x"y|} ]
      && Build.words "ld.lld -o out a.o" = [ "ld.lld"; "-o"; "out"; "a.o" ])
  end

(* A released toolchain's own runtimes are found by the triple a build is
   for and whether it optimizes, whichever spelling of the target it was
   given, and before the cache; any other build compiles its own. *)
let bundled_runtime () =
  let module Build = Codegen__Build in
  let directory = Filename.temp_dir "zane-bundled" "" in
  Fun.protect ~finally:(fun () -> remove_tree directory) @@ fun () ->
  let work = Filename.concat directory "work"
  and bundled = Filename.concat directory "bundled"
  and cache = Filename.concat directory "cache" in
  Sys.mkdir work 0o755;
  Build.write_runtime work;
  let host = Llvm_target.Target.default_triple () in
  let bundle optimize = Build.bundle_runtime ~target:host ~optimize bundled in
  check "a runtime is bundled" (Result.is_ok (bundle false));
  check "into a directory made for it"
    (List.sort compare (List.map Filename.extension (Array.to_list (Sys.readdir bundled))) = [ ""; ".o" ]);
  let cc = Build.cc () in
  let found ?target ?(triple = host) ~optimize () =
    match Build.runtime_object ~bundled ~cache ~cc ~triple ?target ~optimize work with
    | Ok path -> String.starts_with ~prefix:bundled path
    | Error _ -> false
  in
  check "a build for the host links the bundled runtime" (found ~optimize:false ());
  check "as does one naming the host as its target" (found ~target:host ~optimize:false ());
  check "and the cache is left alone" (not (Sys.file_exists cache));
  check "an optimized build compiles its own" (not (found ~optimize:true ()));
  check "as does a build for another triple" (not (found ~triple:"x86_64-unknown-linux-musl" ~optimize:false ()));
  check "an optimized runtime is bundled beside the other" (Result.is_ok (bundle true));
  check "and is linked by an optimized build" (found ~optimize:true ());
  (* Each runtime is bundled with the command that links a program with
     it, which a build runs with its own files and its dependencies'. *)
  let linked = ref [] in
  let lld command =
    linked := command;
    Ok ()
  in
  let level = Build.level ~optimize:false and system = Build.system_libraries None in
  let command = List.fold_left Filename.concat bundled [ "link"; Build.bundled_link_name ~triple:host level system ] in
  let obj = Filename.concat work "program.o" and runtime = "/r/runtime.o" and output = Filename.concat work "out" in
  check "its link is bundled with it"
    (Result.is_ok
       (Build.link_program ~bundled:command ~lld ~cc:"false" ~triple:host ~args:[] ~deps:[ "/d/dep.o" ] ~obj ~runtime
          ~output work)
    && Sys.file_exists command);
  let rec after_obj = function o :: d :: _ when o = obj -> d = "/d/dep.o" | _ :: rest -> after_obj rest | [] -> false in
  let bundled_files =
    List.filter (String.starts_with ~prefix:(Filename.concat bundled "link/files/")) !linked
  in
  check "and a build runs it with its own files, its dependencies' after its object"
    (List.mem output !linked && List.mem runtime !linked && after_obj !linked);
  check "and the files the link takes from the bundle"
    (bundled_files <> [] && List.for_all Sys.file_exists bundled_files);
  let refused = Build.bundle_runtime ~target:"i386-unknown-linux-gnu" ~optimize:false bundled in
  check "a target the compiler does not build for is refused" (Result.is_error refused)

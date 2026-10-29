(* The C interface's front half (lib/foreign/, docs/design/ffi.md §1): a
   package's `c.coda`, the include directories a C compiler names, the
   cache key of a compiled source, and the linked clang compiling one. *)

open Support
module Settings = Foreign.Settings
module Probe = Foreign.Probe
module Compile = Foreign.Compile
module Clang = Foreign.Clang

let patterns () =
  check "* alone matches any target" (Settings.glob_matches "*" "x86_64-unknown-linux-gnu");
  check "a pattern matches a triple" (Settings.glob_matches "*-linux-*" "x86_64-unknown-linux-gnu");
  check "a pattern misses another" (not (Settings.glob_matches "*-apple-*" "x86_64-unknown-linux-gnu"));
  check "* matches an empty run" (Settings.glob_matches "a*b" "ab");
  check "a pattern backtracks" (Settings.glob_matches "*.c" "deflate.h.c");
  check "a pattern without * is the text" (not (Settings.glob_matches "deflate.c" "deflate.cc"))

let paths () =
  check "a relative path is its parts" (Settings.relative_parts "vendor/./zlib" = Ok [ "vendor"; "zlib" ]);
  check "a .. inside the directory is allowed" (Settings.relative_parts "vendor/../src" = Ok [ "src" ]);
  check "a .. that leaves is refused" (Result.is_error (Settings.relative_parts "vendor/../../x"));
  check "an absolute path is refused" (Result.is_error (Settings.relative_parts "/usr/include"));
  check "a drive path is refused" (Result.is_error (Settings.relative_parts "C:\\include"));
  check "a define of a name" (Settings.define_problem "HAVE_UNISTD_H=1" = None);
  check "a define of a fixed macro is refused" (Settings.define_problem "__FAST_MATH__" <> None);
  check "a define that is no name is refused" (Settings.define_problem "1X=2" <> None)

(* What GCC, clang and `zig cc` print for `-E -v`, as the probe reads it. *)
let search_lists () =
  let gcc =
    "#include \"...\" search starts here:\n\
     #include <...> search starts here:\n\
    \ /usr/lib/gcc/x86_64-linux-gnu/13/include\n\
    \ /usr/local/include\n\
    \ /usr/include/x86_64-linux-gnu\n\
    \ /usr/include\n\
     End of search list.\n"
  in
  check "GCC's list"
    (Probe.search_list gcc
    = [
        Probe.System "/usr/lib/gcc/x86_64-linux-gnu/13/include";
        Probe.System "/usr/local/include";
        Probe.System "/usr/include/x86_64-linux-gnu";
        Probe.System "/usr/include";
      ]);
  let macos =
    "#include <...> search starts here:\n\
    \ /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include\n\
    \ /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks (framework directory)\n\
     End of search list.\n"
  in
  check "a framework directory"
    (Probe.search_list macos
    = [
        Probe.System "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include";
        Probe.Framework "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks";
      ]);
  check "no list is no directories" (Probe.search_list "clang: error: unknown argument" = []);
  check "gcc is GCC" (Probe.kind_of ~name:"gcc" "gcc (Ubuntu 13.2.0) 13.2.0\nCopyright" = Probe.Gcc);
  check "zig cc is a clang" (Probe.kind_of ~name:"zig-cc" "clang version 21.1.0 (zig)" = Probe.Clang);
  check "cl.exe is MSVC" (Probe.kind_of ~name:"cl.exe" "" = Probe.Msvc);
  check "clang-cl is MSVC's mode" (Probe.kind_of ~name:"clang-cl" "clang version 19.1.7" = Probe.Msvc)

(* A GCC the probe runs: a script that answers `--version`, `-dumpmachine`
   and `-E -v` as a GCC built for [machine] does, its search list [dir]. *)
let fake_gcc ~machine ~dir path =
  write_all path
    (Printf.sprintf
       "#!/bin/sh\n\
        case \"$1\" in\n\
        --version) echo 'gcc (fake) 13.2.0' ;;\n\
        -dumpmachine) echo %s ;;\n\
        -E) printf '#include <...> search starts here:\\n %s\\nEnd of search list.\\n' >&2 ;;\n\
        esac\n"
       machine dir);
  Unix.chmod path 0o755

(* A GCC checked against the build's target when none is named, and the
   probe's answer kept under the file a bare command runs. *)
let probes () =
  if not Sys.win32 then begin
    let base = Filename.temp_dir "zane-probe-" "" in
    let path = Sys.getenv_opt "PATH" in
    Fun.protect
      ~finally:(fun () ->
        Unix.putenv "PATH" (Option.value ~default:"" path);
        remove_tree base)
      (fun () ->
        let bin name =
          let d = Filename.concat base name in
          Sys.mkdir d 0o755;
          d
        in
        let a = bin "a" and b = bin "b" and cache = bin "cache" and work = bin "work" in
        fake_gcc ~machine:"x86_64-linux-gnu" ~dir:"/a/include" (Filename.concat a "gcc");
        fake_gcc ~machine:"x86_64-linux-gnu" ~dir:"/b/include" (Filename.concat b "gcc");
        let other = Filename.concat a "cross-gcc" in
        fake_gcc ~machine:"aarch64-linux-gnu" ~dir:"/x/include" other;
        let host = "x86_64-unknown-linux-gnu" in
        check "a GCC for another target is refused when the host is the target"
          (Result.is_error (Probe.include_dirs ~dir:work ~cc:other ~triple:host None));
        let dirs on =
          Unix.putenv "PATH" on;
          Probe.include_dirs ~cache ~dir:work ~cc:"gcc" ~triple:host None
        in
        check "a bare gcc is probed where PATH finds it" (dirs a = Ok [ Probe.System "/a/include" ]);
        check "another gcc PATH finds is probed again" (dirs b = Ok [ Probe.System "/b/include" ]))
  end

let triples () =
  check "a missing vendor is the same ABI" (Clang.same_abi "x86_64-linux-gnu" "x86_64-pc-linux-gnu");
  check "another environment is another ABI" (not (Clang.same_abi "x86_64-linux-gnu" "x86_64-linux-musl"));
  check "another architecture is another ABI" (not (Clang.same_abi "x86_64-linux-gnu" "aarch64-linux-gnu"))

let mapping () =
  let maps = [ ("/home/a/zlib", "/zane/pkg"); ("/home/a/zlib/x", "/zane/other") ] in
  check "the longest directory is mapped first"
    (Compile.mapped maps "# 1 \"/home/a/zlib/x/y.h\"\n# 2 \"/home/a/zlib/z.h\""
    = "# 1 \"/zane/other/y.h\"\n# 2 \"/zane/pkg/z.h\"");
  (* Only a path is mapped: a package directory named like an identifier
     leaves the source text, and a `-D` value, as written. *)
  let maps = [ ("foo", "/zane/pkg") ] in
  check "a line marker's file is mapped and the code is not"
    (Compile.mapped maps "# 1 \"foo/a.c\"\nfoo f(void) { return \"foo\"; }\n# 3 \"food/b.h\""
    = "# 1 \"/zane/pkg/a.c\"\nfoo f(void) { return \"foo\"; }\n# 3 \"food/b.h\"");
  check "a path argument is mapped and a definition is not"
    (List.map (Compile.mapped_arg maps) [ "-Ifoo/inc"; "-I"; "foo/inc"; "-Dfoo=1"; "foo/a.c"; "-ffile-prefix-map=foo=/zane/pkg" ]
    = [ "-I/zane/pkg/inc"; "-I"; "/zane/pkg/inc"; "-Dfoo=1"; "/zane/pkg/a.c"; "-ffile-prefix-map=/zane/pkg=/zane/pkg" ])

(* A package with one C source compiled twice from two directories: the
   bitcode is the same, so the key is, a change to its body changes the key,
   and a source that fails to compile is reported at its line. *)
let compiled () =
  let base = Filename.temp_dir "zane-foreign-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
      let package name text =
        let dir = Filename.concat base name in
        Sys.mkdir dir 0o755;
        write_all (Filename.concat dir "a.c") text;
        dir
      in
      let source = "#include <zane_ffi.h>\nint64_t zane_size(zane_bytes b) { return (int64_t)b.size; }\n" in
      let one = package "one" source and two = package "two" source in
      let cc = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC") in
      let keys dir =
        match Foreign.compile_packages ~cache:None ~cc ~target:None [ dir ] with
        | Ok [ { Foreign.sources = [ s ]; _ } ] -> Some (s.Compile.key, s.Compile.bitcode)
        | _ -> None
      in
      (match (keys one, keys two) with
      | Some (k1, b1), Some (k2, _) ->
          check "a C source compiles to bitcode" (String.length b1 > 4 && String.sub b1 0 2 = "BC");
          check "a source's key does not depend on its directory" (k1 = k2)
      | _ -> check "a C source compiles" false);
      (* The key is made from the preprocessed text, so it holds the body:
         changing only a function's body changes it. *)
      let changed =
        package "changed" "#include <zane_ffi.h>\nint64_t zane_size(zane_bytes b) { return (int64_t)b.size + 1; }\n"
      in
      (match (keys one, keys changed) with
      | Some (k1, _), Some (k2, _) -> check "a source's key changes with its body" (k1 <> k2)
      | _ -> check "a changed C source compiles" false);
      (* A dangling symlink, such as an editor's lock file, is no source,
         and a cache that cannot be written is no cache. *)
      let linked = package "linked" source in
      Unix.symlink "nowhere" (Filename.concat linked ".#a.c");
      let blocked = Filename.concat base "blocked" in
      write_all blocked "a file, not a directory";
      (match Foreign.compile_packages ~cache:(Some (Filename.concat blocked "cache")) ~cc ~target:None [ linked ] with
      | Ok [ { Foreign.sources = [ _ ]; _ } ] -> ()
      | _ -> check "a dangling symlink and an unwritable cache leave the build alone" false);
      Sys.remove (Filename.concat linked ".#a.c");
      let broken = package "broken" "int f(void) {\n  return missing;\n}\n" in
      match Foreign.compile_packages ~cache:None ~cc ~target:None [ broken ] with
      | Error { Foreign.diagnostics = [ d ]; _ } ->
          check "a C error is at its line"
            (match d.Diagnostic.location with
            | Diagnostic.Location.Span s -> s.Source.Span.start_.Lexing.pos_lnum = 2
            | _ -> false)
      | _ -> check "a C error is reported once" false)

(* The table's text read back: names with spaces, nested types, and a
   struct's layout. *)
let interface_text () =
  let module I = Foreign.Interface in
  let text =
    "fun 3:add 1 N 0 2 R s 4:vec3 I s 64 64 4:long 7:int64_t R s 4:vec3 var 1:g 1 1 P 1 V      rec 4:vec3 s 1 1 192 64 1 1:x F 64 1 6:double 0 -1 rec 11:struct file s 1 0"
  in
  let t = I.read text in
  check "a function's type is read"
    (List.assoc_opt "add" t.I.functions
    = Some
        {
          I.ty =
            I.Function
              {
                params =
                  [
                    I.Record { union = false; name = "vec3" };
                    I.Int { signed = true; size = 64; width = 64; name = "long"; standard = Some "int64_t" };
                  ];
                result = I.Record { union = false; name = "vec3" };
                variadic = false;
              };
          external_ = true;
        });
  check "a thread-local variable is read"
    (match List.assoc_opt "g" t.I.variables with Some v -> v.I.thread_local | None -> false);
  check "a struct's layout is read"
    (match List.assoc_opt "vec3" t.I.records with
    | Some { I.layout = Some { size = 192; fields = [ { field = "x"; offset = 0; _ } ]; _ }; _ } -> true
    | _ -> false);
  check "an incomplete struct has no layout"
    (match List.assoc_opt "struct file" t.I.records with Some { I.layout = None; _ } -> true | _ -> false);
  let partial = I.read "rec 11:struct file s 1 0" and complete = I.read "rec 11:struct file s 0 1 64 64 0" in
  check "a struct declared in one header and completed in another is both"
    (match List.assoc_opt "struct file" (I.merge partial complete).I.records with
    | Some { I.declared = true; layout = Some _; _ } -> true
    | _ -> false);
  check "a malformed table is refused" (match I.read "fun 1:f 1 Q" with _ -> false | exception I.Malformed _ -> true);
  check "a name past the end is refused" (match I.read "fun 9:f" with _ -> false | exception I.Malformed _ -> true);
  check "a bad number is refused" (match I.read "rec 1:r s 1 1 x" with _ -> false | exception I.Malformed _ -> true)

(* A header compiled alone: what it declares, by its canonical types and
   the standard names written, and not what only an included header does;
   and `long`, which is 32 bits on Windows. *)
let interface_header () =
  let module I = Foreign.Interface in
  let base = Filename.temp_dir "zane-interface-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
      let dir = Filename.concat base "pkg" in
      Sys.mkdir dir 0o755;
      Sys.mkdir (Filename.concat dir "vendor") 0o755;
      write_all (Filename.concat dir "vendor/inner.h") "int inner(void);\n#define MAKE(n) int n(void);\n";
      write_all (Filename.concat dir "c.coda") "c [\n    setting value target\n    include vendor *\n]\n";
      write_all (Filename.concat dir "api.h")
        "#include <stdint.h>\n\
         #include <inner.h>\n\
         typedef unsigned long uLong;\n\
         struct flags { unsigned a : 3; int64_t b; };\n\
         extern _Thread_local int tls;\n\
         uLong crc(uLong c);\n\
         int64_t sum(const int64_t *xs, struct flags f);\n\
         int logf_(const char *fmt, ...);\n\
         int old();\n\
         int later();\n\
         int later(int x);\n\
         int earlier(int x);\n\
         int earlier();\n\
         long wide(long x);\n\
         typedef struct { int x; } Foo;\n\
         struct Foo { double y; };\n\
         void both(Foo a, struct Foo b);\n\
         MAKE(made)\n";
      let cc = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC") in
      let table target =
        match Foreign.compile_packages ~cache:None ~cc ~target [ dir ] with
        | Ok [ p ] -> Some p.Foreign.interface
        | _ -> None
      in
      match table None with
      | None -> check "an interface header is read" false
      | Some t ->
          let fn name = Option.map (fun (f : I.func) -> f.I.ty) (List.assoc_opt name t.I.functions) in
          check "a typedef is read as what it names"
            (match fn "crc" with Some (I.Function { result = I.Int { name = "unsigned long"; standard = None; _ }; _ }) -> true | _ -> false);
          check "int64_t is known by its standard name"
            (match fn "sum" with
            | Some (I.Function { params = [ I.Pointer { const = true; pointee = I.Int { standard = Some "int64_t"; _ } }; _ ]; _ }) -> true
            | _ -> false);
          check "a variadic function" (match fn "logf_" with Some (I.Function { variadic = true; _ }) -> true | _ -> false);
          check "a function without a prototype" (match fn "old" with Some (I.Unprototyped _) -> true | _ -> false);
          let once name = List.length (List.filter (fun (n, _) -> n = name) t.I.functions) = 1 in
          let prototyped name = match fn name with Some (I.Function { params = [ _ ]; _ }) -> true | _ -> false in
          check "a function declared again is read once, with its prototype in either order"
            (once "later" && prototyped "later" && once "earlier" && prototyped "earlier");
          check "a function a macro of an included header writes is the interface's" (fn "made" <> None);
          check "an included header's own declaration is not" (fn "inner" = None);
          check "a thread-local variable"
            (match List.assoc_opt "tls" t.I.variables with Some v -> v.I.thread_local | None -> false);
          check "a bit-field's width and the next field's offset"
            (match List.assoc_opt "struct flags" t.I.records with
            | Some { I.layout = Some { fields = [ { bit_width = Some 3; _ }; { offset = 64; _ } ]; _ }; _ } -> true
            | _ -> false);
          check "a tag and a typedef of the same name are two structs"
            (fn "both"
             = Some (I.Function { params = [ I.Record { union = false; name = "Foo" }; I.Record { union = false; name = "struct Foo" } ]; result = I.Void; variadic = false })
            && (match (List.assoc_opt "Foo" t.I.records, List.assoc_opt "struct Foo" t.I.records) with
               | Some { I.layout = Some { fields = [ { field = "x"; _ } ]; _ }; _ }, Some { I.layout = Some { fields = [ { field = "y"; _ } ]; _ }; _ } -> true
               | _ -> false));
          let long_size t =
            match List.assoc_opt "wide" t.I.functions with
            | Some { I.ty = I.Function { result = I.Int { size; _ }; _ }; _ } -> size
            | _ -> 0
          in
          check "long is 64 bits on Linux" (long_size t = 64);
          check "long is 32 bits on Windows"
            (match table (Some "x86_64-windows-gnu") with Some w -> long_size w = 32 | None -> false))

let run () =
  patterns ();
  paths ();
  search_lists ();
  probes ();
  triples ();
  mapping ();
  compiled ();
  interface_text ();
  interface_header ()

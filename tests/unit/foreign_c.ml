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
        match Foreign.compile_packages ~cache:None ~cc ~cpu:"" ~target:None [ dir ] with
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
      (* The preprocessed text keeps no column, so a module that reads its
         column is never taken from the cache: moving the builtin along its
         line changes what it compiles to. *)
      let cache = Filename.concat base "cache" in
      let cached dir =
        match Foreign.compile_packages ~cache:(Some cache) ~cc ~cpu:"" ~target:None [ dir ] with
        | Ok [ { Foreign.sources = [ s ]; _ } ] -> Some (s.Compile.bitcode, s.Compile.key)
        | _ -> None
      in
      let near = package "near" "int f(void) { return __builtin_COLUMN(); }\n"
      and far = package "far" "int f(void) { return      __builtin_COLUMN(); }\n" in
      (match (cached near, cached far) with
      | Some (b1, k1), Some (b2, k2) ->
          check "a module reading its column is compiled again when the column moves" (b1 <> b2);
          (* Its key is what it compiled to, so what is kept under keys
             built from it, an unoptimized build's C object, moves too. *)
          check "a module reading its column is keyed by what it compiled to" (k1 <> k2)
      | _ -> check "a module reading its column compiles" false);
      (* Nor does it keep the line of a token inside a macro argument that
         spans lines: both of these preprocess to the same text, so a
         module that reads its line is never taken from the cache either. *)
      let early = package "early" "#define I(x) x\nint f(void) { return I(\n__builtin_LINE()); }\n\n\nint g;\n"
      and late = package "late" "#define I(x) x\nint f(void) { return I(\n\n\n__builtin_LINE()); }\nint g;\n" in
      (match (cached early, cached late) with
      | Some (b1, k1), Some (b2, k2) ->
          check "a module reading its line is compiled again when the line moves" (b1 <> b2);
          check "a module reading its line is keyed by what it compiled to" (k1 <> k2)
      | _ -> check "a module reading its line compiles" false);
      (* A dangling symlink, such as an editor's lock file, is no source,
         and a cache that cannot be written is no cache. *)
      let linked = package "linked" source in
      Unix.symlink "nowhere" (Filename.concat linked ".#a.c");
      let blocked = Filename.concat base "blocked" in
      write_all blocked "a file, not a directory";
      (match Foreign.compile_packages ~cache:(Some (Filename.concat blocked "cache")) ~cc ~cpu:"" ~target:None [ linked ] with
      | Ok [ { Foreign.sources = [ _ ]; _ } ] -> ()
      | _ -> check "a dangling symlink and an unwritable cache leave the build alone" false);
      Sys.remove (Filename.concat linked ".#a.c");
      let broken = package "broken" "int f(void) {\n  return missing;\n}\n" in
      match Foreign.compile_packages ~cache:None ~cc ~cpu:"" ~target:None [ broken ] with
      | Error { Foreign.diagnostics = [ d ]; _ } ->
          check "a C error is at its line"
            (match d.Diagnostic.location with
            | Diagnostic.Location.Span s -> s.Source.Span.start_.Lexing.pos_lnum = 2
            | _ -> false)
      | _ -> check "a C error is reported once" false)

(* The table's text read back: names with spaces, nested types, a
   variable's flags, and a struct's layout. *)
let interface_text () =
  let module I = Foreign.Interface in
  let text =
    "fun 3:add 1 N 0 2 R s 4:vec3 I s 64 64 4:long 7:int64_t R s 4:vec3 2 4:vec3 7:int64_t 4:vec3 var 1:g 1 1 1 P 1 V      rec 4:vec3 s 1 1 192 64 1 1:x F 64 1 6:double 0 -1 rec 11:struct file s 1 0"
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
          spelled = [ "vec3"; "int64_t" ];
          spelled_result = "vec3";
        });
  check "a thread-local variable is read"
    (match List.assoc_opt "g" t.I.variables with Some v -> v.I.thread_local | None -> false);
  check "a `const` variable is read"
    (match List.assoc_opt "g" t.I.variables with Some v -> v.I.constant | None -> false);
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
  let old = I.read "fun 1:f 1 K V 0 4:void"
  and typed = I.read "fun 1:f 1 N 0 1 I s 4 32 3:int 3:int V 1 3:int 4:void" in
  check "a function one header declares without a prototype and another with one has the prototype"
    (match List.assoc_opt "f" (I.merge old typed).I.functions with
    | Some { I.ty = I.Function { params = [ _ ]; _ }; spelled = [ "int" ]; _ } -> true
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
         struct Outer { struct { int x; } a; struct { double y; } b; struct { char c; }; };\n\
         void outer(struct Outer o);\n\
         MAKE(made)\n";
      let cc = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC") in
      let table target =
        match Foreign.compile_packages ~cache:None ~cc ~cpu:"" ~target [ dir ] with
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
          check "a function's types are spelled as the header writes them"
            (match List.assoc_opt "sum" t.I.functions with
            | Some { I.spelled = [ "const int64_t *"; "struct flags" ]; spelled_result = "int64_t"; _ } -> true
            | _ -> false);
          check "a typedef is spelled by its name"
            (match List.assoc_opt "crc" t.I.functions with Some { I.spelled = [ "uLong" ]; _ } -> true | _ -> false);
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
          let field_of name =
            match List.assoc_opt name t.I.records with
            | Some { I.layout = Some { fields = [ { field; _ } ]; _ }; _ } -> field
            | _ -> ""
          in
          check "unnamed records nested in a struct are each their own"
            (field_of "struct Outer.a" = "x" && field_of "struct Outer.b" = "y" && field_of "struct Outer.#2" = "c");
          let long_size t =
            match List.assoc_opt "wide" t.I.functions with
            | Some { I.ty = I.Function { result = I.Int { size; _ }; _ }; _ } -> size
            | _ -> 0
          in
          check "long is 64 bits on Linux" (long_size t = 64);
          check "long is 32 bits on Windows"
            (match table (Some "x86_64-windows-gnu") with Some w -> long_size w = 32 | None -> false))

(* A function an interface header defines is compiled in the glue, and
   one holding assembly, or a global the header places in a linker set, is
   refused there, naming the header. *)
let glue_refusals () =
  let refused name text =
    let base = Filename.temp_dir "zane-glue-" "" in
    Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
        let dir = Filename.concat base "pkg" in
        Sys.mkdir dir 0o755;
        let header = Filename.concat dir "api.h" in
        write_all header text;
        let cc = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC") in
        match Foreign.compile_packages ~cache:None ~cc ~cpu:"" ~target:None [ dir ] with
        | Ok [ p ] -> (
            let entry =
              { Foreign.Glue.label = "pkg.fenced.ffi"; c_function = "fenced"; params = []; result = Foreign.Glue.Scalar "int32_t" }
            in
            match Foreign.glue p [ entry ] with
            | Error { Foreign.diagnostics = { Diagnostic.location = Diagnostic.Location.File f; _ } :: _; _ } ->
                check name (f = header)
            | _ -> check name false)
        | _ -> check (name ^ ": the header is read") false)
  in
  refused "a header's function holding assembly is refused in its glue, naming the header"
    "int fenced(void) { __asm__ volatile(\"\" ::: \"memory\"); return 1; }\n";
  refused "a header's global in a linker set is refused in its glue, naming the header"
    "__attribute__((used, section(\"plugins\"))) static const int entry = 1;\n\
     extern const int __start_plugins, __stop_plugins;\n\
     int fenced(void) { return &__stop_plugins - &__start_plugins; }\n"

(* A package whose directory's name holds a byte past ASCII still compiles
   its glue: the glue includes the header by its path as it is spelled,
   which a quoted header name reads without escapes. *)
let glue_paths () =
  let base = Filename.temp_dir "zane-glue-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
      let dir = Filename.concat base "p\xc3\xa4ckage" in
      Sys.mkdir dir 0o755;
      write_all (Filename.concat dir "api.h") "static inline int fenced(void) { return 1; }\n";
      let cc = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC") in
      let entry =
        { Foreign.Glue.label = "pkg.fenced.ffi"; c_function = "fenced"; params = []; result = Foreign.Glue.Scalar "int32_t" }
      in
      check "a header under a directory named past ASCII is included by its glue"
        (match Foreign.compile_packages ~cache:None ~cc ~cpu:"" ~target:None [ dir ] with
        | Ok [ p ] -> ( match Foreign.glue p [ entry ] with Ok [ _ ] -> true | _ -> false)
        | _ -> false))

(* A function one interface header declares without a prototype and a
   later one with it has its thunk in the later header's glue, where the
   prototype is in scope. *)
let glue_prototypes () =
  let base = Filename.temp_dir "zane-glue-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
      let dir = Filename.concat base "pkg" in
      Sys.mkdir dir 0o755;
      write_all (Filename.concat dir "a.h") "int twice();\n";
      write_all (Filename.concat dir "b.h") "int twice(int);\n";
      let cc = Option.value ~default:"clang" (Sys.getenv_opt "ZANE_CC") in
      let entry =
        {
          Foreign.Glue.label = "pkg.twice.ffi";
          c_function = "twice";
          params = [ Foreign.Glue.Scalar "int32_t" ];
          result = Foreign.Glue.Scalar "int32_t";
        }
      in
      check "a function prototyped by a later header has its thunk in that header's glue"
        (match Foreign.compile_packages ~cache:None ~cc ~cpu:"" ~target:None [ dir ] with
        | Ok [ p ] -> ( match Foreign.glue p [ entry ] with Ok [ _ ] -> true | _ -> false)
        | _ -> false))

(* A global an `__asm__` label names, as LLVM writes one for Mach-O, with
   a leading \1 and the target's `_` spelled out, read as the label an
   object's reader names it by: a header's definitions and private state
   name it so, and the glue's copy of one an object assembled apart
   defines is made a declaration. A Mach-O link is the only one that spells the prefix out,
   and no test links one. *)
let asm_labels () =
  let ctx = Llvm.create_context () in
  let ir =
    "target datalayout = \"e-m:o-i64:64-i128:128-n32:64-S128-Fn32\"\n\
     target triple = \"arm64-apple-macosx\"\n\
     @\"\\01_counter_label\" = global i64 1\n\
     @plain = global i64 2\n"
  in
  let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string ir) in
  let bitcode = Llvm.MemoryBuffer.as_string (Llvm_bitwriter.write_bitcode_to_memory_buffer m) in
  check "a header's labelled definition is named by its label"
    (List.sort compare (fst (Clang.definitions bitcode)) = [ "counter_label"; "plain" ]);
  Codegen__Foreign_c.drop_defined_apart m "_" [ "counter_label" ];
  let declared name = match Llvm.lookup_global name m with Some g -> Llvm.is_declaration g | None -> false in
  check "the glue's copy of a labelled definition an object defines is a declaration" (declared "\001_counter_label");
  check "a definition no object defines stays" (not (declared "plain"));
  let state =
    "target datalayout = \"e-m:o-i64:64-i128:128-n32:64-S128-Fn32\"\n\
     target triple = \"arm64-apple-macosx\"\n\
     @\"\\01_private_count\" = internal global i64 0\n\
     @\"\\01_private_limit\" = internal constant i64 1\n\
     define i64 @read() {\n  %v = load i64, ptr @\"\\01_private_count\"\n  %w = load i64, ptr @\"\\01_private_limit\"\n  %s = add i64 %v, %w\n  ret i64 %s\n}\n"
  in
  let sm = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string state) in
  let state_bitcode = Llvm.MemoryBuffer.as_string (Llvm_bitwriter.write_bitcode_to_memory_buffer sm) in
  Llvm.dispose_module sm;
  check "labelled private state is named by its label, as an archive's local symbol is"
    (Clang.private_state state_bitcode = [ "private_count" ]);
  check "a labelled private constant is named by its label"
    (Clang.private_identities state_bitcode = [ "private_limit" ]);
  Llvm.dispose_module m;
  Llvm.dispose_context ctx

(* A header's constructor with external linkage that a source assembled
   apart defines too: the glue's copy is a declaration, and its entry is
   left out of the glue's list, since the object runs its own. A local
   one stays. *)
let apart_constructors () =
  let ctx = Llvm.create_context () in
  let ir =
    "@runs = global i64 0\n\
     define void @start() {\n  ret void\n}\n\
     define internal void @local_start() {\n  ret void\n}\n\
     @llvm.global_ctors = appending global [2 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @start, ptr null }, { i32, ptr, ptr } { i32 65535, ptr @local_start, ptr null }]\n"
  in
  let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string ir) in
  Codegen__Foreign_c.drop_defined_apart m "" [ "start"; "runs" ];
  let entries =
    match Llvm.lookup_global "llvm.global_ctors" m with
    | Some list -> Llvm.num_operands (Llvm.global_initializer list |> Option.get)
    | None -> 0
  in
  check "the glue's copy of an external constructor an object defines is a declaration"
    (match Llvm.lookup_function "start" m with Some f -> Llvm.is_declaration f | None -> false);
  check "the glue no longer runs an external constructor an object defines" (entries = 1);
  Llvm.dispose_module m;
  Llvm.dispose_context ctx

(* The symbols a COFF `.drectve` section's directives name, which an
   archive member or assembled object may not name of its own. *)
let directives () =
  let names = Foreign.Objects.directive_names in
  check "an export names its symbol" (names " /EXPORT:foo" = [ "foo" ]);
  check "an export's data flag and quotes are not part of the name" (names "-export:\"bar\",DATA" = [ "bar" ]);
  check "an export under another name names both" (names "/EXPORT:out=inner" = [ "out"; "inner" ]);
  check "an include and an alternate name are read" (names "/include:a -ALTERNATENAME:b=c" = [ "a"; "b"; "c" ]);
  check "a directive naming no symbol is skipped" (names "/DEFAULTLIB:msvcrt -merge:.a=.b" = [])

(* A Mach-O indirect symbol, the alias `_alias = _foo` defines, renamed
   with its target: the target is named by a string-table offset in the
   symbol's value, which the rewriter renames as it does a symbol's name. *)
let indirect_alias () =
  let ctx = Llvm.create_context () in
  let ir =
    "target triple = \"arm64-apple-macosx\"\n\
     module asm \".globl _alias\"\n\
     module asm \"_alias = _foo\"\n"
  in
  let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string ir) in
  let bitcode = Llvm.MemoryBuffer.as_string (Llvm_bitwriter.write_bitcode_to_memory_buffer m) in
  Llvm.dispose_module m;
  Llvm.dispose_context ctx;
  match Foreign.Objects.emit ~triple:"arm64-apple-macosx" ~cpu:"generic" ~key:"indirect" bitcode with
  | Error why -> check ("a Mach-O alias is assembled: " ^ why) false
  | Ok object_ -> (
      let renamed = function "_foo" -> Some "_p$foo" | "_alias" -> Some "_p$alias" | _ -> None in
      match Rewrite.rename ~rename:renamed object_ with
      | Error why -> check ("a Mach-O alias is renamed: " ^ why) false
      | Ok (bytes, count) ->
          let seen = ref [] in
          ignore
            (Rewrite.rename
               ~rename:(fun n ->
                 seen := n :: !seen;
                 None)
               bytes);
          let times n = List.length (List.filter (( = ) n) !seen) in
          check "both symbols of an alias are renamed" (count = 2);
          check "an alias's target is renamed with the symbol it names" (times "_p$foo" = 2 && times "_foo" = 0))

(* A dependency's C module made a retained copy (docs/design/ffi.md F13,
   retain_stubs.cpp): bodies that read only constants are
   `available_externally`, and one that reaches local state, a local
   constant in a section, or lets out a local constant's or function's
   address is a declaration, as is a caller of a local function that does;
   the lists of constructors and `used` objects and the file-scope
   assembly go, and what nothing reaches any more is removed. *)
let retained () =
  let ctx = Llvm.create_context () in
  let ir =
    "target triple = \"x86_64-unknown-linux-gnu\"\n\
     module asm \"nop\"\n\
     @state = internal global i64 0\n\
     @limit = internal constant i64 3\n\
     @table = internal constant [2 x i64] [i64 1, i64 2]\n\
     @token = internal constant i64 5\n\
     @placed = internal constant i64 7, section \"zt\"\n\
     @shared = global i64 0\n\
     @fixed = constant i64 4\n\
     @holds = constant ptr @token\n\
     @.str = private unnamed_addr constant [2 x i8] c\"x\\00\"\n\
     @llvm.used = appending global [1 x ptr] [ptr @limit], section \"llvm.metadata\"\n\
     @llvm.global_ctors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @init, ptr null }]\n\
     @alias = alias i64 (i64), ptr @pure\n\
     declare void @puts(ptr)\n\
     define i64 @pure(i64 %a) {\n  ret i64 %a\n}\n\
     define i64 @counts() {\n  %v = load i64, ptr @state\n  ret i64 %v\n}\n\
     define i64 @reads(i64 %i) {\n  %l = load i64, ptr @limit\n  %p = getelementptr [2 x i64], ptr @table, i64 0, i64 %i\n  %t = load i64, ptr %p\n  %s = add i64 %l, %t\n  ret i64 %s\n}\n\
     define ptr @leaks() {\n  ret ptr @token\n}\n\
     define i64 @reads_placed() {\n  %v = load i64, ptr @placed\n  ret i64 %v\n}\n\
     define internal i64 @helper() {\n  %v = load i64, ptr @state\n  ret i64 %v\n}\n\
     define i64 @calls_helper() {\n  %v = call i64 @helper()\n  ret i64 %v\n}\n\
     define internal i64 @quiet() {\n  ret i64 1\n}\n\
     define i64 @calls_quiet() {\n  %v = call i64 @quiet()\n  ret i64 %v\n}\n\
     define internal void @callback() {\n  ret void\n}\n\
     define ptr @hands_out() {\n  ret ptr @callback\n}\n\
     define void @says() {\n  call void @puts(ptr @.str)\n  ret void\n}\n\
     define weak i64 @replaceable() {\n  ret i64 2\n}\n\
     define void @init() {\n  store i64 1, ptr @shared\n  ret void\n}\n\
     @targets = private unnamed_addr constant [2 x ptr] [ptr blockaddress(@jumps, %one), ptr blockaddress(@jumps, %two)]\n\
     @exported_targets = constant [1 x ptr] [ptr blockaddress(@jumps, %one)]\n\
     define i64 @jumps(i64 %i) {\n  %p = getelementptr [2 x ptr], ptr @targets, i64 0, i64 %i\n  %t = load ptr, ptr %p\n  indirectbr ptr %t, [label %one, label %two]\none:\n  ret i64 1\ntwo:\n  ret i64 2\n}\n"
  in
  let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string ir) in
  check "a module with nothing local left unreached is retained" (Codegen__Foreign_c.retain m);
  let linkage name =
    match Llvm.lookup_function name m with
    | Some f when Llvm.is_declaration f -> Some `Declared
    | Some f when Llvm.linkage f = Llvm.Linkage.Available_externally -> Some `Retained
    | Some _ -> Some `Defined
    | None -> (
        match Llvm.lookup_global name m with
        | Some g when Llvm.is_declaration g -> Some `Declared
        | Some g when Llvm.linkage g = Llvm.Linkage.Available_externally -> Some `Retained
        | Some _ -> Some `Defined
        | None -> None)
  in
  let is name l = linkage name = Some l in
  check "a function reading only its arguments is retained" (is "pure" `Retained);
  check "one reading local constants is retained" (is "reads" `Retained);
  check "one passing a string literal on is retained" (is "says" `Retained);
  check "one calling a local function that is safe is retained" (is "calls_quiet" `Retained);
  check "the local function it calls is copied" (is "quiet" `Defined);
  check "a constructor is retained, its list gone" (is "init" `Retained && linkage "llvm.global_ctors" = None);
  check "the `used` list is gone" (linkage "llvm.used" = None);
  check "the file-scope assembly is gone"
    (let text = Llvm.string_of_llmodule m in
     not (List.exists (fun l -> String.starts_with ~prefix:"module asm" l) (String.split_on_char '\n' text)));
  check "one reaching local state is called" (is "counts" `Declared);
  check "one letting a local constant's address out is called" (is "leaks" `Declared);
  check "one reading a local constant in a section is called" (is "reads_placed" `Declared);
  check "one letting a local function's address out is called" (is "hands_out" `Declared);
  check "a caller of a local function reaching state is called" (is "calls_helper" `Declared);
  check "that local function and its state are removed" (linkage "helper" = None && linkage "state" = None);
  check "a weak definition is called" (is "replaceable" `Declared);
  check "an alias is a declaration" (is "alias" `Declared);
  check "a variable is a declaration" (is "shared" `Declared);
  check "a constant is retained" (is "fixed" `Retained);
  check "a constant holding a local address is a declaration" (is "holds" `Declared);
  check "a function whose labels' addresses are taken is called" (is "jumps" `Declared);
  check "a constant holding a label's address is a declaration" (is "exported_targets" `Declared);
  (match Llvm_analysis.verify_module m with
  | None -> ()
  | Some why -> check ("the retained module verifies: " ^ why) false);
  Llvm.dispose_module m;
  Llvm.dispose_context ctx

(* The file of C module hashes beside a package's object
   (docs/design/ffi.md F15) reads back as written, and fetching's rewrite
   stamps its packages, never their labels. *)
let hashes () =
  let module H = Foreign.Hashes in
  let rows =
    [
      { H.package = "!lib"; labels = "!lib"; kind = H.Source; file = "a \"b\".c"; hash = "00ff" };
      { H.package = "!lib"; labels = "!lib"; kind = H.Glue; file = "lib.h"; hash = "11ee" };
    ]
  in
  let text = H.write rows in
  check "the file is told from an object" (H.is text && not (H.is "\127ELF"));
  check "the file reads back as written" (H.read text = Ok rows);
  match H.rewrite ~stamp:"v1%0123456789abcdef%" text with
  | Error why -> check ("the file is rewritten: " ^ why) false
  | Ok (stamped, n) ->
      check "each row is stamped" (n = 2);
      check "the stamp names the package, and the labels keep the placeholder"
        (match H.read stamped with
        | Ok rs -> List.for_all (fun (r : H.row) -> r.H.package = "v1%0123456789abcdef%lib" && r.H.labels = "!lib") rs
        | Error _ -> false)

(* The rows an object's packages give its file of C module hashes are each
   package's own, though one package's name ends another's. *)
let own_hashes () =
  let package id =
    ( { Tst.Assembly.id; name = id; dir = "."; is_root = false; files = []; imports = []; keyed = true },
      {
        Foreign.dir = ".";
        rows = [];
        headers = [];
        interface = C_interface.empty;
        sources = [];
        assembled = [];
        archives = [];
        tables = [];
        flags = [];
        maps = [];
        cache = None;
      },
      {
        Codegen.prefix = "!" ^ id ^ "$%c$";
        sources = [];
        glue = [ { Codegen.key = id ^ "-glue"; bitcode = ""; files = [ id ^ ".h" ] } ];
        thunks = [];
        objects = [];
        archives = [];
        defined = [];
        libraries = [];
        labels = None;
      } )
  in
  let ps = [ package "lib"; package "olib" ] in
  let rows =
    Driver.hashes_of
      (List.map (fun (a, _, _) -> a) ps)
      (List.map (fun (_, f, _) -> f) ps)
      (List.map (fun (_, _, k) -> k) ps)
  in
  check "each package's hashes are its own glue's"
    (List.map (fun (r : Foreign.Hashes.row) -> (r.Foreign.Hashes.package, r.Foreign.Hashes.hash)) rows
    = [ ("!lib", "lib-glue"); ("!olib", "olib-glue") ])

(* A glue file's thunks come in the order of their labels, whatever order
   the calls reaching them came in, so a release's consumer writes the
   publisher's glue (docs/design/ffi.md F13). *)
let glue_order () =
  let table =
    {
      C_interface.empty with
      functions =
        [
          ( "f",
            {
              C_interface.ty = C_interface.Function { params = []; result = C_interface.Void; variadic = false };
              external_ = true;
              spelled = [];
              spelled_result = "void";
            } );
        ];
    }
  in
  let entry label = { Foreign.Glue.label; c_function = "f"; params = []; result = Foreign.Glue.Unit } in
  let text order = List.map snd (Foreign.Glue.files [ ("h.h", table) ] (List.map entry order)) in
  check "a glue file does not depend on the order its thunks are reached" (text [ "b"; "a" ] = text [ "a"; "b" ])

let run () =
  patterns ();
  paths ();
  search_lists ();
  probes ();
  triples ();
  mapping ();
  compiled ();
  interface_text ();
  interface_header ();
  glue_refusals ();
  glue_paths ();
  glue_prototypes ();
  asm_labels ();
  apart_constructors ();
  directives ();
  indirect_alias ();
  retained ();
  hashes ();
  own_hashes ();
  glue_order ()

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

let triples () =
  check "a missing vendor is the same ABI" (Clang.same_abi "x86_64-linux-gnu" "x86_64-pc-linux-gnu");
  check "another environment is another ABI" (not (Clang.same_abi "x86_64-linux-gnu" "x86_64-linux-musl"));
  check "another architecture is another ABI" (not (Clang.same_abi "x86_64-linux-gnu" "aarch64-linux-gnu"))

let mapping () =
  let maps = [ ("/home/a/zlib", "/zane/pkg"); ("/home/a/zlib/x", "/zane/other") ] in
  check "the longest directory is mapped first"
    (Compile.mapped maps "# 1 \"/home/a/zlib/x/y.h\"\n# 2 \"/home/a/zlib/z.h\""
    = "# 1 \"/zane/other/y.h\"\n# 2 \"/zane/pkg/z.h\"")

(* A package with one C source compiled twice from two directories: the
   bitcode is the same, so the key is, and a source that fails to compile
   is reported at its line. *)
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
      let broken = package "broken" "int f(void) {\n  return missing;\n}\n" in
      match Foreign.compile_packages ~cache:None ~cc ~target:None [ broken ] with
      | Error { Foreign.diagnostics = [ d ]; _ } ->
          check "a C error is at its line"
            (match d.Diagnostic.location with
            | Diagnostic.Location.Span s -> s.Source.Span.start_.Lexing.pos_lnum = 2
            | _ -> false)
      | _ -> check "a C error is reported once" false)

let run () =
  patterns ();
  paths ();
  search_lists ();
  triples ();
  mapping ();
  compiled ()

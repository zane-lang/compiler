(* The dune rules of tests/codegen/, tests/ffi/, tests/parser/,
   tests/runtime/ and tests/semantics/, written
   from what those directories hold. Each directory's `dune` includes the
   `dune.inc` this prints, and diffs it against a fresh run, so a fixture
   added without its rules fails `dune runtest` until `dune promote` writes
   them.

   Every fixture must have a golden file, and every golden file a fixture:
   it stops, naming the file, at one without the other (fixture_pairing.ml),
   so no fixture goes untested and no golden file outlives its fixture.

   It runs in the directory it writes rules for, and the golden files decide
   which rules there are:

   - codegen: `golden/NAME.cgt` prints fixture NAME's code-generation tree,
     `golden/NAME.optimized.cgt` the tree an optimized build makes of it,
     and `golden/NAME.out` builds it, unoptimized, optimized and tiered
     (tier 0 with tier 1 loaded before `main`), runs each build with its
     drains checked (`ZANE_CHECK` 1) and unchecked (0), and holds what all
     six runs of the program wrote. A
     fixture whose `expected-status` file holds a status other than 0 is a
     program that stops: its golden file holds stdout and stderr together.
     A fixture's `arguments` file, one argument per line, is what both
     builds are run with, and its `flags` file, one per line, what both
     are built with besides.
     `golden/reject.NAME.err` is what lowering reports for the package
     `fixtures/reject/NAME`, a program semantics accepts and lowering refuses.
   - ffi: `golden/NAME.check` is what `zanec --check` prints, both
     streams, for the build `fixtures/NAME`, which it accepts,
     `golden/NAME.tst` its typed tree, `golden/NAME.cgt`,
     `golden/NAME.optimized.cgt` and `golden/NAME.out` what they are in
     codegen, `golden/NAME.optimized.out`, when there is one, what the
     optimized build's runs print in place of `golden/NAME.out`, for a
     program whose optimized build may print otherwise (spec ffi.md §5.5),
     and `golden/reject.NAME.err` what it reports for
     `fixtures/reject/NAME`, or, when that fixture holds a file named
     `build`, what `zanec --build` reports for it, or
     `golden/reject.NAME.ll.err` what `zanec --ll` reports for one only
     codegen refuses, `golden/NAME.released.out` what the fixture's
     root prints linked against releases of its other packages, which
     `released` builds, and `golden/NAME.released.calls` what of those
     packages the optimized build still calls, having inlined the rest
     of what it retained of their C. A fixture holding `.zn` files is one package; any
     other is a build of its subdirectories, in name order, so the first
     is the root. Its `flags` file, one per line, is what it is built with
     besides. A directory `NAME.archive` anywhere in a fixture holds the C
     sources of the static library `NAME.a` beside it, which `archive`
     builds for the fixture's rules.
   - parser: `golden/NAME.STAGE.spans` is `span_dump --STAGE`, and
     `golden/NAME.STAGE.tree` `zanec --STAGE`, over `fixtures/NAME.zn`;
     `golden/reject.NAME.err` is what `zanec` reports for
     `fixtures/reject/NAME.zn`.
   - runtime: `NAME.c` is a C test, linked with the runtime's parts, and
     `golden/NAME.out` is what it printed.
   - semantics: `golden/typing.NAME.VIEW` is a build of every package
     directory in `fixtures/typing/NAME`, in name order, so the first is the
     root: `--decls` for `decls`, `--tst` for `tst`, `span_dump --tst` for
     `tst.spans`, and what `--check` reports for `err`. The `assembly.*` and
     `project.*` cases each set up their build differently, and their rules
     are written by hand. *)

let zanec = "%{exe:../../bin/zanec/zanec.exe}"
let span_dump = "%{exe:../../tools/inspect/span_dump.exe}"

let sorted dir =
  if Sys.file_exists dir then List.sort compare (Array.to_list (Sys.readdir dir)) else []

let chop_suffix ~suffix name =
  if Filename.check_suffix name suffix then Some (Filename.chop_suffix name suffix) else None

let diff golden actual =
  Printf.printf "(rule\n (alias runtest)\n (action\n  (diff golden/%s %s)))\n\n" golden actual

(* Every directory named `NAME.archive` under [dir], each the sources of
   the static library `NAME.a` beside it. *)
let rec archive_dirs dir =
  List.concat_map
    (fun e ->
      let path = Filename.concat dir e in
      if not (Sys.is_directory path) then []
      else if Filename.check_suffix e ".archive" then [ path ]
      else archive_dirs path)
    (sorted dir)

(* What a rule over the fixture [dir] depends on: its files, and the
   static libraries built from it. *)
let fixture_deps dir =
  String.concat " "
    (Printf.sprintf "(source_tree %s)" dir
    :: List.map (fun d -> Filename.chop_suffix d ".archive" ^ ".a") (archive_dirs dir))

(* codegen *)

let status name =
  let file = Filename.concat (Filename.concat "fixtures" name) "expected-status" in
  if Sys.file_exists file then
    int_of_string (String.trim (In_channel.with_open_text file In_channel.input_all))
  else 0

(* What a fixture's program is run with, its `arguments` file, or built
   with, its `flags` file: one per line, each quoted for dune. *)
let lines file name =
  let file = Filename.concat (Filename.concat "fixtures" name) file in
  if Sys.file_exists file then
    In_channel.with_open_text file In_channel.input_lines
    |> List.map (fun a -> " " ^ Printf.sprintf "%S" a)
    |> String.concat ""
  else ""

let arguments = lines "arguments"
let flags = lines "flags"

(* The rules of the program fixture NAME, built from [packages], its
   `--package` arguments: its trees when [goldens] holds `NAME.cgt` or
   `NAME.optimized.cgt`, and its runs when it holds `NAME.out`. *)
let program_rules ~goldens ~packages name =
  let package = "fixtures/" ^ name in
  let deps = fixture_deps package in
  let has suffix = List.mem (name ^ suffix) goldens in
  begin
      if has ".cgt" then begin
        Printf.printf
          "(rule\n (deps %s)\n (action\n  (with-stdout-to\n   %s.cgt.actual\n   (run %s --cgt%s))))\n\n"
          deps name zanec packages;
        diff (name ^ ".cgt") (name ^ ".cgt.actual")
      end;
      if has ".optimized.cgt" then begin
        Printf.printf
          "(rule\n (deps %s)\n (action\n  (with-stdout-to\n   %s.optimized.cgt.actual\n   (run %s --cgt --optimize%s))))\n\n"
          deps name zanec packages;
        diff (name ^ ".optimized.cgt") (name ^ ".optimized.cgt.actual")
      end;
      if has ".out" then begin
        Printf.printf
          "(rule\n (deps %s)\n (targets %s.exe)\n (action\n  (run %s --build %s.exe%s%s)))\n\n"
          deps name zanec name (flags name) packages;
        Printf.printf
          "(rule\n (deps %s)\n (targets %s.optimized.exe)\n (action\n  (run %s --build %s.optimized.exe --optimize%s%s)))\n\n"
          deps name zanec name (flags name) packages;
        Printf.printf
          "(rule\n (deps %s)\n (targets %s.tiered.exe)\n (action\n  (run %s --build %s.tiered.exe --tiered%s%s)))\n\n"
          deps name zanec name (flags name) packages;
        Printf.printf
          "(rule\n (deps %s)\n (targets %s.tier1)\n (action\n  (run %s --tier-up %s.tier1%s%s)))\n\n"
          deps name zanec name (flags name) packages;
        (* The optimized build is held to the same golden file: optimizing
           never changes what a program does, but for an ffi fixture with
           `golden/NAME.optimized.out`, whose C keeps state a folded call
           reads at compile time (spec ffi.md §5.5). So is the tiered build, run
           with tier 1 in place of every function before `main` starts
           (docs/design/tiers.md), so all of the program but `main` itself
           runs optimized code; the runtime stops it when tier 1 does not
           load. So is each build run with its drains checked and
           unchecked, which takes the drain lowering makes in line
           (`Emit.drain_scope`): checking never changes it either. *)
        List.iter
          (fun exe ->
            List.iter
              (fun (mode, check) ->
                let actual = Printf.sprintf "%s.%s.out.actual" exe mode in
                let tiered = exe = name ^ ".tiered" in
                let deps = if tiered then Printf.sprintf " (deps %s.tier1)\n" name else "" in
                let env inner =
                  if tiered then
                    Printf.sprintf
                      "(setenv\n   ZANE_TIER_UP\n   ./%s.tier1\n   (setenv\n    ZANE_TIER_WAIT\n    1\n    %s))" name inner
                  else inner
                in
                (* An optimized build that may print otherwise is held to
                   its own golden file (spec ffi.md §5.5). *)
                let golden =
                  if exe = name ^ ".optimized" && has ".optimized.out" then name ^ ".optimized.out" else name ^ ".out"
                in
                (match status name with
                | 0 ->
                    Printf.printf "(rule\n%s (action\n  %s))\n\n" deps
                      (env
                         (Printf.sprintf "(setenv\n   ZANE_CHECK\n   %s\n   (with-stdout-to\n    %s\n    (run ./%s.exe%s)))"
                            check actual exe (arguments name)))
                | n ->
                    Printf.printf "(rule\n%s (action\n  %s))\n\n" deps
                      (env
                         (Printf.sprintf
                            "(setenv\n   ZANE_CHECK\n   %s\n   (with-outputs-to\n    %s\n    (with-accepted-exit-codes\n     %d\n     (run ./%s.exe%s))))"
                            check actual n exe (arguments name))));
                diff golden actual)
              [ ("checked", "1"); ("unchecked", "0") ])
          [ name; name ^ ".optimized"; name ^ ".tiered" ]
      end
  end

let codegen () =
  let goldens = sorted "golden" in
  let names suffix = List.filter_map (chop_suffix ~suffix) goldens in
  let optimized = names ".optimized.cgt" in
  let trees = List.filter (fun n -> not (Filename.check_suffix n ".optimized")) (names ".cgt") in
  let outputs = names ".out" in
  List.iter
    (fun name -> program_rules ~goldens ~packages:(" --package fixtures/" ^ name) name)
    (List.sort_uniq compare (trees @ optimized @ outputs));
  List.iter
    (fun golden ->
      match String.split_on_char '.' golden with
      | [ "reject"; name; "err" ] ->
          let package = "fixtures/reject/" ^ name in
          Printf.printf
            "(rule\n (deps %s)\n (action\n  (with-stderr-to\n   %s.actual\n   (with-accepted-exit-codes\n    1\n    (run %s --cgt --package %s)))))\n\n"
            (fixture_deps package) golden zanec package;
          diff golden (golden ^ ".actual")
      | _ -> ())
    goldens

(* ffi *)

(* The `--package` arguments of the build [dir] holds: itself, when it
   holds sources, else each subdirectory in name order. *)
let packages dir =
  if List.exists (fun f -> Filename.check_suffix f ".zn") (sorted dir) then " --package " ^ dir
  else
    List.filter (fun p -> Sys.is_directory (Filename.concat dir p)) (sorted dir)
    |> List.map (fun p -> Printf.sprintf " --package %s/%s" dir p)
    |> String.concat ""

(* A fixture's `flags` file, one per line, as arguments quoted for dune. *)
let flags_of dir =
  let file = Filename.concat dir "flags" in
  if Sys.file_exists file then
    In_channel.with_open_text file In_channel.input_lines |> List.map (Printf.sprintf " %S") |> String.concat ""
  else ""

(* The rule that builds the static library of each `NAME.archive` in a
   fixture, with the C compiler and archiver the build is given. *)
let archive_rules () =
  List.iter
    (fun dir ->
      let parent = Filename.dirname dir and base = Filename.basename dir in
      let up = String.concat "/" (List.map (fun _ -> "..") (String.split_on_char '/' parent)) in
      Printf.printf
        "(subdir\n %s\n (rule\n  (targets %s.a)\n  (deps (glob_files %s/*) (env_var ZANE_CC) (env_var AR) (env_var STRIP))\n  (action\n   (run sh %%{dep:%s/archive} %s.a %s))))\n\n"
        parent (Filename.chop_suffix base ".archive") base up (Filename.chop_suffix base ".archive") base)
    (archive_dirs "fixtures")

let ffi () =
  archive_rules ();
  let goldens = sorted "golden" in
  let program = function
    | [ name; "cgt" ] | [ name; "optimized"; ("cgt" | "out") ] | [ name; "out" ] -> Some name
    | _ -> None
  in
  List.iter
    (fun name -> program_rules ~goldens ~packages:(packages ("fixtures/" ^ name)) name)
    (List.sort_uniq compare (List.filter_map (fun g -> program (String.split_on_char '.' g)) goldens));
  List.iter
    (fun golden ->
      let build ~dir view =
        Printf.sprintf "(run %s --%s%s%s)" zanec view (flags_of dir) (packages dir)
      in
      match String.split_on_char '.' golden with
      | [ name; ("check" | "tst") as view ] ->
          let dir = "fixtures/" ^ name in
          let stream = if view = "check" then "with-outputs-to" else "with-stdout-to" in
          Printf.printf "(rule\n (deps %s)\n (action\n  (%s\n   %s.actual\n   %s)))\n\n" (fixture_deps dir) stream
            golden (build ~dir view);
          diff golden (golden ^ ".actual")
      | [ "reject"; name; "err" ] ->
          let dir = "fixtures/reject/" ^ name in
          (* A fixture refused only when it is built is built, to a program
             its refusal never writes. *)
          let view = if Sys.file_exists (Filename.concat dir "build") then Printf.sprintf "build reject.%s.exe" name else "check" in
          Printf.printf
            "(rule\n (deps %s)\n (action\n  (with-stderr-to\n   %s.actual\n   (with-accepted-exit-codes\n    1\n    %s))))\n\n"
            (fixture_deps dir) golden (build ~dir view);
          diff golden (golden ^ ".actual")
      | [ name; "released"; ("out" | "calls" as what) ] ->
          let dir = "fixtures/" ^ name in
          let mode = if what = "calls" then " --calls" else "" in
          Printf.printf
            "(rule\n (deps %s)\n (action\n  (with-stdout-to\n   %s.actual\n   (run sh %%{dep:released}%s %s %s))))\n\n"
            (fixture_deps dir) golden mode zanec dir;
          diff golden (golden ^ ".actual")
      | [ "reject"; name; "ll"; "err" ] ->
          let dir = "fixtures/reject/" ^ name in
          Printf.printf
            "(rule\n (deps %s)\n (action\n  (with-stderr-to\n   %s.actual\n   (with-accepted-exit-codes\n    1\n    %s))))\n\n"
            (fixture_deps dir) golden (build ~dir "ll");
          diff golden (golden ^ ".actual")
      | parts when program parts <> None -> ()
      | _ -> failwith ("gen_rules: no rule makes golden/" ^ golden))
    goldens

(* parser *)

let parser () =
  List.iter
    (fun golden ->
      match String.split_on_char '.' golden with
      | [ name; stage; ("spans" | "tree") as kind ] ->
          let tool = if kind = "spans" then span_dump else zanec in
          Printf.printf
            "(rule\n (with-stdout-to\n  %s.actual\n  (run %s --%s %%{dep:fixtures/%s.zn})))\n\n" golden
            tool stage name;
          diff golden (golden ^ ".actual")
      | [ "reject"; name; "err" ] ->
          Printf.printf
            "(rule\n (with-stderr-to\n  %s.actual\n  (with-accepted-exit-codes\n   1\n   (run %s %%{dep:fixtures/reject/%s.zn}))))\n\n"
            golden zanec name;
          diff golden (golden ^ ".actual")
      | _ -> failwith ("gen_rules: no rule makes golden/" ^ golden))
    (sorted "golden")

(* semantics *)

let semantics () =
  List.iter
    (fun golden ->
      let rule name tool view ~err =
        let dir = "fixtures/typing/" ^ name in
        let packages =
          List.filter (fun p -> Sys.is_directory (Filename.concat dir p)) (sorted dir)
          |> List.map (fun p -> Printf.sprintf " --package %s/%s" dir p)
          |> String.concat ""
        in
        let run = Printf.sprintf "(run %s --%s%s)" tool view packages in
        if err then
          Printf.printf
            "(rule\n (deps %s)\n (action\n  (with-stderr-to\n   %s.actual\n   (with-accepted-exit-codes\n    1\n    %s))))\n\n"
            (fixture_deps dir) golden run
        else
          Printf.printf
            "(rule\n (deps %s)\n (action\n  (with-stdout-to\n   %s.actual\n   %s)))\n\n"
            (fixture_deps dir) golden run;
        diff golden (golden ^ ".actual")
      in
      match String.split_on_char '.' golden with
      | [ "typing"; name; "decls" ] -> rule name zanec "decls" ~err:false
      | [ "typing"; name; "tst" ] -> rule name zanec "tst" ~err:false
      | [ "typing"; name; "tst"; "spans" ] -> rule name span_dump "tst" ~err:false
      | [ "typing"; name; "err" ] -> rule name zanec "check" ~err:true
      | _ -> ())
    (sorted "golden")

(* runtime *)

let parts = [ "main"; "arena"; "region"; "block"; "value"; "list"; "slot"; "handle"; "spawn"; "snapshot"; "tier" ]

let runtime () =
  let sources = String.concat " " (List.map (Printf.sprintf "../../runtime/%s.c") parts) in
  List.iter
    (fun name ->
      Printf.printf
        "(rule\n (deps %s.c walks.h scopes.h ../../runtime/zane.h ../../runtime/zane_abi.h ../../runtime/zane_internal.h %s)\n (targets %s.exe)\n (action\n  (run clang -std=c11 -Wall -Wextra -Werror -O2 -pthread -I ../../runtime -o %s.exe %s.c\n   %s)))\n\n"
        name sources name name name sources;
      Printf.printf "(rule\n (action\n  (with-stdout-to\n   %s.out.actual\n   (run ./%s.exe))))\n\n" name
        name;
      diff (name ^ ".out") (name ^ ".out.actual"))
    (List.filter_map (chop_suffix ~suffix:".c") (sorted "."))

(* What a directory holds to be tested, named as Fixture_pairing names it:
   the semantics builds whose rules are written by hand are left out. *)
let fixtures = function
  | Fixture_pairing.Runtime -> List.filter (fun f -> Filename.check_suffix f ".c") (sorted ".")
  | Semantics -> List.map (Filename.concat "fixtures/typing") (sorted "fixtures/typing")
  | Codegen | Ffi | Parser ->
      let entries dir = List.map (Filename.concat dir) (sorted dir) in
      List.filter (fun f -> f <> "fixtures/reject") (entries "fixtures") @ entries "fixtures/reject"

(* The golden files the directory's own dune file compares against, which
   Fixture_pairing leaves to those hand-written rules. A line's `;` comment is
   dropped first, so a rule commented out exempts nothing. *)
let hand_written () =
  let marker = "(diff golden/" in
  let golden line =
    let line = match String.index_opt line ';' with Some i -> String.sub line 0 i | None -> line in
    let rec find i =
      if i + String.length marker > String.length line then None
      else if String.sub line i (String.length marker) = marker then
        let start = i + String.length marker in
        let stop = Option.value (String.index_from_opt line start ' ') ~default:(String.length line) in
        Some (String.sub line start (stop - start))
      else find (i + 1)
    in
    find 0
  in
  if Sys.file_exists "dune" then
    List.filter_map golden (In_channel.with_open_bin "dune" In_channel.input_lines)
  else []

let () =
  let suite, rules =
    match Sys.argv with
    | [| _; "codegen" |] -> (Fixture_pairing.Codegen, codegen)
    | [| _; "ffi" |] -> (Fixture_pairing.Ffi, ffi)
    | [| _; "parser" |] -> (Parser, parser)
    | [| _; "runtime" |] -> (Runtime, runtime)
    | [| _; "semantics" |] -> (Semantics, semantics)
    | _ ->
        prerr_endline "usage: gen_rules (codegen|ffi|parser|runtime|semantics)";
        exit 2
  in
  match
    Fixture_pairing.check ~hand_written:(hand_written ()) suite ~fixtures:(fixtures suite)
      ~goldens:(sorted "golden")
  with
  | [] ->
      print_string "; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.\n\n";
      rules ()
  | errors ->
      List.iter (fun e -> prerr_endline ("gen_rules: " ^ e)) errors;
      exit 1

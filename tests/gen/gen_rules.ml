(* The dune rules of tests/codegen/, tests/parser/, tests/runtime/ and
   tests/semantics/, written
   from what those directories hold. Each directory's `dune` includes the
   `dune.inc` this prints, and diffs it against a fresh run, so a fixture
   added without its rules fails `dune runtest` until `dune promote` writes
   them.

   It runs in the directory it writes rules for, and the golden files decide
   which rules there are:

   - codegen: `golden/NAME.cgt` prints fixture NAME's code-generation tree,
     and `golden/NAME.out` builds it, unoptimized and optimized, and holds
     what both builds of the program wrote. A
     fixture whose `expected-status` file holds a status other than 0 is a
     program that stops: its golden file holds stdout and stderr together.
     `golden/reject.NAME.err` is what lowering reports for the package
     `fixtures/reject/NAME`, a program semantics accepts and lowering refuses.
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

(* codegen *)

let status name =
  let file = Filename.concat (Filename.concat "fixtures" name) "expected-status" in
  if Sys.file_exists file then
    int_of_string (String.trim (In_channel.with_open_text file In_channel.input_all))
  else 0

let codegen () =
  let goldens = sorted "golden" in
  let names suffix = List.filter_map (chop_suffix ~suffix) goldens in
  let trees = names ".cgt" and outputs = names ".out" in
  List.iter
    (fun name ->
      let package = "fixtures/" ^ name in
      if List.mem name trees then begin
        Printf.printf
          "(rule\n (deps (source_tree %s))\n (action\n  (with-stdout-to\n   %s.cgt.actual\n   (run %s --cgt --package %s))))\n\n"
          package name zanec package;
        diff (name ^ ".cgt") (name ^ ".cgt.actual")
      end;
      if List.mem name outputs then begin
        Printf.printf
          "(rule\n (deps (source_tree %s))\n (targets %s.exe)\n (action\n  (run %s --build %s.exe --package %s)))\n\n"
          package name zanec name package;
        Printf.printf
          "(rule\n (deps (source_tree %s))\n (targets %s.optimized.exe)\n (action\n  (run %s --build %s.optimized.exe --optimize --package %s)))\n\n"
          package name zanec name package;
        (* The optimized build is held to the same golden file: optimizing
           never changes what a program does. *)
        List.iter
          (fun exe ->
            (match status name with
            | 0 ->
                Printf.printf
                  "(rule\n (action\n  (with-stdout-to\n   %s.out.actual\n   (run ./%s.exe))))\n\n" exe
                  exe
            | n ->
                Printf.printf
                  "(rule\n (action\n  (with-outputs-to\n   %s.out.actual\n   (with-accepted-exit-codes\n    %d\n    (run ./%s.exe)))))\n\n"
                  exe n exe);
            diff (name ^ ".out") (exe ^ ".out.actual"))
          [ name; name ^ ".optimized" ]
      end)
    (List.sort_uniq compare (trees @ outputs));
  List.iter
    (fun golden ->
      match String.split_on_char '.' golden with
      | [ "reject"; name; "err" ] ->
          let package = "fixtures/reject/" ^ name in
          Printf.printf
            "(rule\n (deps (source_tree %s))\n (action\n  (with-stderr-to\n   %s.actual\n   (with-accepted-exit-codes\n    1\n    (run %s --cgt --package %s)))))\n\n"
            package golden zanec package;
          diff golden (golden ^ ".actual")
      | _ -> ())
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
            "(rule\n (deps (source_tree %s))\n (action\n  (with-stderr-to\n   %s.actual\n   (with-accepted-exit-codes\n    1\n    %s))))\n\n"
            dir golden run
        else
          Printf.printf
            "(rule\n (deps (source_tree %s))\n (action\n  (with-stdout-to\n   %s.actual\n   %s)))\n\n"
            dir golden run;
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

let parts = [ "main"; "arena"; "block"; "value"; "list"; "slot"; "spawn"; "snapshot" ]

let runtime () =
  let sources = String.concat " " (List.map (Printf.sprintf "../../runtime/%s.c") parts) in
  List.iter
    (fun name ->
      Printf.printf
        "(rule\n (deps %s.c ../../runtime/zane.h ../../runtime/zane_internal.h %s)\n (targets %s.exe)\n (action\n  (run clang -std=c11 -Wall -Wextra -Werror -O2 -pthread -I ../../runtime -o %s.exe %s.c\n   %s)))\n\n"
        name sources name name name sources;
      Printf.printf "(rule\n (action\n  (with-stdout-to\n   %s.out.actual\n   (run ./%s.exe))))\n\n" name
        name;
      diff (name ^ ".out") (name ^ ".out.actual"))
    (List.filter_map (chop_suffix ~suffix:".c") (sorted "."))

let () =
  print_string "; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.\n\n";
  match Sys.argv with
  | [| _; "codegen" |] -> codegen ()
  | [| _; "parser" |] -> parser ()
  | [| _; "runtime" |] -> runtime ()
  | [| _; "semantics" |] -> semantics ()
  | _ ->
      prerr_endline "usage: gen_rules (codegen|parser|runtime|semantics)";
      exit 2

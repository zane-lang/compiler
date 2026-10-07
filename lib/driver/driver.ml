(* The pipeline as a front end runs it (docs/design/stages.md). Each step
   returns a result whose failure is every problem it found, with the text
   of the files they point into, so a front end prints them all the same
   way. The rules that are about the build rather than about any one stage
   live here too: which package a `--stamp` names, and whether the root
   needs a `main`. *)

module Assembly = Tst.Assembly

type failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

let fail ?(sources = []) diagnostics = Error { diagnostics; sources }
let render failure = List.map (Diagnostic.render_in failure.sources) failure.diagnostics

(* What the root package is (packages.md §6.2): an application has a `main`
   to start from, and a library does not become an executable. *)
type kind = Application | Library

(* `--stamp NAME=STAMP` gives the one package named NAME its stamp. A stamp
   for a package the build does not have would be dropped silently, and the
   package it was meant for compiled into the root's object rather than
   linked from its own; one for a name two packages have would pick between
   them. *)
let with_stamps stamps requests =
  let problems = ref [] in
  let requests =
    List.fold_left
      (fun requests (name, stamp) ->
        let named (r : Assembly.request) =
          r.Assembly.stamp = None && String.equal (Assembly.path_of r) name
        in
        match List.filter named requests with
        | [ _ ] -> List.map (fun r -> if named r then { r with Assembly.stamp = Some stamp } else r) requests
        | [] ->
            problems :=
              Diagnostic.about_invocation
                (Printf.sprintf "`--stamp %s=...` names no package given with `--package`" name)
              :: !problems;
            requests
        | _ ->
            problems :=
              Diagnostic.about_invocation
                (Printf.sprintf
                   "`--stamp %s=...` names more than one package; give each its stamp with `--package STAMP%s=DIR`"
                   name name)
              :: !problems;
            requests)
      requests stamps
  in
  match !problems with [] -> Ok requests | problems -> fail (List.rev problems)

(* The packages of the build, read from their directories, the first the
   root when [root]: a library build has no root (packages.md §6.1). *)
let assemble ?(root = true) ?(imports = []) ?(stamps = []) requests =
  match with_stamps stamps requests with
  | Error _ as e -> e
  | Ok requests -> (
      match Assembly.assemble_requests ~root ~imports requests with
      | Ok packages -> Ok packages
      | Error { Assembly.diagnostics; sources } -> fail ~sources diagnostics)

(* Semantics, which reports every problem it finds (docs/design/semantics.md
   D4) and gives no tree when there is one. *)
let check packages =
  match Tst.check packages with
  | { Tst.Semantics.diagnostics = []; program } -> Ok program
  | { Tst.Semantics.diagnostics; _ } -> fail ~sources:(Assembly.sources packages) diagnostics

(* An application starts from `main` (packages.md §6.2), so one without it is
   an error however far the build goes. This is the one check for `main`:
   lowering takes it as given. *)
let require_main (program : Tst.Nodes.Program.t) =
  match program.Tst.Nodes.Program.packages with
  | root :: _ ->
      let declares_main =
        List.exists
          (fun (d : Tst.Nodes.Decl.t) ->
            match d.Tst.Nodes.Decl.node with
            | Tst.Nodes.Decl.Verb { signature; _ } -> signature.Tst.Signature.name = "main"
            | _ -> false)
          root.Tst.Nodes.Package.decls
      in
      if declares_main then Ok ()
      else
        fail
          [
            Diagnostic.about_invocation
              (Printf.sprintf "the application `%s` declares no `main` to start from"
                 root.Tst.Nodes.Package.name);
          ]
  | [] -> Ok ()

(* Lowering refuses what it cannot handle yet with a diagnostic rather than
   lowering it wrongly (docs/design/lowering.md). A library lowers from every
   function it declares. *)
let lower ~kind packages program =
  match Cgt.lower ~library:(kind = Library) program with
  | Ok cgt -> Ok cgt
  | Error d -> fail ~sources:(Assembly.sources packages) [ d ]

(* Stage 5 (docs/design/optimization.md), which only an optimized build
   runs: an unoptimized one is the same pipeline with no passes. *)
let optimize ~optimize cgt = if optimize then Optimize.run cgt else cgt

(* Codegen's own failures -- an unknown target, a link that failed -- are
   about the build, not about any file of it. *)
let built = function Ok v -> Ok v | Error message -> fail [ Diagnostic.about_invocation message ]

let ir ?target ~optimize cgt =
  let m = Codegen.emit cgt in
  built (Result.map (fun () -> Codegen.ir m) (Codegen.prepare ?target ~optimize m))

let executable ?target ~optimize ~link cgt output =
  built (Codegen.executable ?target ~optimize ~link (Codegen.emit cgt) output)

let object_file ?target ~optimize cgt output =
  built (Codegen.object_file ?target ~optimize (Codegen.emit cgt) output)

(* A library is checked and built into an object, never into an
   executable. *)
let buildable = function
  | Some Library -> fail [ Diagnostic.about_invocation "a library is not built into an executable; check it with `--check`" ]
  | _ -> Ok ()

(* The pipeline as a front end runs it (docs/design/stages.md). Each step
   returns a result whose failure is every problem it found, with the text
   of the files they point into, so a front end prints them all the same
   way. The rules that are about the build rather than about any one stage
   live here too: which package a `--stamp` names, and whether the root
   needs a `main`. So does rewriting an object, fetching's step rather than a
   build's (docs/design/separate-compilation.md C9, C11). *)

module Assembly = Tst.Assembly

type failure = { diagnostics : Diagnostic.t list; sources : Source.Files.t }

let fail ?(sources = []) diagnostics = Error { diagnostics; sources }
let render failure = List.map (Diagnostic.render_in failure.sources) failure.diagnostics

(* What the root package is (packages.md §6.2): an application has a `main`
   to start from, and a library does not become an executable. *)
type kind = Application | Library

let not_stamp stamp =
  Printf.sprintf
    "`%s` is not a stamp: a version tag of letters, digits, `.`, `_`, `+` and `-`, then `%%`, 16 lowercase hexadecimal digits and `%%`"
    stamp

(* `--stamp NAME=STAMP` gives the one package named NAME its stamp. A stamp
   for a package the build does not have would be dropped silently, and the
   package it was meant for compiled into the root's object rather than
   linked from its own; one for a name two packages have would pick between
   them. A value that is no stamp would name the package's symbols with it,
   while lowering, which recognizes a stamp by its form, took the package
   for unstamped. *)
let with_stamps stamps requests =
  let problems = ref [] in
  let requests =
    List.fold_left
      (fun requests (name, stamp) ->
        let named (r : Assembly.request) =
          r.Assembly.stamp = None && String.equal (Assembly.path_of r) name
        in
        match List.filter named requests with
        | _ when not (Rewrite.is_stamp stamp) ->
            problems := Diagnostic.about_invocation (not_stamp stamp) :: !problems;
            requests
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
(* The sizes of each context's range of frames, from `--fixed-region` and
   `--spawned-fixed-region`; the defaults
   when absent. *)
type regions = { fixed : int option; spawned : int option }

let no_regions = { fixed = None; spawned = None }

(* Every build takes in its stamped dependencies' bodies, which LLVM inlines
   and defines in no object (docs/design/separate-compilation.md C12): an
   unoptimized build's inlining needs them as much as an optimized one's. *)
let lower ?(regions = no_regions) ~kind packages program =
  match Cgt.lower ~library:(kind = Library) ~import_bodies:true ?fixed_region:regions.fixed program with
  | Ok cgt -> Ok cgt
  | Error d -> fail ~sources:(Assembly.sources packages) [ d ]

(* Stage 5 (docs/design/optimization.md), which only an optimized build
   runs: an unoptimized one skips it. *)
let optimize ~optimize cgt = if optimize then Optimize.run cgt else cgt

(* Codegen's own failures -- an unknown target, a link that failed -- are
   about the build, not about any file of it. *)
let built = function Ok v -> Ok v | Error message -> fail [ Diagnostic.about_invocation message ]

(* The program's module exists only inside [f] (Codegen.with_program). *)
let emitted ?target ?pack ?memoize regions cgt f =
  Codegen.with_program ?target ?pack ?memoize ?fixed_region:regions.fixed ?spawned_fixed_region:regions.spawned cgt f

let ir ?target ?pack ?memoize ?(regions = no_regions) ~optimize cgt =
  built
    (emitted ?target ?pack ?memoize regions cgt (fun m ->
         Result.map (fun () -> Codegen.ir m) (Codegen.prepare ?target ~optimize m)))

(* A [tiered] build is tier 0 (docs/design/tiers.md). Every build plans
   what it remembers alike, so it and tier 1 emit the same module. *)
let executable ?target ?pack ?memoize ?(regions = no_regions) ?(tiered = false) ~optimize ~link cgt output =
  let tier = if tiered then Codegen.Tier0 else Codegen.Plain in
  built
    (emitted ?target ?pack ?memoize regions cgt (fun m ->
         Codegen.executable ?target ~optimize ~tier ~link m output))

(* Tier 1 of a tiered build, from the tree lowering made, without stage 5,
   so it emits the module tier 0 does. *)
let tier_up ?target ?pack ?memoize ?(regions = no_regions) cgt output =
  built (emitted ?target ?pack ?memoize regions cgt (fun m -> Codegen.shared_library ?target m output))

let object_file ?target ?pack ?memoize ?(regions = no_regions) ~optimize cgt output =
  built (emitted ?target ?pack ?memoize regions cgt (fun m -> Codegen.object_file ?target ~optimize m output))

let bundle_runtime ~target ~optimize dir = built (Codegen.bundle_runtime ~target ~optimize dir)

(* A library is checked and built into an object, never into an
   executable. *)
let buildable = function
  | Some Library -> fail [ Diagnostic.about_invocation "a library is not built into an executable; check it with `--check`" ]
  | _ -> Ok ()

(* The name of a file beside [output] to write it under before it is renamed
   into place, drawn from [random]. *)
let temporary_name random output =
  Filename.concat (Filename.dirname output)
    (Printf.sprintf ".%s.%08x" (Filename.basename output) (Random.State.bits random))

(* How many names [write_replacing] draws before it gives up: each one
   already taken is a file someone else made. *)
let temporary_attempts = 8

(* [contents] written beside [output] and renamed into place, so a failed
   write leaves an existing [output], or the input it may be, as it was. The
   temporary is created exclusively, so a name that already exists is
   another's file: it is left alone and a new name drawn. Any failure to
   create one draws again, since [Sys_error] does not say whether the name
   was taken, and a lookup after the fact misses a dangling symlink or a file
   removed in between. Only a temporary this call created is removed when a
   later step fails. *)
let write_replacing ~random ~output contents =
  let rec attempt drawn =
    let temporary = temporary_name random output in
    let created = ref false in
    match
      Out_channel.with_open_gen
        [ Open_wronly; Open_creat; Open_excl; Open_binary ]
        0o666 temporary
        (fun oc ->
          created := true;
          output_string oc contents);
      Sys.rename temporary output
    with
    | () -> Ok ()
    | exception Sys_error message ->
        if !created then begin
          (try Sys.remove temporary with Sys_error _ -> ());
          Error message
        end
        else if drawn < temporary_attempts then attempt (drawn + 1)
        else Error message
  in
  attempt 1

(* The output is written only once the whole object has been rewritten, so a
   malformed input leaves nothing behind. *)
let rewrite_object ~random ~stamps ~rewrite ~input ~output =
  let fail_with message = fail [ Diagnostic.about_invocation message ] in
  match List.find_opt (fun stamp -> not (Rewrite.is_stamp stamp)) stamps with
  | Some stamp -> fail_with (not_stamp stamp)
  | None -> (
      match stamps with
      | [ from; to_ ] when not (Rewrite.same_package from to_) ->
          fail_with
            (Printf.sprintf
               "`%s` and `%s` are versions of two packages, since their identity hashes differ; \
                remapping moves references between versions of one package"
               from to_)
      | _ -> (
          match In_channel.with_open_bin input In_channel.input_all with
          | exception Sys_error message -> fail_with message
          | contents -> (
              match rewrite contents with
              | Error message -> fail_with (input ^ ": " ^ message)
              | Ok (rewritten, _) -> (
                  match write_replacing ~random ~output rewritten with
                  | Ok () -> Ok ()
                  | Error message ->
                      fail_with (Printf.sprintf "cannot write `%s`: %s" output message)))))

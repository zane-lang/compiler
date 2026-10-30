(* Which fixture each golden file of a test directory holds the expectation
   of, so that a fixture with no golden file, or a golden file whose fixture
   is gone, stops tests/gen/gen_rules.ml rather than leaving a program
   untested. Every fixture is tested, so neither has an opt-out.

   A fixture is named by its path in the directory: `fixtures/NAME` for a
   codegen package, `fixtures/reject/NAME` for one lowering refuses,
   `fixtures/NAME.zn` and `fixtures/reject/NAME.zn` for a parser source,
   `fixtures/NAME` and `fixtures/reject/NAME` for a C interface package,
   `fixtures/typing/NAME` for a semantics build, and `NAME.c` for a runtime
   test. *)

type suite = Codegen | Ffi | Parser | Runtime | Semantics

(* The fixture [golden] holds the expectation of: [Ok None] for a golden
   file a rule written by hand compares against, one of [hand_written], and
   [Error] for one no rule makes. *)
let fixture ?(hand_written = []) suite golden =
  match (suite, String.split_on_char '.' golden) with
  | _ when List.mem golden hand_written -> Ok None
  | Codegen, ([ name; ("cgt" | "out") ] | [ name; "optimized"; "cgt" ]) ->
      Ok (Some ("fixtures/" ^ name))
  | Ffi, ([ name; ("check" | "tst" | "cgt" | "out") ] | [ name; "optimized"; "cgt" ]) ->
      Ok (Some ("fixtures/" ^ name))
  | (Codegen | Ffi | Parser), [ "reject"; name; "err" ] ->
      Ok (Some ("fixtures/reject/" ^ name ^ if suite = Parser then ".zn" else ""))
  | Ffi, [ "reject"; name; "ll"; "err" ] -> Ok (Some ("fixtures/reject/" ^ name))
  | Parser, [ name; _stage; ("spans" | "tree") ] -> Ok (Some ("fixtures/" ^ name ^ ".zn"))
  | Runtime, [ name; "out" ] -> Ok (Some (name ^ ".c"))
  | Semantics, ([ "typing"; name; ("decls" | "tst" | "err") ] | [ "typing"; name; "tst"; "spans" ])
    ->
      Ok (Some ("fixtures/typing/" ^ name))
  | _ -> Error (Printf.sprintf "no rule makes golden/%s" golden)

(* Every way [fixtures] and [goldens] fail to pair, in name order, each
   naming the file: a golden file no rule makes or whose fixture does not
   exist, then a fixture no golden file holds the expectation of.
   [hand_written] names the golden files the directory's own rules compare
   against. *)
let check ?hand_written suite ~fixtures ~goldens =
  let goldens = List.sort compare goldens and fixtures = List.sort compare fixtures in
  let paired = List.map (fun g -> (g, fixture ?hand_written suite g)) goldens in
  let orphan_goldens =
    List.filter_map
      (fun (golden, fixture) ->
        match fixture with
        | Error message -> Some message
        | Ok (Some f) when not (List.mem f fixtures) ->
            Some (Printf.sprintf "golden/%s is for %s, which does not exist" golden f)
        | Ok _ -> None)
      paired
  in
  let orphan_fixtures =
    List.filter_map
      (fun f ->
        if List.exists (fun (_, fixture) -> fixture = Ok (Some f)) paired then None
        else Some (Printf.sprintf "%s has no golden file" f))
      fixtures
  in
  orphan_goldens @ orphan_fixtures

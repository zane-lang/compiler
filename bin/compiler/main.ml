(* Parsing the checked-in sample is the common case while the front end is the
   only stage, so it stays the default when no source is named. *)
let default_path = "test/parser/fixtures/main.zn"

(* Which tree to print. The CST stays the default because it is what the source
   says, and a reader checking the parser wants that one; `--sst` is for
   checking the desugaring, where the interesting thing is what is no longer
   there. *)
type stage = Cst | Sst

let read_file path =
  try In_channel.with_open_text path In_channel.input_all
  with Sys_error message ->
    prerr_endline message;
    exit 2

let usage () =
  prerr_endline "usage: compiler [--cst|--sst] [SOURCE|-]";
  exit 2

(* The name reported in parse errors travels with the text, so reading from
   standard input still produces a located message. *)
let read = function
  | "-" -> ("<stdin>", In_channel.input_all In_channel.stdin)
  | path -> (path, read_file path)

let arguments () =
  let rec go stage rest =
    match rest with
    | [] -> (stage, read default_path)
    | "--cst" :: rest -> go Cst rest
    | "--sst" :: rest -> go Sst rest
    (* `-` is the stdin source, not an option, so it is taken before the guard
       below rejects everything else that starts with a dash. Without that
       guard a mistyped `--ss` reads as a path, and the error names a file the
       author never meant to open rather than the option they meant to
       write. *)
    | [ "-" ] -> (stage, read "-")
    | [ source ] when not (String.starts_with ~prefix:"-" source) ->
        (stage, read source)
    | _ -> usage ()
  in
  go Cst (List.tl (Array.to_list Sys.argv))

let () =
  let stage, (filename, input) = arguments () in
  match Cst.parse filename input with
  | Error diagnostic ->
      prerr_string (Diagnostic.render ~source:input diagnostic);
      exit 1
  | Ok cst ->
      let output =
        match stage with
        | Cst -> Cst.to_node cst
        | Sst -> Sst.to_node (Sst.of_cst cst)
      in
      print_string (Tree_graph.render output)

(* Print every node in a parsed file with the source text its span covers.

   A span is only ever wrong by pointing somewhere, and the cheapest way to see
   where is to read it back out of the source. Each line is one node: its kind,
   and the text between its span's two positions.

   The walk itself is not here. Rendering a stage's nodes is that stage's
   business, so it lives in [Cst.To_span_text] and [Sst.To_span_text], the
   span-side counterparts of [Cst.To_tree_graph] and [Sst.To_tree_graph]. This
   file is the frontend: it reads the source, parses it, picks the stage, and
   prints what the adapter returns. The stage is selected the same way the
   compiler frontend selects it, with `--cst` or `--sst`.

   The output is checked in under `test/parser/golden/` and compared on every
   run, so a grammar change that moves a span shows the move as a diff rather
   than as nothing at all. *)

(* The CST is the default for the same reason it is the compiler's: it is what
   the source says, and a reader checking the parser wants that one. *)
type stage = Cst | Sst

let usage () =
  prerr_endline "usage: span_dump [--cst|--sst] SOURCE";
  exit 2

let arguments () =
  let rec go stage rest =
    match rest with
    | "--cst" :: rest -> go Cst rest
    | "--sst" :: rest -> go Sst rest
    | [ source ] when not (String.starts_with ~prefix:"-" source) ->
        (stage, source)
    | _ -> usage ()
  in
  go Cst (List.tl (Array.to_list Sys.argv))

let () =
  let stage, path = arguments () in
  let input = In_channel.with_open_text path In_channel.input_all in
  match Cst.parse path input with
  | Error diagnostic ->
      prerr_string (Diagnostic.render ~source:input diagnostic);
      exit 1
  | Ok package ->
      print_string
        (match stage with
        | Cst -> Cst.To_span_text.render ~source:input package
        | Sst -> Sst.To_span_text.render ~source:input (Sst.of_cst package))

(* A position in a C file from the line and column the front end gives,
   both counted from one, the column in bytes, so a diagnostic about C is
   drawn under its text as one about Zane is. *)

(* The position of [line], [column] in [source], the text of [path]; [None]
   when the file has no such line. *)
let position ~path source ~line ~column =
  let rec start_of l offset =
    if l = line then Some offset
    else
      match String.index_from_opt source offset '\n' with
      | Some i -> start_of (l + 1) (i + 1)
      | None -> None
  in
  Option.map
    (fun bol ->
      let eol = Option.value ~default:(String.length source) (String.index_from_opt source bol '\n') in
      let cnum = min eol (bol + max 0 (column - 1)) in
      { Lexing.pos_fname = path; pos_lnum = line; pos_bol = bol; pos_cnum = cnum })
    (if line >= 1 then start_of 1 0 else None)

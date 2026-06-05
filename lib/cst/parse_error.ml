let tab_width = 4

let visual_col_of_idx s idx =
  let rec aux i vcol =
    if i >= idx then vcol
    else
      let c = s.[i] in
      let step = if c = '\t' then tab_width - (vcol mod tab_width) else 1 in
      aux (i + 1) (vcol + step)
  in
  aux 0 0

let expand_tabs s =
  let buf = Buffer.create (String.length s + 10) in
  let rec aux i vcol =
    if i >= String.length s then Buffer.contents buf
    else
      let c = s.[i] in
      if c = '\t' then
        let spaces = tab_width - (vcol mod tab_width) in
        let () = Buffer.add_string buf (String.make spaces ' ') in
        aux (i + 1) (vcol + spaces)
      else
        let () = Buffer.add_char buf c in
        aux (i + 1) (vcol + 1)
  in
  aux 0 0

let print_parse_error filename input pos_start pos_end =
  let line = pos_start.Lexing.pos_lnum in
  let char_start = pos_start.Lexing.pos_cnum - pos_start.Lexing.pos_bol in
  let char_end = pos_end.Lexing.pos_cnum - pos_start.Lexing.pos_bol in
  let lines = String.split_on_char '\n' input in
  let source_line =
    match List.nth_opt lines (line - 1) with
    | Some l ->
        let len = String.length l in
        if len > 0 && l.[len - 1] = '\r' then String.sub l 0 (len - 1) else l
    | None -> "<unknown>"
  in
  
  let vcol_start = visual_col_of_idx source_line char_start in
  let vcol_end = visual_col_of_idx source_line char_end in
  let visual_source_line = expand_tabs source_line in
  
  let () = Printf.eprintf "File \"%s\", line %d, characters %d-%d:\n" filename line (vcol_start + 1) (vcol_end + 1) in
  let () = Printf.eprintf "%d | %s\n" line visual_source_line in
  let () = Printf.eprintf "  | %s%s\n" (String.make vcol_start ' ') (String.make (max 1 (vcol_end - vcol_start)) '^') in
  let () = Printf.eprintf "Error: Parse error\n" in
  exit 1

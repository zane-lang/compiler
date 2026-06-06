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

let format_parse_error filename input pos_start pos_end =
  let line = pos_start.Lexing.pos_lnum in
  let char_start = pos_start.Lexing.pos_cnum - pos_start.Lexing.pos_bol in
  let lines = String.split_on_char '\n' input in
  let source_line =
    match List.nth_opt lines (line - 1) with
    | Some l ->
        let len = String.length l in
        if len > 0 && l.[len - 1] = '\r' then String.sub l 0 (len - 1) else l
    | None -> "<unknown>"
  in
  let line_len = String.length source_line in
  (* The error span may cross newlines. We only display the start line, so the
     caret must stop at that line's end rather than following pos_end into
     later lines. *)
  let same_line = pos_end.Lexing.pos_lnum = line in
  let char_end =
    if same_line then
      min line_len (pos_end.Lexing.pos_cnum - pos_start.Lexing.pos_bol)
    else
      line_len
  in
  let char_start = min char_start line_len in
  let char_end = max char_start char_end in

  let vcol_start = visual_col_of_idx source_line char_start in
  let vcol_end = visual_col_of_idx source_line char_end in
  let visual_source_line = expand_tabs source_line in

  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (Printf.sprintf "File \"%s\", line %d, characters %d-%d:\n"
       filename line (vcol_start + 1) (vcol_end + 1));
  Buffer.add_string buf
    (Printf.sprintf "%d | %s\n" line visual_source_line);
  Buffer.add_string buf
    (Printf.sprintf "  | %s%s\n"
       (String.make vcol_start ' ')
       (String.make (max 1 (vcol_end - vcol_start)) '^'));
  Buffer.add_string buf "Error: Parse error\n";
  Buffer.contents buf

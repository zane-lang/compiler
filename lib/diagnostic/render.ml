(* A diagnostic as a person reads it at a terminal: where it is, the line it is
   on with a caret under the text it covers, and what is wrong.

   Only the span's first line is shown. The file name is the one the span's
   positions carry, which [Cst.parse] sets on every position it produces.

   The line is built once, as a list of pieces: each source character, the
   bytes shown for it, and how many cells it takes. The source row is those
   bytes in order, and the caret row counts their cells, so the two cannot
   disagree about where a character sits. A character that would act on the
   terminal rather than be drawn -- a control, a bidirectional override, a byte
   that is not UTF-8 -- is shown as an escape such as [\x1b] or [\u202e],
   written in ASCII and as wide as its text. The file name and the message are
   escaped the same way, so source text quoted in a message is safe too: it is
   escaped here, when it is printed, not where the message is made. *)

let tab_width = 4

(* The Unicode Bidi_Control characters. Each reorders the text after it, so
   shown as is it would make the line read differently from the source. *)
let is_bidi_control c =
  c = 0x061C || c = 0x200E || c = 0x200F || (c >= 0x202A && c <= 0x202E)
  || (c >= 0x2066 && c <= 0x2069)

(* The escape a character is shown as, if it is one the terminal would act on:
   a C0 control other than tab, DEL, a C1 control, or a Bidi_Control
   character. Tab is left to the caller, which expands it in a source line. *)
let escape u =
  let c = Uchar.to_int u in
  if (c < 0x20 && c <> 0x09) || c = 0x7F then Some (Printf.sprintf "\\x%02x" c)
  else if (c >= 0x80 && c <= 0x9F) || is_bidi_control c then Some (Printf.sprintf "\\u%04x" c)
  else None

(* Bytes that do not decode as UTF-8, one escape each. *)
let escape_bytes s =
  String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "\\x%02x" (Char.code s.[i])))

(* Text printed outside the excerpt -- a file name, a message -- with every
   character the terminal would act on escaped. *)
let escaped s =
  let buf = Buffer.create (String.length s) in
  let rec aux i =
    if i < String.length s then begin
      let d = String.get_utf_8_uchar s i in
      let n = Uchar.utf_decode_length d in
      let bytes = String.sub s i n in
      let shown =
        if not (Uchar.utf_decode_is_valid d) then escape_bytes bytes
        else Option.value (escape (Uchar.utf_decode_uchar d)) ~default:bytes
      in
      Buffer.add_string buf shown;
      aux (i + n)
    end
  in
  aux 0;
  Buffer.contents buf

(* One character of the displayed line: the source bytes [first, next), what
   is shown for them, and the cells that takes. *)
type piece = { first : int; next : int; shown : string; cells : int }

let pieces line =
  let rec aux i column acc =
    if i >= String.length line then List.rev acc
    else
      let d = String.get_utf_8_uchar line i in
      let n = Uchar.utf_decode_length d in
      let bytes = String.sub line i n in
      let shown, cells =
        if not (Uchar.utf_decode_is_valid d) then
          let e = escape_bytes bytes in
          (e, String.length e)
        else
          let u = Uchar.utf_decode_uchar d in
          if Uchar.to_int u = 0x09 then
            let spaces = tab_width - (column mod tab_width) in
            (String.make spaces ' ', spaces)
          else
            match escape u with
            | Some e -> (e, String.length e)
            | None -> (bytes, 1)
      in
      aux (i + n) (column + cells) ({ first = i; next = i + n; shown; cells } :: acc)
  in
  aux 0 0 []

(* The cell a byte offset starts at, counting the pieces wholly before it, and
   the cell it ends at, counting every piece it reaches into. A span that starts
   or ends inside a piece so covers all of it. *)
let cells_before pieces idx =
  List.fold_left (fun n p -> if p.next <= idx then n + p.cells else n) 0 pieces

let cells_through pieces idx =
  List.fold_left (fun n p -> if p.first < idx then n + p.cells else n) 0 pieces

(* The header's columns count characters, a tab advancing to its stop, rather
   than cells, so an editor's jump to a column lands where it did. Positions
   arrive as byte offsets, and a UTF-8 continuation byte is the tail of a
   character already counted, so it advances no column. *)
let is_utf8_continuation c = Char.code c land 0xC0 = 0x80

let character_column s idx =
  let rec aux i col =
    if i >= idx then col
    else
      let c = s.[i] in
      let step =
        if c = '\t' then tab_width - (col mod tab_width)
        else if is_utf8_continuation c then 0
        else 1
      in
      aux (i + 1) (col + step)
  in
  aux 0 0

let at_span ~source severity span message =
  let pos_start = span.Source.Span.start_ and pos_end = span.Source.Span.end_ in
  let filename = pos_start.Lexing.pos_fname in
  let line = pos_start.Lexing.pos_lnum in
  let char_start = pos_start.Lexing.pos_cnum - pos_start.Lexing.pos_bol in
  let lines = String.split_on_char '\n' source in
  let source_line =
    match List.nth_opt lines (line - 1) with
    | Some l ->
        let len = String.length l in
        if len > 0 && l.[len - 1] = '\r' then String.sub l 0 (len - 1) else l
    | None -> "<unknown>"
  in
  let line_len = String.length source_line in
  (* The span may cross newlines. We only display the start line, so the
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

  let shown = pieces source_line in
  let cell_start = cells_before shown char_start in
  let cell_end = cells_through shown char_end in

  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (Printf.sprintf "File \"%s\", line %d, characters %d-%d:\n"
       (escaped filename) line
       (character_column source_line char_start + 1)
       (character_column source_line char_end + 1));
  Buffer.add_string buf
    (Printf.sprintf "%d | %s\n" line (String.concat "" (List.map (fun p -> p.shown) shown)));
  Buffer.add_string buf
    (Printf.sprintf "  | %s%s\n"
       (String.make cell_start ' ')
       (String.make (max 1 (cell_end - cell_start)) '^'));
  Buffer.add_string buf
    (Printf.sprintf "%s: %s\n" (Report.Severity.label severity) message);
  Buffer.contents buf

(* A report about a file or a directory has no source excerpt: the same two
   lines a report about text starts with, minus the excerpt. *)
let render ~source ({ Report.severity; location; message } : Report.t) =
  let label = Report.Severity.label severity in
  let message = escaped message in
  match location with
  | Report.Location.Span span -> at_span ~source severity span message
  | Report.Location.File path ->
      Printf.sprintf "File \"%s\":\n%s: %s\n" (escaped path) label message
  | Report.Location.Directory dir ->
      Printf.sprintf "Directory \"%s\":\n%s: %s\n" (escaped dir) label message
  | Report.Location.Invocation -> Printf.sprintf "%s: %s\n" label message

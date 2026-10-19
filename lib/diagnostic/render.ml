(* A diagnostic as a person reads it at a terminal: where it is, the line it is
   on with a caret under the text it covers, and what is wrong.

   Only the span's first line is shown. The file name is the one the span's
   positions carry, which [Cst.parse] sets on every position it produces.

   The line is built once, as a list of pieces: each grapheme cluster, the
   unit a terminal draws as one glyph, with the bytes shown for it and how many
   cells it takes. The source row is those bytes in order, and the caret row
   counts their cells, so the two cannot disagree about where a character
   sits: a combining mark adds nothing, and a wide East Asian character or an
   emoji takes two. A character that would act on the
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

(* A grapheme cluster: the characters a terminal draws as one glyph, found by
   [Uuseg], and the source bytes [first, next) they came from. *)
type cluster = { first : int; next : int; chars : Uchar.t list }

(* The line's clusters, and each run of bytes that is not UTF-8 on its own.
   The segmenter is fed one character at a time and hands characters back in
   the same order, perhaps later, so the byte length of each one fed waits in
   [pending] until it comes out. A byte that does not decode ends the
   segmentation, since a cluster cannot span it, and a fresh one starts after. *)
let clusters line =
  let out = ref [] in
  let current = ref None in
  let pending = Queue.create () in
  let close () =
    Option.iter (fun c -> out := `Cluster { c with chars = List.rev c.chars } :: !out) !current;
    current := None
  in
  let rec drain segmenter v =
    match Uuseg.add segmenter v with
    | `Await | `End -> ()
    | `Boundary ->
        close ();
        drain segmenter `Await
    | `Uchar u ->
        let first, next = Queue.pop pending in
        current :=
          Some
            (match !current with
            | None -> { first; next; chars = [ u ] }
            | Some c -> { c with next; chars = u :: c.chars });
        drain segmenter `Await
  in
  let rec aux segmenter i =
    if i >= String.length line then begin
      drain segmenter `End;
      close ()
    end
    else
      let d = String.get_utf_8_uchar line i in
      let n = Uchar.utf_decode_length d in
      if Uchar.utf_decode_is_valid d then begin
        Queue.push (i, i + n) pending;
        drain segmenter (`Uchar (Uchar.utf_decode_uchar d));
        aux segmenter (i + n)
      end
      else begin
        drain segmenter `End;
        close ();
        out := `Invalid (i, i + n) :: !out;
        aux (Uuseg.create `Grapheme_cluster) (i + n)
      end
  in
  aux (Uuseg.create `Grapheme_cluster) 0;
  List.rev !out

let is_regional_indicator u = Uchar.to_int u >= 0x1F1E6 && Uchar.to_int u <= 0x1F1FF

(* The cells a cluster takes. An emoji sequence is two: a ZWJ sequence such as
   a family, a pair of regional indicators that makes a flag, and an emoji
   asking for emoji presentation with U+FE0F, such as U+00A9 U+FE0F. A terminal
   draws these as one wide glyph, though [tty_width_hint] sees one character at
   a time and calls some of them one cell. Any other cluster is as wide as its
   first character: two for a wide East Asian character, one otherwise, with
   combining marks and the rest of the cluster adding nothing. *)
let cluster_cells = function
  | [] -> 0
  | first :: rest ->
      let has c = List.exists (fun u -> Uchar.to_int u = c) rest in
      let emoji =
        (Uucp.Emoji.is_extended_pictographic first && has 0x200D)
        || (is_regional_indicator first && List.exists is_regional_indicator rest)
        || (Uucp.Emoji.is_emoji first && has 0xFE0F)
      in
      if emoji then 2 else max 0 (Uucp.Break.tty_width_hint first)

(* One glyph of the displayed line: the source bytes [first, next), what is
   shown for them, and the cells that takes. *)
type piece = { first : int; next : int; shown : string; cells : int }

let pieces line =
  let piece column = function
    | `Invalid (first, next) ->
        let e = escape_bytes (String.sub line first (next - first)) in
        { first; next; shown = e; cells = String.length e }
    | `Cluster { first; next; chars } -> (
        let bytes = String.sub line first (next - first) in
        match chars with
        | [ u ] when Uchar.to_int u = 0x09 ->
            let spaces = tab_width - (column mod tab_width) in
            { first; next; shown = String.make spaces ' '; cells = spaces }
        | _ when List.exists (fun u -> escape u <> None) chars ->
            (* A control is a cluster of its own, so this is that one
               character; the rest are shown one by one all the same. *)
            let one u =
              match escape u with
              | Some e -> (e, String.length e)
              | None ->
                  let b = Buffer.create 4 in
                  Buffer.add_utf_8_uchar b u;
                  (Buffer.contents b, cluster_cells [ u ])
            in
            let parts = List.map one chars in
            {
              first;
              next;
              shown = String.concat "" (List.map fst parts);
              cells = List.fold_left (fun n (_, w) -> n + w) 0 parts;
            }
        | _ -> { first; next; shown = bytes; cells = cluster_cells chars })
  in
  let _, acc =
    List.fold_left
      (fun (column, acc) c ->
        let p = piece column c in
        (column + p.cells, p :: acc))
      (0, []) (clusters line)
  in
  List.rev acc

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

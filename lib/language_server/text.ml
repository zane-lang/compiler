(* Positions in a text, as the compiler counts them and as an editor does.

   A span is a pair of byte offsets. An editor names a position by its line
   and by a character count along that line, in the units the server and the
   client agreed on: UTF-8 bytes or UTF-16 code units
   (docs/design/language-server.md, D9). *)

type encoding = Utf8 | Utf16

(* The byte offset at which each line starts. A line ends at LF, CRLF or a
   bare CR, as the protocol counts lines. *)
type lines = { text : string; starts : int array }

let lines text =
  let starts = ref [ 0 ] in
  let n = String.length text in
  String.iteri
    (fun i c ->
      if c = '\n' || (c = '\r' && not (i + 1 < n && text.[i + 1] = '\n')) then starts := (i + 1) :: !starts)
    text;
  { text; starts = Array.of_list (List.rev !starts) }

(* The length in bytes of the UTF-8 sequence that starts with [c]. *)
let sequence_length c =
  let b = Char.code c in
  if b < 0x80 then 1 else if b < 0xe0 then 2 else if b < 0xf0 then 3 else 4

(* The line holding [offset]: the last line starting at or before it. *)
let line_of t offset =
  let rec search lo hi = if lo >= hi then lo else
      let mid = (lo + hi + 1) / 2 in
      if t.starts.(mid) <= offset then search mid hi else search lo (mid - 1)
  in
  search 0 (Array.length t.starts - 1)

(* The end of a line's text, before its line break. *)
let line_end t line =
  let start = t.starts.(line) in
  if line + 1 >= Array.length t.starts then String.length t.text
  else
    let next = t.starts.(line + 1) in
    let before_break = if t.text.[next - 1] = '\n' then next - 1 else next in
    if before_break > start && t.text.[before_break - 1] = '\r' then before_break - 1 else before_break

let position encoding t offset =
  let offset = max 0 (min offset (String.length t.text)) in
  let line = line_of t offset in
  let start = t.starts.(line) in
  match encoding with
  | Utf8 -> (line, offset - start)
  | Utf16 ->
      let rec count i units =
        if i >= offset then units
        else
          let n = sequence_length t.text.[i] in
          count (i + n) (units + if n = 4 then 2 else 1)
      in
      (line, count start 0)

let offset encoding t (line, character) =
  if line < 0 then 0
  else if line >= Array.length t.starts then String.length t.text
  else
    let start = t.starts.(line) and stop = line_end t line in
    match encoding with
    | Utf8 -> min (start + max 0 character) stop
    | Utf16 ->
        let rec walk i units =
          if i >= stop || units >= character then i
          else
            let n = sequence_length t.text.[i] in
            walk (i + n) (units + if n = 4 then 2 else 1)
        in
        walk start 0

(* An edit an editor sent: the text between two offsets replaced. *)
let replace text ~start ~stop replacement =
  String.sub text 0 start ^ replacement ^ String.sub text stop (String.length text - stop)

(* How the offsets of [before] move to [after]: the bytes both share at the
   start and at the end stay where they were, shifted by the change in
   length, and an offset inside the changed part has no place in [after]. A
   tree read from [before] is still right about everything outside the
   change (docs/design/language-server.md, D7). *)
type shift = { prefix : int; old_suffix_start : int; delta : int }

let shift ~before ~after =
  let lb = String.length before and la = String.length after in
  let rec common_prefix i = if i < lb && i < la && before.[i] = after.[i] then common_prefix (i + 1) else i in
  let prefix = common_prefix 0 in
  let rec common_suffix i =
    if i < lb - prefix && i < la - prefix && before.[lb - 1 - i] = after.[la - 1 - i] then common_suffix (i + 1) else i
  in
  let suffix = common_suffix 0 in
  { prefix; old_suffix_start = lb - suffix; delta = la - lb }

let identity = { prefix = max_int; old_suffix_start = max_int; delta = 0 }

(* Where a span of [before], from [start] to [stop], is in [after]. *)
let move s (start, stop) =
  if stop <= s.prefix then Some (start, stop)
  else if start >= s.old_suffix_start then Some (start + s.delta, stop + s.delta)
  else None

(* Where an offset of [after] was in [before]. Where text was deleted, the
   offset at the deletion is the start of the text after it, which [move]
   maps there too. *)
let move_back s offset =
  if offset - s.delta >= s.old_suffix_start then Some (offset - s.delta)
  else if offset <= s.prefix then Some offset
  else None

(* The path a `file:` URI's path part spells: percent-escapes read, and a
   Windows drive letter's `/c:/...` written as `c:\...`. *)
let decode_path rest =
  let b = Buffer.create (String.length rest) in
  let hex c =
    match c with
    | '0' .. '9' -> Some (Char.code c - 48)
    | 'a' .. 'f' -> Some (Char.code c - 87)
    | 'A' .. 'F' -> Some (Char.code c - 55)
    | _ -> None
  in
  let n = String.length rest in
  let rec go i =
    if i < n then
      match (rest.[i], if i + 2 < n then (hex rest.[i + 1], hex rest.[i + 2]) else (None, None)) with
      | '%', (Some a, Some c) ->
          Buffer.add_char b (Char.chr ((a * 16) + c));
          go (i + 3)
      | c, _ ->
          Buffer.add_char b c;
          go (i + 1)
  in
  go 0;
  let path = Buffer.contents b in
  if Sys.win32 && String.length path >= 3 && path.[0] = '/' && path.[2] = ':' then
    String.map (function '/' -> '\\' | c -> c) (String.sub path 1 (String.length path - 1))
  else path

(* A `file:` URI and the path it names. Percent-escapes are read and written
   for every byte outside the unreserved set and `/`. A URI that names
   another machine, by a host other than `localhost`, names no path here. *)
let path_of_uri uri =
  let prefix = "file://" in
  if not (String.starts_with ~prefix uri) then None
  else
    let rest = String.sub uri (String.length prefix) (String.length uri - String.length prefix) in
    let host, path =
      match String.index_opt rest '/' with
      | Some i -> (String.sub rest 0 i, String.sub rest i (String.length rest - i))
      | None -> (rest, "")
    in
    if host = "" || String.lowercase_ascii host = "localhost" then Some (decode_path path) else None

(* The directories the editor named under another spelling than their real
   path, such as a directory reached through a symbolic link: each real path
   and the editor's spelling of it, longest real path first. A URI the server
   sends names a file under the editor's spelling, so the editor matches it to
   the document it opened. *)
let spellings : (string * string) list ref = ref []

let spell ~real ~editor =
  if real <> editor && not (List.mem_assoc real !spellings) then
    spellings :=
      List.sort (fun (a, _) (b, _) -> compare (String.length b) (String.length a)) ((real, editor) :: !spellings)

let respelled path =
  let under dir =
    path = dir
    || String.length path > String.length dir
       && String.starts_with ~prefix:dir path
       && (path.[String.length dir] = '/' || path.[String.length dir] = '\\')
  in
  match List.find_opt (fun (real, _) -> under real) !spellings with
  | Some (real, editor) -> editor ^ String.sub path (String.length real) (String.length path - String.length real)
  | None -> path

let uri_of_path path =
  let path = respelled path in
  let path = if Sys.win32 then "/" ^ String.map (function '\\' -> '/' | c -> c) path else path in
  let b = Buffer.create (String.length path + 8) in
  Buffer.add_string b "file://";
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' | '/' -> Buffer.add_char b c
      | ':' when Sys.win32 -> Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    path;
  Buffer.contents b

(* Reading a span back out of the source it points at.

   A span is only ever wrong by pointing somewhere, and the cheapest way to see
   where is to print the text between its two positions. [Cst.To_span_text] and
   [Sst.To_span_text] both do that, and they do it the same way, so the doing
   of it lives here rather than twice. This is to the span side what
   [Tree_graph] is to the structure side: the shared rendering, with the walk
   over a stage's own nodes left to that stage.

   That is not tidiness. The cut logic below has to respect UTF-8, and it got
   that wrong once already: an elision landing mid-character wrote invalid
   bytes into an expectation file. A second copy is a second place for that to
   come back. *)

type t = {
  source : string;
  out : Buffer.t;
}

let create source = { source; out = Buffer.create (1 lsl 16) }
let contents printer = Buffer.contents printer.out

(* Whitespace runs collapse so a node's text stays on its own line. *)
let squeeze text =
  let out = Buffer.create (String.length text) in
  let in_space = ref false in
  String.iter
    (fun c ->
      match c with
      | ' ' | '\t' | '\n' | '\r' ->
          if not !in_space then Buffer.add_char out ' ';
          in_space := true
      | c ->
          Buffer.add_char out c;
          in_space := false)
    text;
  String.trim (Buffer.contents out)

(* A UTF-8 continuation byte is the tail of a character that starts earlier, so
   a cut landing on one would split that character and put an invalid byte
   sequence in the expectation file. The same fact [Parse_error] uses to keep a
   caret from drifting, for the same reason: this file's business is positions
   in text that is not necessarily ASCII. *)
let is_continuation text i = Char.code text.[i] land 0xC0 = 0x80

(* Long spans are elided in the middle. Both ends are what a wrong span usually
   gets wrong -- it starts at the binder instead of the name, or stops before
   the `)` -- and keeping them whole would put a whole function body on one
   line. *)
let elide text =
  let limit = 56 and keep = 26 in
  let length = String.length text in
  if length <= limit then text
  else
    (* Back the head's cut off a continuation byte, and move the tail's cut
       forward off one, so both land between characters. Each moves at most
       three bytes, since no UTF-8 character is longer than four. *)
    let head = ref keep in
    while !head > 0 && is_continuation text !head do
      decr head
    done;
    let tail = ref (length - keep) in
    while !tail < length && is_continuation text !tail do
      incr tail
    done;
    String.sub text 0 !head ^ " … " ^ String.sub text !tail (length - !tail)

(* One node: its kind, indented by depth, and the source its span covers.

   A span that does not fit the source says so in the output rather than
   raising, because a dump that stops at the first bad span hides every one
   after it -- and the run that most wants this tool is the one where a span is
   wrong. *)
let line printer depth kind (span : Span.t) =
  let a = span.Span.start_.Lexing.pos_cnum
  and b = span.Span.end_.Lexing.pos_cnum in
  let text =
    if a >= 0 && b >= a && b <= String.length printer.source then
      elide (squeeze (String.sub printer.source a (b - a)))
    else "<INVALID SPAN>"
  in
  Buffer.add_string printer.out (String.make (depth * 2) ' ');
  Buffer.add_string printer.out kind;
  Buffer.add_string printer.out " | ";
  Buffer.add_string printer.out text;
  Buffer.add_char printer.out '\n'

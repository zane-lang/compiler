(* Where a node was written.

   Every node in [Nodes] carries one. The parser fills them from Menhir's
   [$loc], which is the pair of positions delimiting the production that built
   the node, so a span covers exactly the tokens the node was reduced from.

   It is also where a [Diagnostic.t] points, and its renderer draws a caret
   from the two positions. Keeping the pair on the node is what lets a pass
   that runs *after* the parse -- the statement check today, the desugaring and
   everything downstream of it later -- report against source the same way the
   parser does.

   Positions are byte offsets, not code points, because that is what indexing
   the source text needs; see [Cst.byte_positions]. *)
type t = {
  start_ : Lexing.position;
  end_ : Lexing.position;
}

(* Menhir's [$loc] is exactly this pair, so an action reads
   [Span.of_loc $loc]. *)
let of_loc ((start_, end_) : Lexing.position * Lexing.position) =
  { start_; end_ }

(* The span covering both, for a node built from parts whose own production
   does not span all of them. A verb-type suffix is the case that needs it: the
   suffix is parsed as `[ params ]` and only later applied to the return type
   written to its left, so the node's span runs from the return type's start to
   the suffix's end. *)
let join a b = { start_ = a.start_; end_ = b.end_ }

(* A span standing in for one that was never written. Only for nodes the parser
   synthesises rather than reduces -- there are none today, so nothing uses it
   yet; it exists so a later desugaring has something honest to put on a node
   with no source of its own, rather than borrowing a nearby node's span and
   reporting an error at the wrong place. *)
let none =
  let position =
    { Lexing.pos_fname = ""; pos_lnum = 0; pos_bol = 0; pos_cnum = -1 }
  in
  { start_ = position; end_ = position }

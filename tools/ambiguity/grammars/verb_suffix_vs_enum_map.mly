(* A slice of Zane's grammar around a conflict its unambiguity proof trips on,
   kept small enough to sweep the abstraction level over.

   HISTORICAL, AND KEPT ON PURPOSE. The real grammar no longer has the
   adjacency modelled below: the spec moved an enum map's entries from `[ ]` to
   `{ }`, so the entry list no longer shares a bracket with the verb-type
   suffixes of the map type, and the `[` lookahead below cannot arise there any
   more. This file is retained as a prover corpus case rather than as a mirror
   of the current parser -- what it demonstrates is a property of the
   abstraction (a lookahead set merged across contexts that the retained stack
   cannot separate), and that property is worth a standing test whether or not
   Zane's own grammar still exhibits it. Do not read the widths below as a
   claim about `lib/cst/parser.mly` today.

   The conflict: after `&Foo`, with `[` as the lookahead, the parser can

     - shift, starting a verb-type suffix, so the type is `&Foo[]`; or
     - reduce the empty suffix list, ending the type at `&Foo`, because the
       `[` opens an enum map whose map type has just finished.

   Menhir's explanation of the real automaton shows this is not two competing
   items meeting. State 27 holds exactly one item,

     type_expr -> AMPERSAND UIDENT loption_generics_ . list_verb_type_suffix_

   whose lookahead set has been merged across every context that reaches it,
   and `[` is in that set because one of those contexts is the enum map. The
   context that would separate the two readings sits below the retained stack,
   so the abstraction cannot see which reading it is in and lets both walk to
   acceptance.

   WHAT THIS FILE HAS TO GET RIGHT

   An earlier version of this slice had the same shape as the real grammar but
   narrower productions, and it proved at level 1 with no accepting pairs --
   useless as a stand-in. Width is the whole mechanism: the abstraction is
   exact for a reduction only while the reduction pops less than the retained
   stack, so a slice whose productions are narrower than the real ones resolves
   at a level the real grammar cannot reach.

   So the productions here are expanded to exactly the widths Menhir reports
   for the real ones, which means mirroring the `%inline` markers too --
   inlining is what flattens `&Foo` into a single four-symbol production rather
   than a chain of two-symbol ones.

     type_expr  -> AMPERSAND UIDENT loption_generics_ list_verb_type_suffix_
                                                                     (width 4)
     simple_decl -> UIDENT loption_generics_ DOT LIDENT type_expr
                    LBRACKET loption_..._enum_map_entry__ RBRACKET    (width 8)

   WHAT THAT TURNED OUT NOT TO BE ENOUGH FOR

   The widest reduction on the chain is the eight-symbol enum map, so exact
   resolution needs a retained stack of nine, and the prediction was that the
   accepting-pair count would hold through the low levels and fall to zero by
   level nine. Swept over levels 1 to 9, this grammar instead proves at level
   1, with six divergence sites and no accepting pair.

   So the conflict reproduces -- six sites means there really are stacks here
   offering two moves -- but the spurious acceptance does not. Matching the
   widths was necessary and is not sufficient.

   What the small grammar cannot supply is somewhere for an over-approximated
   goto to land. When a reduction pops past the retained stack the abstraction
   admits every goto edge, and the blind spot only becomes a false accepting
   pair if one of those edges leads to a state from which the rest of the
   sentence still parses. The real grammar has hundreds of states and many
   declaration forms, so it does; a grammar with nine productions has nowhere
   for the slop to go, and both branches simply die.

   That makes this file a reduced case of the conflict but not of the proof
   failure, and it is the reason a slice small enough to sweep cannot measure
   the level at which the real blind spot closes. It is kept because the
   negative result is worth keeping: it rules out width alone as the
   explanation, and it says a useful slice would have to be large enough to
   give the abstraction room to be wrong in, which is most of the way back to
   sweeping the real grammar.

   Nothing here has semantic actions or precedence declarations: the question
   is about the shape of the automaton, and Zane's precedences do not reach
   this conflict, since the empty production carries no terminal to take a
   precedence from. *)

%token <string> UIDENT
%token <string> LIDENT
%token AMPERSAND   "&"
%token LBRACKET    "["
%token RBRACKET    "]"
%token LESS        "<"
%token GREATER     ">"
%token COMMA       ","
%token DOT         "."
%token SEMICOLON   ";"
%token LPAREN      "("
%token RPAREN      ")"
%token THICK_ARROW "=>"
%token EOF         "<eof>"

%start <unit> main

%%

main: decls=list(decl) EOF { ignore decls }

decl: value=simple_decl ";" { ignore value }

(* Both alternatives are inlined away into `simple_decl` in the real grammar,
   which is what makes the enum map eight symbols wide rather than a shorter
   production over a `named_type_expr` nonterminal. *)
%inline generics: "<" args=separated_nonempty_list(",", UIDENT) ">" {
    ignore args
  }

%inline named_type_expr: name=UIDENT generics=loption(generics) {
    ignore (name, generics)
  }

simple_decl:
  (* A verb declaration: the return type is followed by the verb's name. Six
     symbols, matching the real `body_decl`. *)
  | ret_type=type_expr name=LIDENT "(" params=loption(param_list) ")"
    body=body {
      ignore (ret_type, name, params, body)
    }
  (* An enum map: the map type is followed by the bracketed entry list. This
     alternative is the whole reason the conflict exists -- it is the only
     context in which a completed type is followed by `[` -- and its width is
     what puts the resolving level out of reach of a narrow window. *)
  | enum=named_type_expr "." property=LIDENT map_type=type_expr
    "[" entries=loption(entry_list) "]" {
      ignore (enum, property, map_type, entries)
    }

param_list: params=separated_nonempty_list(",", LIDENT) { ignore params }

entry_list: entries=separated_nonempty_list(",", LIDENT) { ignore entries }

body: "=>" value=LIDENT { ignore value }

%inline type_base:
  | value=named_type_expr { ignore value }
  | "(" value=type_expr ")" { ignore value }

%inline type_atom:
  | value=type_base { ignore value }
  | "&" value=type_base { ignore value }

%inline verb_type_suffix: "[" params=loption(param_type_list) "]" {
    ignore params
  }

param_type_list: params=separated_nonempty_list(",", type_expr) {
    ignore params
  }

type_expr: atom=type_atom suffixes=list(verb_type_suffix) {
    ignore (atom, suffixes)
  }

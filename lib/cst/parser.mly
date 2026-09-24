%{
(* The tokens, the precedence table and the productions are below. Everything
   their actions call lives beside this file: [Parser_nodes] for the
   spanned-node constructors, [Parser_actions] for the actions that build or
   reject a larger node, and [Statement_shape] for where a statement ends and
   whether it was spelled to match. *)
module Span = Source.Span
open Parser_nodes
open Parser_actions
open Statement_shape
%}

(*****************************)
(*     token definitions     *)
(*****************************)
%token <string> INT "43"
%token <string> FLOAT "8.647"
%token <string> STRING "\"john\""
%token <string> LIDENT "length"
%token <string> UIDENT "Int"

%token LPAREN      "("
%token RPAREN      ")"
%token COMMA       ","
%token LCURLY      "{"
%token RCURLY      "}"
%token LBRACKET    "["
%token RBRACKET    "]"
%token COLON       ":"
%token SEMICOLON   ";"
%token DOT         "."
%token EQUAL       "="
%token PLUS        "+"
%token MINUS       "-"
%token STAR        "*"
%token SLASH       "/"
%token DOLLAR      "$"
%token HASH        "#"
%token AMPERSAND   "&"
%token AT          "@"
%token EXCL        "!"
%token QSTNMARK    "?"
%token QSTNQSTN    "??"
%token TILDE       "~"
%token THICK_ARROW "=>"
%token EQEQ        "=="
%token NOTEQ       "~="
%token LESSEQ      "<="
%token MOREEQ      ">="
%token LESS        "<"
%token MORE        ">"

(* The loose forms of operators.md §3.1: one token each, so the `'` must touch
   the operator it prefixes. *)
%token LOOSE_STAR   "'*"
%token LOOSE_SLASH  "'/"
%token LOOSE_PLUS   "'+"
%token LOOSE_MINUS  "'-"
%token LOOSE_EQEQ   "'=="
%token LOOSE_NOTEQ  "'~="
%token LOOSE_LESSEQ "'<="
%token LOOSE_MOREEQ "'>="
%token LOOSE_LESS   "'<"
%token LOOSE_MORE   "'>"

%token LTYPE       "type"
%token ALIAS       "alias"
%token UTYPE       "Type"
%token NUMBER      "Number"
%token STRUCT      "struct"
%token VARIANT     "variant"
%token ENUM        "enum"
%token PACKAGE     "package"
%token IMPORT      "import"
%token AS          "as"
%token IMPLICIT    "implicit"
%token INIT        "init"
%token MATCH       "match"
%token SPAWN       "spawn"
%token TRUE        "true"
%token FALSE       "false"
%token THIS        "this"
%token MUT         "mut"
%token ABORT       "abort"
%token RETURN      "return"
%token RESOLVE     "resolve"
%token EOF          "<eof>"

(* The precedence table of operators.md §3, loosest first -- which is Menhir's
   order, so the declarations below read as that table upside down. The numbered
   lines are that table exactly, and are every operator the language has. The
   unnumbered ones carry no level in the spec because they are not operators:
   they are abort handling and the postfix chain, placed where each has to be
   for the chain to thread. *)
%right THICK_ARROW
%left LOOSE_EQEQ LOOSE_NOTEQ LOOSE_LESSEQ LOOSE_MOREEQ LOOSE_LESS LOOSE_MORE  /* 7 */
%left LOOSE_PLUS LOOSE_MINUS                    /* 6 */
%left LOOSE_STAR LOOSE_SLASH                    /* 5 -- the loose tier, §3.1 */
%left EQEQ NOTEQ LESSEQ MOREEQ LESS MORE        /* 4 -- comparisons */
%left PLUS MINUS                                /* 3 */
%left STAR SLASH                                /* 2 */
%nonassoc QSTNMARK QSTNQSTN                    /* abort handling */
%nonassoc TILDE AMPERSAND                       /* 1 -- prefix ~, and & */
%left DOT                                       /* field access */
%left LBRACKET                                  /* subscript */
%left LPAREN                                    /* function application */

%start <Nodes.Package.t> package

(*************************)
(*     grammar rules     *)
(*************************)
%%

(* A package-scope declaration is not a statement and carries no terminator of
   its own: it ends where its own body, bracket, or expression ends. A `;`
   there would belong to nothing, since nothing follows a declaration that a
   terminator would have to be told apart from -- the next declaration starts
   with its own return type, binder, or keyword.

   `package` and `import` are the exception, and [header_decl] below says why.

   Inside a body the same declaration is a statement and does take `;`, unless
   it ends in a `}`; see [stat]. That is the one place the two levels differ in
   how a declaration is spelled. *)
package:
  | decls=list(top_decl) EOF {
      ({ Nodes.Package.decls; span = Span.of_loc $loc } : Nodes.Package.t)
    }

top_decl:
  | value=block_decl { value }
  | value=simple_decl { value }
  | value=header_decl ";" { value }

(* An identifier, carrying where it was written.

   Every name position in the grammar goes through one of these rather than
   reading the token directly, so no production can build a node with a name
   the reader cannot be pointed at. Both are `%inline`, so they expand back
   into their caller and the automaton is the same one the bare tokens built --
   the conflict census in docs/ambiguity.md is unchanged by their introduction.

   [import_member] is the one name position that does not use them: it is
   already a record whose own span is exactly the name. *)
%inline lname:
  | text=LIDENT { mk_name $loc text }

%inline uname:
  | text=UIDENT { mk_name $loc text }

(* The member of an intrinsic namespace that names a type. `Number` is a
   keyword, since it is the concept a number parameter is declared with, but
   the concept type of a numeric literal is spelled with the same word:
   `@concepts$Number` (syntax.md §2.8). After `@pkg$` the keyword can mean
   nothing else, so it is read back as the name it spells.

   Not `%inline`, unlike [uname]: inlined, each production that writes an
   intrinsic type would be written twice, once per spelling, and so would
   every conflict in docs/ambiguity.md that involves one. As a nonterminal of
   its own, the census only renames the symbol. *)
intrinsic_uname:
  | name=uname { name }
  | "Number" { mk_name $loc "Number" }

%inline func_lambda(body_form):
  | ret_type=ret_type "(" params=separated_list(COMMA, param) ")" body=body_form {
      ({ Nodes.Func_lambda.params; ret_type; body; span = Span.of_loc $loc }
        : Nodes.Func_lambda.t)
    }

%inline meth_lambda(body_form):
  | ret_type=ret_type "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body_form {
      ({
        Nodes.Meth_lambda.this_type;
        params;
        ret_type;
        is_mut;
        body;
        span = Span.of_loc $loc;
      } : Nodes.Meth_lambda.t)
    }

%inline concept:
  | "Type" {
      concept $loc Nodes.Concept.Type
    }
  | "Number" {
      concept $loc Nodes.Concept.Number
    }

%inline generic_arg:
  | type_expr=type_expr {
      generic_arg $loc (Nodes.Generic_arg.Type type_expr)
    }
  | number=INT {
      generic_arg $loc (Nodes.Generic_arg.Number number)
    }
  | name=lname {
      generic_arg $loc (Nodes.Generic_arg.NumberRef name)
    }
  | param=param {
      generic_arg $loc (Nodes.Generic_arg.Inferred param)
    }

%inline generics:
  | "<" generics=separated_nonempty_list(",", generic_arg) ">" {
      generics
    }

%inline named_type_expr:
  | name=name_type generics=loption(generics) {
      type_expr $loc (Nodes.Type_expr.Path { name; generics })
    }

%inline type_base:
  | type_=named_type_expr {
      type_
    }
  | "(" type_=type_expr ")" {
      type_expr $loc (Nodes.Type_expr.Parenthesized type_)
    }

%inline type_atom:
  | type_=type_base {
      type_
    }
  | "&" type_=type_base {
      type_expr $loc (Nodes.Type_expr.Guest type_)
    }

(* A suffix is parsed as its own bracket group and only then applied to the
   return type written to its left, so neither the suffix's `$loc` nor the
   return type's span covers the node it builds. The span runs from the return
   type's start to the suffix's end, which is what [Span.join] is for. *)
%inline verb_type_suffix:
  | "[" params=separated_list(",", param_type) "]" {
      let suffix_span = Span.of_loc $loc in
      fun (ret_type : Nodes.Ret_type.t) ->
        let span = Span.join ret_type.Nodes.Ret_type.span suffix_span in
        ({
          Nodes.Type_expr.span;
          node =
            Nodes.Type_expr.Verb
              { Nodes.Verb_type.span; node = Nodes.Verb_type.Func { params; ret_type } };
        } : Nodes.Type_expr.t)
    }
  | "[" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param_type)))
    "]" is_mut=boption(MUT) {
      let suffix_span = Span.of_loc $loc in
      fun (ret_type : Nodes.Ret_type.t) ->
        let span = Span.join ret_type.Nodes.Ret_type.span suffix_span in
        ({
          Nodes.Type_expr.span;
          node =
            Nodes.Type_expr.Verb
              {
                Nodes.Verb_type.span;
                node =
                  Nodes.Verb_type.Meth { this_type; params; ret_type; is_mut };
              };
        } : Nodes.Type_expr.t)
    }

(* Verb-type brackets bind more tightly than an unparenthesized abort return:
   `Int ? Error[]` is `Int ? (Error[])`. To make the abort return feed the
   verb type instead, group it explicitly: `(Int ? Error)[]`. *)
(* The [Ret_type.Safe] cast introduces no syntax of its own -- it is the type
   to its left, read as a return type -- so it takes that type's span. *)
type_expr:
  | atom=type_atom suffixes=list(verb_type_suffix) {
      List.fold_left
        (fun (type_ : Nodes.Type_expr.t) suffix ->
          suffix
            {
              Nodes.Ret_type.node = Nodes.Ret_type.Safe type_;
              span = type_.Nodes.Type_expr.span;
            })
        atom suffixes
    }
  | open_=LPAREN ret_type=abort_ret_type close=RPAREN
    first=verb_type_suffix rest=list(verb_type_suffix) {
      ignore open_;
      ignore close;
      let parenthesized =
        ({
          Nodes.Ret_type.node = Nodes.Ret_type.Parenthesized ret_type;
          span = Span.join (Span.of_loc $loc(open_)) (Span.of_loc $loc(close));
        } : Nodes.Ret_type.t)
      in
      let type_ = first parenthesized in
      List.fold_left
        (fun (type_ : Nodes.Type_expr.t) suffix ->
          suffix
            {
              Nodes.Ret_type.node = Nodes.Ret_type.Safe type_;
              span = type_.Nodes.Type_expr.span;
            })
        type_ rest
    }

%inline generic_param:
  | name=uname concept_=UTYPE {
      ignore concept_;
      ({
        Nodes.Generic_param.name;
        type_ = concept $loc(concept_) Nodes.Concept.Type;
        span = Span.of_loc $loc;
      } : Nodes.Generic_param.t)
    }
  | name=lname concept_=NUMBER {
      ignore concept_;
      ({
        Nodes.Generic_param.name;
        type_ = concept $loc(concept_) Nodes.Concept.Number;
        span = Span.of_loc $loc;
      } : Nodes.Generic_param.t)
    }

%inline constructor_name:
  | type_=name_type member=ioption(preceded(".", lname)) {
      ({ Nodes.Constructor_name.type_; member; span = Span.of_loc $loc }
        : Nodes.Constructor_name.t)
    }

%inline field_arg:
  | name=lname value=ioption(preceded("=", expr)) {
      ({ Nodes.Field_arg.name; value; span = Span.of_loc $loc }
        : Nodes.Field_arg.t)
    }

(* A braced run of statements handed to a call and run by the callee. It is not
   an expression: it may be written only where a call takes arguments, which is
   what keeps a block from being stored, returned, or bound to a symbol. *)
%inline block_arg:
  | "{" stats=list(stat) "}" {
      call_arg $loc (Nodes.Call_arg.Block stats)
    }

(* A `{ }` body of `;`-terminated `key, value` entries. It stands in a value
   position behind no introducing token, which is also true of a block
   argument, so in argument position the two can meet. What tells them apart is
   the mark after the first expression: a `,` opens an entry's value, a `;`
   ends a statement. A literal is never empty, so a bare `{}` is a block. *)
%inline map_entry:
  | key=expr "," value=expr {
      (key, value)
    }

map_lit:
  | "{" entries=nonempty_list(terminated(map_entry, ";")) "}" {
      expr $loc (Nodes.Expr.MapLit entries)
    }

%inline call_arg:
  | value=expr { call_arg $loc (Nodes.Call_arg.Value value) }
  | block=block_arg { block }

%inline call_args:
  | args=separated_list(",", call_arg) { args }

(* The empty positional list is a production of its own rather than a
   [call_args] that happens to be empty, so that the non-empty list is written
   once and both spellings of a constructor call -- with a trailing argument
   and without -- read it through the same production. Written as one list
   either way, the parser has to pick between them while reducing the list, at
   the `)`; written like this it shifts the `)` and decides on the token that
   actually decides, the `{` or its absence. The state count is the same
   twelve; what changes is which fork they are, and this one is the fork
   docs/ambiguity.md already carries for a call's trailing argument against an
   enclosing brace. *)
%inline positional_constructor_args:
  | "(" ")" {
      constructor_args $loc (Nodes.Constructor_args.Positional [])
    }
  | "(" args=separated_nonempty_list(",", call_arg) ")" {
      constructor_args $loc (Nodes.Constructor_args.Positional args)
    }

(* The field form closes on its own `}`, so a statement ending in one is closed
   by it; see [stat]. It is named apart from the positional form for that
   reason alone. *)
%inline field_constructor_args:
  | "{" args=list(terminated(field_arg, ";")) "}" {
      constructor_args $loc (Nodes.Constructor_args.Fields args)
    }

%inline constructor_args:
  | args=positional_constructor_args { args }
  | args=field_constructor_args { args }

(* A named type after the binder either is the field's own type or introduces an
   inferred type parameter. Constructor fields and parameters spell that pair the
   same way, so both take it from here. *)
%inline field_type:
  | type_=type_expr {
      param_type $loc (Nodes.Param_type.Concrete type_)
    }
  | name=uname concept_=UTYPE {
      ignore concept_;
      param_type $loc
        (Nodes.Param_type.InferredType
           { name; concept = concept $loc(concept_) Nodes.Concept.Type })
    }

%inline constructor_field:
  | name=lname type_=field_type default=ioption(preceded("=", expr)) {
      ({ Nodes.Constructor_field.name; type_; default; span = Span.of_loc $loc }
        : Nodes.Constructor_field.t)
    }
  (* The field's type is not written: it is the constructor being called, read
     as a type. It stands for the *type* part of that name and not the whole of
     it -- `x Span.point(0)` declares a field of type `Span`, so the type node
     takes the span of `Span` rather than of `Span.point`, which is wider than
     anything it represents.

     The default is the call, so it runs from the constructor name through the
     arguments. The production's own span would start at the field binder,
     which is not part of the call. *)
  | name=lname constructor=constructor_name args=constructor_args {
      let type_span =
        constructor.Nodes.Constructor_name.type_.Nodes.Name_type.span
      in
      let type_ =
        ({
          Nodes.Type_expr.node =
            Nodes.Type_expr.Path
              { name = constructor.Nodes.Constructor_name.type_; generics = [] };
          span = type_span;
        } : Nodes.Type_expr.t)
      in
      let default =
        constructor_expr ($startpos(constructor), $endpos(args)) constructor args
      in
      ({
        Nodes.Constructor_field.name;
        type_ =
          { Nodes.Param_type.node = Nodes.Param_type.Concrete type_; span = type_span };
        default = Some default;
        span = Span.of_loc $loc;
      } : Nodes.Constructor_field.t)
    }

%inline constructor_params:
  | "(" params=separated_list(",", param) ")" {
      constructor_params $loc (Nodes.Constructor_params.Positional params)
    }
  | "{" fields=list(terminated(constructor_field, ";")) "}" {
      constructor_params $loc (Nodes.Constructor_params.Fields fields)
    }

%inline constructor_decl_name:
  | type_=named_type_expr member=ioption(preceded(".", lname)) {
      (type_, member)
    }

%inline enum_map_entry:
  | member=lname "=" value=expr {
      (member, value)
    }

(* An enum map's entries are a `{ }` body, so they no longer share a bracket
   with the verb-type suffixes of the property's own type. The type is an
   ordinary [type_expr] again and the entries follow it, which is what the
   earlier shift-every-group-then-classify shape existed to work around: with
   `[ ]` on both, whether a group was a suffix or the entry list depended on
   what came after its closing bracket. `{ }` answers that at the opening
   bracket, so the run of groups, the two rejected orders, and the classifier
   carrying a group's kind are all gone. *)
%inline enum_map_body:
  | "{" entries=list(terminated(enum_map_entry, ";")) "}" {
      entries
    }

(* A name taken from a package, in either casing class. *)
%inline import_member:
  | name=LIDENT {
      ({ Nodes.Import_member.name; is_type = false; span = Span.of_loc $loc }
        : Nodes.Import_member.t)
    }
  | name=UIDENT {
      ({ Nodes.Import_member.name; is_type = true; span = Span.of_loc $loc }
        : Nodes.Import_member.t)
    }

(* The four import forms. What the file writes at the use site is what the
   import wrote after `import`, so each form is its own production rather than
   one shape with optional parts.

   `import pkg$` takes everything past the separator and so ends on the `$`
   itself. What follows the `$` is settled by the terminator [header_decl]
   requires, not by reading on: see there. *)
import_decl:
  | IMPORT package=lname alias=ioption(preceded(AS, lname)) {
      import $loc (Nodes.Import.Package { package; alias })
    }
  | IMPORT package=lname "$" member=import_member
    alias=ioption(preceded(AS, import_member)) {
      import $loc
        (Nodes.Import.Member {
          package;
          member;
          alias = Option.map (import_alias member) alias;
        })
    }
  | IMPORT package=lname "$"
    "[" members=separated_nonempty_list(",", import_member) "]" {
      import $loc (Nodes.Import.Members { package; members })
    }
  | IMPORT package=lname "$" {
      import $loc (Nodes.Import.All { package })
    }

(* The two declarations that end in a bare name, and the only two that carry a
   terminator at package scope.

   Every other declaration ends in a body, a bracket, or an expression, so the
   declaration after it starts where its own shape says it stopped. These two
   stop at a name, and `import pkg$` stops before one: after the `$` a name is
   either the member being imported or the first token of the next
   declaration, and nothing in either shape tells the reader -- or the parser
   -- which. Carrying both readings until one fails to be a declaration is not
   enough, because both can succeed: `import core$ main Unit() { }` is a
   whole-package import followed by a lambda-valued declaration, and also a
   member import of `main` followed by a constructor declaration for `Unit`.
   That was an ambiguity the search found, not a fork that resolves.

   So the `;` is required here and the grammar carries the rule, which is
   where docs/ambiguity.md says a rule belongs when the grammar can hold it. A
   terminator after the `$` leaves the name nowhere to go but the next
   declaration, and the same `;` is what ends `package pkg` and the three
   import forms that do end in a name. *)
header_decl:
  | PACKAGE name=lname {
      decl $loc (Nodes.Decl.Package name)
    }
  | value=import_decl {
      decl $loc (Nodes.Decl.Import value)
    }

(* A verb declaration and the declaration wrapping it span the same tokens:
   there is nothing in a `Decl.Verb` but the verb. Both take `$loc`. *)
body_decl(body_form):
  | ret_type=ret_type name=lname "(" params=separated_list(",", param) ")" body=body_form {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Func { name; params; ret_type; body })))
    }
  | ret_type=ret_type name=lname "(" THIS this_type=type_expr
    params=loption(preceded(",", separated_nonempty_list(",", param)))
    ")" is_mut=boption(MUT) body=body_form {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Meth {
                name;
                this_type;
                params;
                ret_type;
                is_mut;
                body;
              })))
    }
  | type_=constructor_decl_name params=constructor_params body=body_form {
      let type_, member = type_ in
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Constructor {
                type_;
                member;
                params;
                body;
                is_implicit = false;
              })))
    }
  (* The parameter list is `( param )`, brackets included, so its node spans
     them: the sole parameter's own span would leave the parentheses out of the
     thing that is precisely a parenthesized list. *)
  | IMPLICIT type_=named_type_expr open_=LPAREN param=param close=RPAREN
    body=body_form {
      ignore open_;
      ignore close;
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Constructor {
                type_;
                member = None;
                params =
                  constructor_params
                    ($startpos(open_), $endpos(close))
                    (Nodes.Constructor_params.Positional [param]);
                body;
                is_implicit = true;
              })))
    }
  | ret_type=ret_type op=operator "(" params=separated_list(",", param) ")" body=body_form {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc (Nodes.Verb_decl.Op { op; params; ret_type; body })))
    }
  | ret_type=ret_type "~" "(" params=separated_list(",", param) ")" body=body_form {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc (Nodes.Verb_decl.Flip { params; ret_type; body })))
    }

(* Ends in a `{ }` block, which closes the construct on its own. *)
type_decl(value_form):
  | "type" name=uname params=loption(delimited("<", separated_nonempty_list(",", generic_param), ">"))
    "=" value=value_form {
      decl $loc (Nodes.Decl.Type { name; params; value })
    }
  | "alias" name=uname params=loption(delimited("<", separated_nonempty_list(",", generic_param), ">"))
    "=" value=value_form {
      decl $loc (Nodes.Decl.Alias { name; params; value })
    }

block_decl:
  | value=body_decl(block_body) { value }
  | value=type_decl(moulded_value) { value }

(* Every declaration that is not closed by its own `{ }` body. At package scope
   none of them takes a terminator; in a body each is a statement closed by a
   `;`, and the ones that can end in a brace are written again in
   [simple_decl_braced] for the statement that closes on it instead. *)
simple_decl:
  | value=body_decl(shorthand_body) { value }
  | value=type_decl(raw_value) { value }
  | value=type_decl(enum_moulded_value) { value }
  | name=lname type_=type_expr "=" value=expr {
      decl $loc (Nodes.Decl.Var { name; type_; value })
    }
  | name=lname constructor=constructor_name args=positional_constructor_args {
      decl $loc
        (Nodes.Decl.VarShorthand { name; constructor; args; trailing = false })
    }
  | value=fields_var_shorthand { value }
  | value=trailing_var_shorthand { value }
  | name=lname func_lambda=func_lambda(body) {
      decl $loc
        (Nodes.Decl.Var {
          name;
          type_ = Nodes.func_type_of_lambda func_lambda;
          value = expr $loc(func_lambda) (Nodes.Expr.FuncLambda func_lambda);
        })
    }
  | name=lname meth_lambda=meth_lambda(body) {
      decl $loc
        (Nodes.Decl.Var {
          name;
          type_ = Nodes.meth_type_of_lambda meth_lambda;
          value = expr $loc(meth_lambda) (Nodes.Expr.MethLambda meth_lambda);
        })
    }
  | value=enum_map_decl { value }
  | "(" THIS this_type=type_expr ")"
    "[" params=separated_list(",", param) "]" "=>" value=expr {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Subscript { this_type; params; value })))
    }

(* The declarations a statement can end on a `}` with, and so the ones that
   take no terminator there; see [stat]. At package scope no declaration takes
   one, so [top_decl] reads [simple_decl] and never needs these. *)
simple_decl_braced:
  | value=body_decl(shorthand_body_braced) { value }
  | name=lname type_=type_expr "=" value=expr_braced {
      decl $loc (Nodes.Decl.Var { name; type_; value })
    }
  | value=fields_var_shorthand { value }
  | value=trailing_var_shorthand { value }
  | name=lname func_lambda=func_lambda(body_braced) {
      decl $loc
        (Nodes.Decl.Var {
          name;
          type_ = Nodes.func_type_of_lambda func_lambda;
          value = expr $loc(func_lambda) (Nodes.Expr.FuncLambda func_lambda);
        })
    }
  | name=lname meth_lambda=meth_lambda(body_braced) {
      decl $loc
        (Nodes.Decl.Var {
          name;
          type_ = Nodes.meth_type_of_lambda meth_lambda;
          value = expr $loc(meth_lambda) (Nodes.Expr.MethLambda meth_lambda);
        })
    }
  | value=enum_map_decl { value }
  | "(" THIS this_type=type_expr ")"
    "[" params=separated_list(",", param) "]" "=>" value=expr_braced {
      decl $loc
        (Nodes.Decl.Verb
           (verb_decl $loc
              (Nodes.Verb_decl.Subscript { this_type; params; value })))
    }

fields_var_shorthand:
  | name=lname constructor=constructor_name args=field_constructor_args {
      decl $loc
        (Nodes.Decl.VarShorthand { name; constructor; args; trailing = false })
    }

(* The same instantiation with the call's last argument trailing, under the
   same restriction the call itself is under: what stays inside the `( )` may
   not be empty, or `name Foo() { ... }` would read both as this and as the
   lambda-variable shorthand in [simple_decl]. *)
trailing_var_shorthand:
  | name=lname constructor=constructor_name
    open_=LPAREN args=separated_nonempty_list(",", call_arg) RPAREN
    tail=trailing_arg {
      ignore open_;
      decl $loc
        (Nodes.Decl.VarShorthand {
          name;
          constructor;
          (* The arguments run from the `(` through the trailing argument. The
             production's own span would start at the binder and the
             constructor name, neither of which is an argument. *)
          args =
            constructor_args
              ($startpos(open_), $endpos(tail))
              (Nodes.Constructor_args.Positional (args @ tail));
          trailing = true;
        })
    }

(* Its entries are a `{ }` body, so it always closes on a `}`. *)
enum_map_decl:
  | enum=named_type_expr "." property=lname type_=type_expr
    entries=enum_map_body {
      decl $loc (Nodes.Decl.EnumMap { enum; property; type_; entries })
    }

%inline moulded_value:
  | value=moulded(braced_mould) {
      type_or_moulded $loc (Nodes.Type_or_moulded.Moulded value)
    }

%inline enum_moulded_value:
  | value=moulded(enum_mould) {
      type_or_moulded $loc (Nodes.Type_or_moulded.Moulded value)
    }

%inline raw_value:
  | value=type_expr {
      type_or_moulded $loc (Nodes.Type_or_moulded.Raw value)
    }

(* The moulds that close on a brace. A declaration ending in one is closed by
   it and takes no terminator, which is why they and the peer mould below are
   reached through different declaration rules. *)
%inline braced_mould:
  | STRUCT "{" fields=list(body_field) "}" {
      mould $loc (Nodes.Mould.Struct fields)
    }
  | VARIANT "{" fields=list(body_field) "}" {
      mould $loc (Nodes.Mould.Variant fields)
    }

(* The peer mould's contents are a flat list of names, so it takes `[ ]` and
   closes on a `]`. Which delimiter a mould uses is decided by its contents,
   and only a brace ends a statement -- so a declaration cast from this one is
   terminated like any other that does not end in a brace. *)
%inline enum_mould:
  | ENUM "[" members=separated_nonempty_list(",", lname) "]" {
      mould $loc (Nodes.Mould.Enum members)
    }

(* The value axis is written by the absence of a `#`, so it has no tokens of
   its own; it takes the mould's span, which is what a reader would be pointed
   at anyway. The reference axis takes the `#`. *)
%inline moulded(mould_form):
  | mould=mould_form {
      ({
        Nodes.Moulded.mould;
        axis = type_axis $loc(mould) Nodes.Type_axis.Value;
        span = Span.of_loc $loc;
      } : Nodes.Moulded.t)
    }
  | hash=HASH mould=mould_form {
      ignore hash;
      ({
        Nodes.Moulded.mould;
        axis = type_axis $loc(hash) Nodes.Type_axis.Reference;
        span = Span.of_loc $loc;
      } : Nodes.Moulded.t)
    }

%inline body_field:
  | name=lname type_=type_expr ";" {
      ({ Nodes.Body_field.name; type_; span = Span.of_loc $loc }
        : Nodes.Body_field.t)
    }

block_body:
  | "{" stats=list(stat) "}" {
      body $loc (Nodes.Body.Longhand stats)
    }

shorthand_body:
  | "=>" value=expr {
      body $loc (Nodes.Body.Shorthand value)
    }

body:
  | value=block_body { value }
  | value=shorthand_body { value }

(* A body that closes on a `}`: its own block, or a shorthand whose expression
   does. See [expr_braced]. *)
shorthand_body_braced:
  | "=>" value=expr_braced {
      body $loc (Nodes.Body.Shorthand value)
    }

body_braced:
  | value=block_body { value }
  | value=shorthand_body_braced { value }

ret_type:
  | value=type_expr {
      ret_type $loc (Nodes.Ret_type.Safe value)
    }
  | value=abort_ret_type {
      value
    }

abort_ret_type:
  | ok=type_expr "?" abort=type_expr {
      ret_type $loc (Nodes.Ret_type.Abort { ok; abort })
    }

%inline meth_part:
  | is_mut=mut_marker name=primary {
      (is_mut, name)
    }

%inline mut_marker:
  | ":" { false }
  | "!" { true }

(* At most one of a call's arguments may trail its closing `)`, where it still
   reads as the last argument. Only a `{ }` may take the position -- a block or
   a map literal -- because `{` is the one opening bracket that cannot also be
   read as a postfix on what precedes it: a trailing `[ ]` would collide with
   the subscript syntax. The two spellings are the same call, so the
   productions below take the tail as a parameter and build one node, recording
   only whether the argument was written outside the `)`, since that decides
   where the statement ends.

   A constructor call takes the same tail, but not through this rule: its
   callee is a [constructor_name] rather than an [app], so it is written out
   in [block_call] instead of being parameterized here. *)
%inline no_trailing_arg:
  | { ([] : Nodes.Call_arg.t list) }

%inline trailing_arg:
  | block=block_arg { [ block ] }
  | lit=map_lit { [ call_arg $loc (Nodes.Call_arg.Value lit) ] }

(* These build a function of the abort handler, because the handler is written
   to the call's right and reaches it through [attach_abort_handle]. The span
   captured here is the call's own -- through the `)` or the trailing argument,
   without the handler. The handler extends the enclosing [Expr], which is
   where [attach_abort_handle] re-spans. *)
computed_call(trailer):
  | receiver=func_callee "(" args=call_args ")" tail=trailer {
      let span = Span.of_loc $loc in
      fun abort_handle ->
        ({
          Nodes.Verb_call.span;
          node =
            Nodes.Verb_call.Func {
              callee = receiver;
              args = args @ tail;
              abort_handle;
              trailing = tail <> [];
            };
        } : Nodes.Verb_call.t)
    }
  | receiver=app part=meth_part "(" args=call_args ")" tail=trailer {
      let is_mut, callee = part in
      let span = Span.of_loc $loc in
      fun abort_handle ->
        ({
          Nodes.Verb_call.span;
          node =
            Nodes.Verb_call.Meth {
              callee;
              this = receiver;
              args = args @ tail;
              abort_handle;
              is_mut;
              trailing = tail <> [];
            };
        } : Nodes.Verb_call.t)
    }

%inline verb_call:
  | call=unbraced_verb_call { call }
  | call=braced_verb_call { call }

(* The [verb_call]s that close on a `)`, and so the ones a postfix may follow. *)
unbraced_verb_call:
  | call=computed_call(no_trailing_arg) { call }
  | name=constructor_name args=positional_constructor_args {
      let span = Span.of_loc $loc in
      fun abort_handle ->
        ({
          Nodes.Verb_call.span;
          node =
            Nodes.Verb_call.Constructor
              { name; args; abort_handle; trailing = false };
        } : Nodes.Verb_call.t)
    }

(* The one [verb_call] that closes on a `}`: a constructor call by fields. Like
   a [block_call] it is an expression rather than a postfix base (see
   [app_braced]). *)
braced_verb_call:
  | name=constructor_name args=field_constructor_args {
      let span = Span.of_loc $loc in
      fun abort_handle ->
        ({
          Nodes.Verb_call.span;
          node =
            Nodes.Verb_call.Constructor
              { name; args; abort_handle; trailing = false };
        } : Nodes.Verb_call.t)
    }

(* A call closed by a trailing block. It is an expression rather than a postfix
   base, so a further postfix reaches what such a call produces only through
   parentheses. `spawn` takes a bare [verb_call] and so cannot reach one at all,
   which is where "a verb declaring a block parameter is never spawned" falls
   out of the grammar rather than being written as a rule. *)
block_call:
  | call=computed_call(trailing_arg) { call }
  (* A constructor call trails its last argument the same way, with two
     restrictions the casing rule puts on it and on nothing else.

     Only the positional form takes a tail: trailing elides the `)`, and the
     field form has none to elide -- it already closes on the `}` of its own
     field body.

     And what stays inside the `( )` may not be empty. `Foo() { ... }` is a
     nullary lambda literal whose return type is `Foo` (syntax.md §3.8), and
     in statement position a constructor declaration as well; both are written
     with an upper-case name in front of an empty bracket and a `{ }`, which
     is exactly the trailing form's own shape. A lower-case callee has no such
     reading, which is why `do() { ... }` is unambiguous and `Foo() { ... }`
     is not. A constructor call whose only argument is a block writes it
     inside the list. See docs/spec-divergences.md. *)
  | name=constructor_name
    open_=LPAREN args=separated_nonempty_list(",", call_arg) RPAREN
    tail=trailing_arg {
      ignore open_;
      let span = Span.of_loc $loc in
      (* As above: the call spans the whole production, its arguments only the
         `( )` list and the trailing argument -- not the callee. *)
      let args_span = ($startpos(open_), $endpos(tail)) in
      fun abort_handle ->
        ({
          Nodes.Verb_call.span;
          node =
            Nodes.Verb_call.Constructor {
              name;
              args =
                constructor_args args_span
                  (Nodes.Constructor_args.Positional (args @ tail));
              abort_handle;
              trailing = true;
            };
        } : Nodes.Verb_call.t)
    }

(* The operators a program may declare: the primitive set of operators.md
   §2.1, which is "implementable and define[s] the operator surface area".

   The five the use sites below also admit -- `-`, `~=`, `>`, `<=` and `>=` --
   are derived (§2.3): each is a fixed desugaring into this set and "**not**
   independently implementable". They are rejected here rather than accepted
   and ignored, because the SST rewrites every use of one into its primitive
   form (docs/desugaring.md §2.3), so a declaration of `>` would parse, check,
   and then never be reached by any call.

   `~` is primitive too and has its own production, since it is the one unary
   operator and takes one parameter rather than two. *)
%inline operator:
  | "==" { operator $loc Nodes.Operator.Eq }
  | "<"  { operator $loc Nodes.Operator.Less }
  | "+"  { operator $loc Nodes.Operator.Add }
  | "*"  { operator $loc Nodes.Operator.Mul }
  | "/"  { operator $loc Nodes.Operator.Div }

%inline comparison_op:
  | "==" { operator $loc Nodes.Operator.Eq }
  | "<=" { operator $loc Nodes.Operator.LessEq }
  | ">=" { operator $loc Nodes.Operator.MoreEq }
  | "<"  { operator $loc Nodes.Operator.Less }
  | ">"  { operator $loc Nodes.Operator.More }
  | "~=" { operator $loc Nodes.Operator.NotEq }

%inline additive_op:
  | "+" { operator $loc Nodes.Operator.Add }
  | "-" { operator $loc Nodes.Operator.Sub }

%inline multiplicative_op:
  | "*" { operator $loc Nodes.Operator.Mul }
  | "/" { operator $loc Nodes.Operator.Div }

(* The loose forms carry the same [Operator.node] as the operators they mirror,
   because a loose operator "calls the same implementation as its unprefixed
   form and differs only in where it groups" (operators.md §3.1) and the
   grouping is the tree. What they do not share is [is_loose], because the two
   spellings are two different pieces of source and the CST records what was
   parsed; collapsing them is the SST's job (docs/desugaring.md §2.2).

   §3.1 is explicit that the loose forms add no token to the operator
   vocabulary of §5.1 -- so they declare nothing either, and the declaration
   productions, which read the unprefixed rules below, do not admit them. *)

%inline loose_comparison_op:
  | "'==" { loose_operator $loc Nodes.Operator.Eq }
  | "'~=" { loose_operator $loc Nodes.Operator.NotEq }
  | "'<=" { loose_operator $loc Nodes.Operator.LessEq }
  | "'>=" { loose_operator $loc Nodes.Operator.MoreEq }
  | "'<"  { loose_operator $loc Nodes.Operator.Less }
  | "'>"  { loose_operator $loc Nodes.Operator.More }

%inline loose_additive_op:
  | "'+" { loose_operator $loc Nodes.Operator.Add }
  | "'-" { loose_operator $loc Nodes.Operator.Sub }

%inline loose_multiplicative_op:
  | "'*" { loose_operator $loc Nodes.Operator.Mul }
  | "'/" { loose_operator $loc Nodes.Operator.Div }

%inline match_selector:
  | case=lname {
      [case]
    }
  | "[" cases=separated_nonempty_list(",", lname) "]" {
      cases
    }

%inline match_pattern:
  | cases=match_selector {
      ({ Nodes.Match_pattern.binder = None; cases; span = Span.of_loc $loc }
        : Nodes.Match_pattern.t)
    }
  | binder=lname cases=match_selector {
      ({
        Nodes.Match_pattern.binder = Some binder;
        cases;
        span = Span.of_loc $loc;
      } : Nodes.Match_pattern.t)
    }

(* An arm follows the same rule as a declaration body: `=> expr` needs the
   terminator, a `{ }` block closes itself. The spec terminates every arm; see
   docs/spec-divergences.md. *)
%inline match_arm:
  | patterns=separated_nonempty_list(",", match_pattern) body=block_body {
      ({ Nodes.Match_arm.patterns; body; span = Span.of_loc $loc }
        : Nodes.Match_arm.t)
    }
  | patterns=separated_nonempty_list(",", match_pattern) body=shorthand_body ";" {
      ({ Nodes.Match_arm.patterns; body; span = Span.of_loc $loc }
        : Nodes.Match_arm.t)
    }

(* The scrutinee list is parenthesized, and that is what keeps the arms' `{`
   attached to the `match` rather than to whatever the last scrutinee turned out
   to be. Written bare, the brace after the scrutinee has two owners: an `expr`
   may itself end in a brace -- a constructor's field body, a map literal, a
   call's trailing argument -- so `match A { } <= B { }` reads both as
   `(match A { }) <= (B { })` and as `match (A { } <= B) { }`. Both are complete
   derivations, which is the one thing docs/ambiguity.md does not allow; the `)`
   ends the scrutinee before the brace is read and neither reading survives it.

   The parentheses delimit the list; they do not build a value out of it. The
   scrutinees stay independent values matched jointly on their tags, exactly as
   before -- Zane has no `(a, b)` expression form for them to collapse into. *)
%inline match_expr:
  | MATCH "(" scrutinees=separated_nonempty_list(",", expr) ")"
    "{" arms=list(match_arm) "}" {
      expr $loc
        (Nodes.Expr.Match
           ({
             Nodes.Match_expr.scrutinees;
             arms;
             abort_handle = None;
             span = Span.of_loc $loc;
           } : Nodes.Match_expr.t))
    }

(* `spawn` takes the whole call, so it is an expression rather than a postfix
   base: `spawn false()()` spawns the outer call. Were it a `primary`, a
   trailing `(` could attach outside it as well as inside, giving the same
   tokens two readings. Parenthesize to call what a spawn produces. *)
%inline spawn_expr:
  | SPAWN call=verb_call {
      expr $loc (Nodes.Expr.Spawn (call None))
    }

(* Postfix bases are deliberately limited so that an uppercase `Type.member`
   has exactly one reading. Bare `Type.member` is a type-member value; when it
   is immediately followed by constructor arguments it is a named constructor
   or variant-case call, never a generic function call. *)
primary:
  | i=INT    { expr $loc (Nodes.Expr.IntLit i) }
  | f=FLOAT  { expr $loc (Nodes.Expr.FloatLit f) }
  | s=STRING { expr $loc (Nodes.Expr.StrLit s) }
  | TRUE     { expr $loc (Nodes.Expr.BoolLit true) }
  | FALSE    { expr $loc (Nodes.Expr.BoolLit false) }
  | "[" items=separated_list(",", expr) "]" {
      expr $loc (Nodes.Expr.CollectionLit items)
    }
  | THIS     {
      expr $loc
        (Nodes.Expr.NameExpr
           (name_expr $loc (Nodes.Name_expr.Ident (mk_name $loc "this"))))
    }
  | name_expr=name_expr { expr $loc (Nodes.Expr.NameExpr name_expr) }
  | "(" e=expr ")" { expr $loc (Nodes.Expr.Parenthized e) }

(* The values that close on a `}` without being a call. They are not [primary]
   for the reason [app_braced] gives. *)
primary_braced:
  | INIT "{" fields=list(terminated(field_arg, ";")) "}" {
      expr $loc (Nodes.Expr.Init fields)
    }
  | value=map_lit { value }
  | value=match_expr { value }

%inline type_member:
  | type_=name_type "." member=lname {
      expr $loc (Nodes.Expr.TypeMember { type_; member })
    }

(* `func_callee` excludes a bare type member. This is what keeps
   `Vector2.zeros()` out of the ordinary computed-call production while still
   allowing postfixes on the value produced by `Colors.red`.) *)
func_callee:
  | primary=primary { primary }
  | call=unbraced_verb_call { expr $loc (Nodes.Expr.VerbCall (call None)) }
  | target=app "." field=lname {
      expr $loc (Nodes.Expr.DotAccess { target; field; abort_handle = None })
    }
  | target=app "[" args=separated_list(",", expr) "]" {
      expr $loc (Nodes.Expr.Subscript { target; args })
    }

app:
  | value=func_callee { value }
  | value=type_member { value }

expr:
  | app=app { app }
  (* A type passed as a value -- the explicit type argument of generics.md
     §5.3, as in `Array(Int, 10000)`.

     It sits here rather than in [primary] because a type is never a postfix
     base: there is no dot access on a type, no calling one (a name in front of
     an argument list is already a constructor call), and no subscripting one
     (a `[ ]` after a type name is a verb-type suffix). Written as a [primary]
     it would reach all three through [app], and `Colors.red`, `Int(3)` and
     `Span.point(0)` would each gain a second reading; written here it reaches
     none of them and every one of those stays at a single derivation.

     Only a bare name, for the reason [Nodes.Expr.TypeValue] records. *)
  | name=name_type { expr $loc (Nodes.Expr.TypeValue name) }
  | value=app_braced { value }
  | call=block_call { expr $loc (Nodes.Expr.VerbCall (call None)) }
  | value=spawn_expr { value }
  | func_lambda=func_lambda(body) {
      expr $loc (Nodes.Expr.FuncLambda func_lambda)
    }
  | meth_lambda=meth_lambda(body) {
      expr $loc (Nodes.Expr.MethLambda meth_lambda)
    }
  | left=expr op=comparison_op right=expr %prec EQEQ {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=additive_op right=expr %prec PLUS {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=multiplicative_op right=expr %prec STAR {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=loose_comparison_op right=expr %prec LOOSE_EQEQ {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=loose_additive_op right=expr %prec LOOSE_PLUS {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=loose_multiplicative_op right=expr %prec LOOSE_STAR {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | "~" value=expr %prec TILDE {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Flip { value; abort_handle = None })))
    }
  | "&" value=ref_target %prec AMPERSAND {
      expr $loc (Nodes.Expr.Ref value)
    }
  | value=expr abort_handle=abort_handle %prec QSTNQSTN {
      attach_abort_handle abort_handle (Span.of_loc $loc) value
    }

(* What a reference may be taken of: a postfix chain, optionally under further
   prefixes. A bare lambda is excluded, so the leading `&` in `&Int () { }`
   belongs to the return type and the whole reads as a lambda returning `&Int`.
   Parenthesize the lambda to take a reference to it. *)
ref_target:
  | value=app { value }
  | value=app_braced { value }
  | "&" value=ref_target %prec AMPERSAND {
      expr $loc (Nodes.Expr.Ref value)
    }
  | "~" value=ref_target %prec TILDE {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Flip { value; abort_handle = None })))
    }

abort_handle:
  | "?" binder=ioption(lname) body=body %prec THICK_ARROW {
      abort_handle_node $loc (Nodes.Abort_handle.Longhand { binder; body })
    }
  | "??" value=expr %prec THICK_ARROW {
      abort_handle_node $loc (Nodes.Abort_handle.Shorthand value)
    }

(* An expression whose last token is a `}` -- the ones a statement may end on
   without a `;` (lexical.md §6.3).

   Whether an expression ends in a brace is decided by its rightmost part:
   `a + match (e) { }` does because its right operand does. So this is the
   right spine of [expr] again, each form with its tail restricted to one that
   closes on a brace, and every left operand still a plain [expr].

   It is a parallel rule rather than a half of [expr]. Splitting [expr] into
   two flavours joined by unit productions would put a reduce/reduce conflict
   between `a + b` and the `b` of `a + b * c`, where precedence cannot reach,
   and GLR would keep both groupings. Beside [expr], the only new decision is
   the one that should exist: at the `}`, whether the statement ends. *)
expr_braced:
  | value=app_braced { value }
  | call=block_call { expr $loc (Nodes.Expr.VerbCall (call None)) }
  | SPAWN call=braced_verb_call {
      expr $loc (Nodes.Expr.Spawn (call None))
    }
  | func_lambda=func_lambda(body_braced) {
      expr $loc (Nodes.Expr.FuncLambda func_lambda)
    }
  | meth_lambda=meth_lambda(body_braced) {
      expr $loc (Nodes.Expr.MethLambda meth_lambda)
    }
  | left=expr op=comparison_op right=expr_braced {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=additive_op right=expr_braced {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=multiplicative_op right=expr_braced {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=loose_comparison_op right=expr_braced {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=loose_additive_op right=expr_braced {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | left=expr op=loose_multiplicative_op right=expr_braced {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Op { op; left; right; abort_handle = None })))
    }
  | "~" value=expr_braced {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Flip { value; abort_handle = None })))
    }
  | "&" value=ref_target_braced {
      expr $loc (Nodes.Expr.Ref value)
    }
  | value=expr abort_handle=abort_handle_braced {
      attach_abort_handle abort_handle (Span.of_loc $loc) value
    }

(* The values other than a [block_call] that close on a `}`. None of them is a
   postfix base: the brace that closes one may close its statement too
   (lexical.md §6.3), and the two tokens a postfix can open with, `(` and `[`,
   are the two a statement can open with. Were `match (x) { } (y)()` a call on
   the match, it would also be the match's statement followed by the statement
   `(y)()`. Parenthesize one to go on using its value. *)
app_braced:
  | value=primary_braced { value }
  | call=braced_verb_call { expr $loc (Nodes.Expr.VerbCall (call None)) }

ref_target_braced:
  | value=app_braced { value }
  | "&" value=ref_target_braced {
      expr $loc (Nodes.Expr.Ref value)
    }
  | "~" value=ref_target_braced {
      expr $loc
        (Nodes.Expr.VerbCall
           (verb_call $loc
              (Nodes.Verb_call.Flip { value; abort_handle = None })))
    }

abort_handle_braced:
  | "?" binder=ioption(lname) body=body_braced {
      abort_handle_node $loc (Nodes.Abort_handle.Longhand { binder; body })
    }
  | "??" value=expr_braced {
      abort_handle_node $loc (Nodes.Abort_handle.Shorthand value)
    }

(* A `;` terminates a statement, unless the statement ends in a `}` -- then that
   brace closes it and nothing else may (lexical.md §6.3). So every statement
   is closed by exactly one of the two, and the grammar says which: each form
   below comes once with a `;` and, where its tail can close on a brace, once
   more ending in a [_braced] tail with none.

   Neither mark is optional. A statement that could end on any token would
   leave a `[` or `(` after it -- the two tokens a statement can open with --
   with two owners, and both readings would reach the end of the input. GLR
   has no way to choose between two finished parses, so that would be a
   program the compiler cannot parse rather than a fork.

   What the grammar still admits is a `;` after a statement that ends in a
   brace. That spelling has one parse -- nothing can begin with the `;` -- so
   [Statement_check] reads it off the tree and rejects it there.

   Note what is *not* here: a bare `{ }` is not a statement. Scoping a run of
   work is a call taking a block argument, so the only braces that open
   anything at this level belong to a declaration. *)
stat:
  | target=app "=" value=expr ";" {
      expr_statement ~ends_at:$endpos ~loc:$loc
        (fun value -> Nodes.Stat.Assign { target; value }) value
    }
  | target=app "=" value=expr_braced {
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(continues_past_trailing value)
        (Nodes.Stat.Assign { target; value })
    }
  (* Ends in its own `{ }` body, so there was no terminator to get wrong. *)
  | decl=block_decl {
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(decl_continues_past_trailing decl)
        (Nodes.Stat.Decl decl)
    }
  (* The grammar requires this one's `;` (see [header_decl]), so there was no
     terminator to get wrong here either. A statement is where the ambiguity
     reaches too -- a body holds `import pkg$` and the declaration after it on
     the same terms package scope does -- so the requirement has to hold at
     both levels to close it at either. *)
  | decl=header_decl ";" {
      terminated_statement ~loc:$loc (Nodes.Stat.Decl decl)
    }
  | decl=simple_decl ";" {
      statement
        ~ends_in_brace:(decl_ends_in_brace decl)
        ~ends_at:$endpos ~loc:$loc
        ~continued:(decl_continues_past_trailing decl)
        (Nodes.Stat.Decl decl)
    }
  | decl=simple_decl_braced {
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(decl_continues_past_trailing decl)
        (Nodes.Stat.Decl decl)
    }
  | call=verb_call ";" {
      let call = call None in
      statement
        ~ends_in_brace:(verb_call_ends_in_brace call)
        ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.VerbCall call)
    }
  | call=verb_call abort_handle=abort_handle ";" {
      let call = call (Some abort_handle) in
      statement
        ~ends_in_brace:(verb_call_ends_in_brace call)
        ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.VerbCall call)
    }
  | call=braced_verb_call {
      let call = call None in
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.VerbCall call)
    }
  | call=verb_call abort_handle=abort_handle_braced {
      let call = call (Some abort_handle) in
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.VerbCall call)
    }
  (* Closed by its own trailing argument, so it takes no terminator and admits
     no abort handler -- nothing may continue the call past that brace. *)
  | call=block_call {
      let call = call None in
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.VerbCall call)
    }
  | SPAWN call=verb_call ";" {
      let call = call None in
      statement
        ~ends_in_brace:(verb_call_ends_in_brace call)
        ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.Spawn call)
    }
  | SPAWN call=verb_call abort_handle=abort_handle ";" {
      let call = call (Some abort_handle) in
      statement
        ~ends_in_brace:(verb_call_ends_in_brace call)
        ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.Spawn call)
    }
  | SPAWN call=braced_verb_call {
      let call = call None in
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.Spawn call)
    }
  | SPAWN call=verb_call abort_handle=abort_handle_braced {
      let call = call (Some abort_handle) in
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(verb_call_continues_past_trailing call)
        (Nodes.Stat.Spawn call)
    }
  | ABORT value=expr ";" {
      expr_statement ~ends_at:$endpos ~loc:$loc
        (fun value -> Nodes.Stat.Abort value) value
    }
  | ABORT value=expr_braced {
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(continues_past_trailing value)
        (Nodes.Stat.Abort value)
    }
  | RETURN value=expr ";" {
      expr_statement ~ends_at:$endpos ~loc:$loc
        (fun value -> Nodes.Stat.Ret value) value
    }
  | RETURN value=expr_braced {
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(continues_past_trailing value)
        (Nodes.Stat.Ret value)
    }
  | RESOLVE value=expr ";" {
      expr_statement ~ends_at:$endpos ~loc:$loc
        (fun value -> Nodes.Stat.Resolve value) value
    }
  | RESOLVE value=expr_braced {
      braced_statement ~ends_at:$endpos ~loc:$loc
        ~continued:(continues_past_trailing value)
        (Nodes.Stat.Resolve value)
    }

%inline param_type:
  | type_=type_expr {
      param_type $loc (Nodes.Param_type.Concrete type_)
    }
  | type_=concept {
      param_type $loc (Nodes.Param_type.Concept type_)
    }

%inline param:
  | name=lname type_=field_type {
      ({ Nodes.Param.name; type_; span = Span.of_loc $loc } : Nodes.Param.t)
    }
  | name=uname concept_=UTYPE {
      ignore concept_;
      ({
        Nodes.Param.name;
        type_ =
          param_type $loc(concept_)
            (Nodes.Param_type.Concept
               (concept $loc(concept_) Nodes.Concept.Type));
        span = Span.of_loc $loc;
      } : Nodes.Param.t)
    }
  | name=lname concept_=NUMBER {
      ignore concept_;
      ({
        Nodes.Param.name;
        type_ =
          param_type $loc(concept_)
            (Nodes.Param_type.Concept
               (concept $loc(concept_) Nodes.Concept.Number));
        span = Span.of_loc $loc;
      } : Nodes.Param.t)
    }

%inline name_expr:
  | name=lname { name_expr $loc (Nodes.Name_expr.Ident name) }
  | pkg=lname "$" name=lname {
      name_expr $loc (Nodes.Name_expr.Qualified { package = pkg; ident = name })
    }
  | "@" pkg=lname "$" name=lname {
      name_expr $loc (Nodes.Name_expr.Intrinsic { package = pkg; ident = name })
    }

%inline name_type:
  | name=uname { name_type $loc (Nodes.Name_type.Ident name) }
  | pkg=lname "$" name=uname {
      name_type $loc (Nodes.Name_type.Qualified { package = pkg; ident = name })
    }
  | "@" pkg=lname "$" name=intrinsic_uname {
      name_type $loc (Nodes.Name_type.Intrinsic { package = pkg; ident = name })
    }

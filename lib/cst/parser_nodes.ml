(* Node constructors, one per spanned module.

   Every action in the grammar builds its node from a variant and the
   production's own [$loc], so each is written [expr $loc (Nodes.Expr.IntLit i)]
   rather than spelling the record out. They exist because the span is not
   optional: a node built without one does not typecheck, which is what keeps a
   production from quietly dropping the position it was reduced from.

   They live beside the grammar rather than inside it because they are record
   boilerplate, not syntax design: nothing here decides what Zane accepts. *)

(* Not called [name]: these are used from `%inline` rules, whose bodies are
   expanded into their callers, and a caller binding `name=...` would capture
   the reference. *)
let mk_name loc text = ({ Nodes.Name.text; span = Span.of_loc loc } : Nodes.Name.t)

let expr loc node = ({ Nodes.Expr.node; span = Span.of_loc loc } : Nodes.Expr.t)

let abort_handle_node loc node =
  ({ Nodes.Abort_handle.node; span = Span.of_loc loc } : Nodes.Abort_handle.t)

let call_arg loc node =
  ({ Nodes.Call_arg.node; span = Span.of_loc loc } : Nodes.Call_arg.t)

let constructor_args loc node =
  ({ Nodes.Constructor_args.node; span = Span.of_loc loc }
    : Nodes.Constructor_args.t)

let verb_call loc node =
  ({ Nodes.Verb_call.node; span = Span.of_loc loc } : Nodes.Verb_call.t)

let mould loc node = ({ Nodes.Mould.node; span = Span.of_loc loc } : Nodes.Mould.t)

let generic_arg loc node =
  ({ Nodes.Generic_arg.node; span = Span.of_loc loc } : Nodes.Generic_arg.t)

let verb_type loc node =
  ({ Nodes.Verb_type.node; span = Span.of_loc loc } : Nodes.Verb_type.t)

let type_expr loc node =
  ({ Nodes.Type_expr.node; span = Span.of_loc loc } : Nodes.Type_expr.t)

let param_type loc node =
  ({ Nodes.Param_type.node; span = Span.of_loc loc } : Nodes.Param_type.t)

let constructor_params loc node =
  ({ Nodes.Constructor_params.node; span = Span.of_loc loc }
    : Nodes.Constructor_params.t)

let stat loc node = ({ Nodes.Stat.node; span = Span.of_loc loc } : Nodes.Stat.t)

let body loc node = ({ Nodes.Body.node; span = Span.of_loc loc } : Nodes.Body.t)

let ret_type loc node =
  ({ Nodes.Ret_type.node; span = Span.of_loc loc } : Nodes.Ret_type.t)

let type_or_moulded loc node =
  ({ Nodes.Type_or_moulded.node; span = Span.of_loc loc }
    : Nodes.Type_or_moulded.t)

let verb_decl loc node =
  ({ Nodes.Verb_decl.node; span = Span.of_loc loc } : Nodes.Verb_decl.t)

let decl loc node = ({ Nodes.Decl.node; span = Span.of_loc loc } : Nodes.Decl.t)

let operator loc node =
  ({ Nodes.Operator.node; is_loose = false; span = Span.of_loc loc }
    : Nodes.Operator.t)

(* The same operator, written with its `'` prefix. Two constructors rather than
   a flag at each of the twenty call sites, so the ten loose productions are
   the only ones that say so. *)
let loose_operator loc node =
  ({ Nodes.Operator.node; is_loose = true; span = Span.of_loc loc }
    : Nodes.Operator.t)

let concept loc node =
  ({ Nodes.Concept.node; span = Span.of_loc loc } : Nodes.Concept.t)

let name_type loc node =
  ({ Nodes.Name_type.node; span = Span.of_loc loc } : Nodes.Name_type.t)

let name_expr loc node =
  ({ Nodes.Name_expr.node; span = Span.of_loc loc } : Nodes.Name_expr.t)

let import loc node =
  ({ Nodes.Import.node; span = Span.of_loc loc } : Nodes.Import.t)

let type_axis loc node =
  ({ Nodes.Type_axis.node; span = Span.of_loc loc } : Nodes.Type_axis.t)

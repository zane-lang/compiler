(* Every node of the typed tree, with the source text its span covers.

   [Sst.To_span_text] over the TST. As there, each line carries the node's
   variant, so the expectation shows what resolution decided and not just
   that spans survived it:

     expr Coerce Point       | 3
       expr Integer_lit      | 3

   Two lines that say the checker inserted an implicit constructor around a
   literal (D9), and that the inserted node points at the argument it
   converted. A node the checker built that pointed nowhere would print
   `<INVALID SPAN>`, and one that pointed at the wrong thing would print the
   wrong text.

   One thing is new. A tree of the SST comes from one file; the TST comes
   from every file of the build. So each line reads its text out of the file
   its own span names, which also means a node that took its span from the
   wrong file shows the wrong text rather than going unnoticed.

   The printer is a module-level reference for the same reason it is one in
   [Sst.To_span_text]: [render] is the only entry point and sets it before
   walking. *)

open Nodes

let printer = ref (Source.Span_text.create "")
let sources : (string -> string option) ref = ref (fun _ -> None)

let line d kind (span : Source.Span.t) =
  let source =
    Option.value ~default:"" (!sources span.Source.Span.start_.Lexing.pos_fname)
  in
  Source.Span_text.line (Source.Span_text.with_source !printer source) d kind span

let each d f xs = List.iter (f d) xs
let opt d f = function None -> () | Some x -> f d x
let local label d (l : Local.t) = line d (label ^ " " ^ l.Local.name) l.Local.span

let rec expr d (e : Expr.t) =
  let at kind = line d ("expr " ^ kind) e.Expr.span in
  let d = d + 1 in
  match e.Expr.node with
  | Expr.Integer_lit _ -> at "Integer_lit"
  | Expr.Decimal_lit _ -> at "Decimal_lit"
  | Expr.Text_lit _ -> at "Text_lit"
  | Expr.Bool_lit _ -> at "Bool_lit"
  | Expr.Var r ->
      at
        ("Var "
        ^
        match r with
        | Name_ref.Local l -> l.Local.name
        | Name_ref.Global { name; _ } -> name
        | Name_ref.Number_param { name; _ } -> name
        | Name_ref.Intrinsic s -> s)
  | Expr.Type_arg t -> at ("Type_arg " ^ Ty.to_string t)
  | Expr.Enum_member m -> at ("Enum_member " ^ m)
  | Expr.Invalid -> at "Invalid"
  | Expr.Array_lit items ->
      at "Array_lit";
      each d expr items
  | Expr.Map_lit entries ->
      at "Map_lit";
      List.iter
        (fun (k, v) ->
          expr d k;
          expr d v)
        entries
  | Expr.Case { case; payload } ->
      at ("Case " ^ case);
      expr d payload
  | Expr.Construct { ctor; args; handler = h } ->
      at ("Construct " ^ ctor.Verb_ref.name);
      each d arg args;
      opt d handler h
  | Expr.Construct_fields { ctor; fields; handler = h } ->
      at ("Construct_fields " ^ ctor.Verb_ref.name);
      each d field_value fields;
      opt d handler h
  | Expr.Field { target; field; _ } ->
      at ("Field " ^ field);
      expr d target
  | Expr.Case_read { target; case; handler = h } ->
      at ("Case_read " ^ case);
      expr d target;
      handler d h
  | Expr.Map_read { target; property; _ } ->
      at ("Map_read " ^ property);
      expr d target
  | Expr.Subscript { target; args; _ } ->
      at "Subscript";
      expr d target;
      each d expr args
  | Expr.Ref inner ->
      at "Ref";
      expr d inner
  | Expr.Init fields ->
      at "Init";
      each d field_value fields
  | Expr.Spawn inner ->
      at "Spawn";
      expr d inner
  | Expr.Match m ->
      at "Match";
      each d expr m.Match.scrutinees;
      each d arm m.Match.arms;
      opt d handler m.Match.handler
  | Expr.Call { callee; args; handler = h } ->
      at ("Call " ^ callee.Verb_ref.name);
      each d arg args;
      opt d handler h
  | Expr.Call_value { callee; args; handler = h } ->
      at "Call_value";
      expr d callee;
      each d arg args;
      opt d handler h
  | Expr.Op { op; left; right; swapped; handler = h; _ } ->
      at
        ("Op " ^ Intrinsics.operator_token op
        ^ if swapped then " swapped" else "");
      expr d left;
      expr d right;
      opt d handler h
  | Expr.Flip { value; handler = h; _ } ->
      at "Flip";
      expr d value;
      opt d handler h
  | Expr.Coerce { ctor; value } ->
      at ("Coerce " ^ ctor.Verb_ref.name);
      expr d value
  | Expr.Lambda l ->
      at "Lambda";
      each d (local "param") l.Lambda.params;
      block d l.Lambda.body

and arg d = function Arg.Value e -> expr d e | Arg.Block b -> block d b

and field_value d (f : Field_value.t) =
  line d ("field " ^ f.Field_value.name) f.Field_value.span;
  expr (d + 1) f.Field_value.value

and handler d (h : Handler.t) =
  line d "handler" h.Handler.span;
  opt (d + 1) (local "binder") h.Handler.binder;
  block (d + 1) h.Handler.body

and arm d (a : Arm.t) =
  line d "arm" a.Arm.span;
  List.iter
    (fun (p : Pattern.t) ->
      line (d + 1) ("pattern " ^ p.Pattern.case) p.Pattern.span;
      opt (d + 2) (local "binder") p.Pattern.binder)
    a.Arm.patterns;
  block (d + 1) a.Arm.body

and block d (b : Block.t) =
  line d "block" b.Block.span;
  each (d + 1) stat b.Block.stats

and stat d (s : Stat.t) =
  let at kind = line d ("stat " ^ kind) s.Stat.span in
  let d = d + 1 in
  match s.Stat.node with
  | Stat.Expr e ->
      at "Expr";
      expr d e
  | Stat.Spawn e ->
      at "Spawn";
      expr d e
  | Stat.Let { local = l; value } ->
      at "Let";
      local "local" d l;
      expr d value
  | Stat.Assign { target; value } ->
      at "Assign";
      expr d target;
      expr d value
  | Stat.Abort e ->
      at "Abort";
      expr d e
  | Stat.Return e ->
      at "Return";
      expr d e
  | Stat.Resolve e ->
      at "Resolve";
      expr d e

let decl d (x : Decl.t) =
  let at kind name = line d ("decl " ^ kind ^ " " ^ name) x.Decl.span in
  let d = d + 1 in
  match x.Decl.node with
  | Decl.Type { name; _ } -> at "Type" name
  | Decl.Alias { name; _ } -> at "Alias" name
  | Decl.Constant { name; value; _ } ->
      at "Constant" name;
      expr d value
  | Decl.Enum_map { property; entries; _ } ->
      at "Enum_map" property;
      each d (fun d (_, v) -> expr d v) entries
  | Decl.Verb { signature; body } -> (
      at "Verb" signature.Signature.name;
      match body with
      | Decl.Per_instance -> ()
      | Decl.Checked { params; body } ->
          each d (local "param") params;
          block d body)
  | Decl.Subscript { params; value; _ } ->
      at "Subscript" "[]";
      each d (local "param") params;
      opt d expr value

(* An instance has no span of its own: it is its declaration's body, checked
   again (D12). Its header points at that declaration. *)
let instance spans d (i : Instance.t) =
  line d
    (Printf.sprintf "instance %s with %s" i.Instance.signature.Signature.name
       (String.concat ", "
          (List.map (fun ((p : Ty.param), a) -> p.Ty.name ^ " = " ^ Ty.arg_to_string a) i.Instance.args)))
    (Option.value ~default:Source.Span.none (Hashtbl.find_opt spans i.Instance.decl));
  each (d + 1) (local "param") i.Instance.params;
  block (d + 1) i.Instance.body

(* [source] finds a file's text by the path its spans carry, which is the
   path the build read it from. *)
let render ~source (p : Program.t) =
  printer := Source.Span_text.create "";
  (* Every line looks its file up, and [source] may scan the whole build to
     find one, so each file is found once. *)
  let found = Hashtbl.create 16 in
  (sources :=
     fun path ->
       match Hashtbl.find_opt found path with
       | Some text -> text
       | None ->
           let text = source path in
           Hashtbl.add found path text;
           text);
  let spans = Hashtbl.create 64 in
  List.iter
    (fun (pkg : Package.t) ->
      List.iter (fun (x : Decl.t) -> Hashtbl.replace spans x.Decl.id x.Decl.span) pkg.Package.decls)
    p.Program.packages;
  List.iter
    (fun (pkg : Package.t) ->
      Source.Span_text.heading !printer 0 ("package " ^ pkg.Package.name);
      each 1 decl pkg.Package.decls)
    p.Program.packages;
  if p.Program.instances <> [] then Source.Span_text.heading !printer 0 "instances";
  each 1 (instance spans) p.Program.instances;
  Source.Span_text.contents !printer

(* The CGT as a tree to print, the `--cgt` view. Every expression shows the
   machine type it has. *)

open Tree_graph
open Nodes

(* A layout, one position per line: a host as `@8 (16 bytes) when [0]=1`,
   a string's handle as `text @8`, a list's as `list @8 of T (16 bytes
   apart)`, and a boxed member as `box @8 of T (24 bytes)`. *)
let positions (ps : Layout.position list) =
  map_seq
    (fun (p : Layout.position) ->
      let tags =
        match p.tags with
        | [] -> ""
        | ts ->
            let tag (o, t) = Printf.sprintf "[%d]=%d" o t in
            " when " ^ String.concat ", " (List.map tag ts)
      in
      match p.kind with
      | Layout.Host -> Leaf (Printf.sprintf "@%d (%d bytes)%s" p.offset p.size tags)
      | Layout.Text -> Leaf (Printf.sprintf "text @%d%s" p.offset tags)
      | Layout.List { stride; elements } ->
          Leaf (Printf.sprintf "list @%d of %s (%d bytes apart)%s" p.offset elements stride tags)
      | Layout.Box { size; payload } ->
          Leaf (Printf.sprintf "box @%d of %s (%d bytes)%s" p.offset payload size tags))
    ps

let layout (l : Layout.t) = Leaf l

let rec expr (e : Expr.t) =
  let typed s = Leaf (s ^ " : " ^ Ty.to_string e.Expr.ty) in
  let call title fn args =
    group title
      (fields
         [ ("type", Leaf (Ty.to_string e.Expr.ty)); ("fn", Leaf fn); ("args", map_seq expr args) ])
  in
  match e.Expr.node with
  | Expr.Int i -> typed (Int64.to_string i)
  | Expr.Float f -> typed (Printf.sprintf "%h" f)
  | Expr.Bool b -> typed (string_of_bool b)
  | Expr.Text s -> typed (Printf.sprintf "%S" s)
  | Expr.Unit -> typed "unit"
  | Expr.Local id -> typed (Printf.sprintf "local #%d" id)
  | Expr.Address id -> typed (Printf.sprintf "address of #%d" id)
  | Expr.Deref p ->
      group "deref" (fields [ ("type", Leaf (Ty.to_string e.Expr.ty)); ("ptr", expr p) ])
  | Expr.Record members ->
      group "record"
        (fields
           [
             ("type", Leaf (Ty.to_string e.Expr.ty));
             ( "members",
               map_seq
                 (fun (i, m) -> group (Printf.sprintf "member %d" i) (expr m))
                 members );
           ])
  | Expr.Member { value; index } ->
      group "member"
        (fields
           [
             ("type", Leaf (Ty.to_string e.Expr.ty));
             ("index", Leaf (string_of_int index));
             ("value", expr value);
           ])
  | Expr.Case { index; payload } ->
      group "case"
        (fields
           [
             ("type", Leaf (Ty.to_string e.Expr.ty));
             ("index", Leaf (string_of_int index));
             ("payload", expr payload);
           ])
  | Expr.Payload { value; index } ->
      group "payload"
        (fields
           [
             ("type", Leaf (Ty.to_string e.Expr.ty));
             ("index", Leaf (string_of_int index));
             ("value", expr value);
           ])
  | Expr.Offset { base; within; path } ->
      group "offset"
        (fields
           [
             ("within", Leaf (Ty.to_string within));
             ("path", Leaf (String.concat "." (List.map string_of_int path)));
             ("base", expr base);
           ])
  | Expr.Mint p -> group "mint" (expr p)
  | Expr.Resolve t -> group "resolve" (expr t)
  | Expr.Terminal t -> group "terminal" (expr t)
  | Expr.Take { address; layout = l } ->
      group "take"
        (fields
           [
             ("type", Leaf (Ty.to_string e.Expr.ty));
             ("address", expr address);
             ("layout", layout l);
           ])
  | Expr.Copy { value; layout = l } ->
      group "copy"
        (fields
           [ ("type", Leaf (Ty.to_string e.Expr.ty)); ("value", expr value); ("layout", layout l) ])
  | Expr.Box { value; layout = l } ->
      group "box" (fields [ ("value", expr value); ("layout", layout l) ])
  | Expr.Layout l -> Leaf ("layout " ^ l)
  | Expr.Call { fn; args } -> call "call" fn args
  | Expr.Runtime { fn; args } -> call "runtime" fn args
  | Expr.Binary { op; left; right } ->
      group "binary"
        (fields
           [
             ("type", Leaf (Ty.to_string e.Expr.ty));
             ("op", Leaf (Expr.binop_to_string op));
             ("left", expr left);
             ("right", expr right);
           ])
  | Expr.Flip value ->
      group "flip" (fields [ ("type", Leaf (Ty.to_string e.Expr.ty)); ("value", expr value) ])
  | Expr.Expand { label; body; result } ->
      group "expand"
        (fields
           ([
              ("type", Leaf (Ty.to_string e.Expr.ty));
              ("label", Leaf (Printf.sprintf "@%d" label));
            ]
           @ (match result with
             | Some id -> [ ("result", Leaf (Printf.sprintf "#%d" id)) ]
             | None -> [])
           @ [ ("body", map_seq stat body) ]))

and stat = function
  | Stat.Let { id; value } ->
      group "let" (fields [ ("local", Leaf (Printf.sprintf "#%d" id)); ("value", expr value) ])
  | Stat.Host { id; scope; value; layout = l } ->
      group "host"
        (fields
           ([
              ("local", Leaf (Printf.sprintf "#%d" id));
              ("scope", Leaf (Printf.sprintf "%%%d" scope));
              ("value", expr value);
            ]
           @ [ ("layout", layout l) ]))
  | Stat.Store { address; value } ->
      group "store" (fields [ ("address", expr address); ("value", expr value) ])
  | Stat.Overwrite { address; value; layout = l; contingent } ->
      group (if contingent then "overwrite contingent" else "overwrite")
        (fields [ ("address", expr address); ("value", expr value); ("layout", layout l) ])
  | Stat.Place { address; value; layout = l } ->
      group "place"
        (fields [ ("address", expr address); ("value", expr value); ("layout", layout l) ])
  | Stat.Reserve { id; scope; ty; layout = l } ->
      group "reserve"
        (fields
           [
             ("local", Leaf (Printf.sprintf "#%d" id));
             ("scope", Leaf (Printf.sprintf "%%%d" scope));
             ("type", Leaf (Ty.to_string ty));
             ("layout", layout l);
           ])
  | Stat.Scope { id; body } ->
      let arena = Leaf (Printf.sprintf "%%%d" id) in
      group "scope" (fields [ ("id", arena); ("body", map_seq stat body) ])
  | Stat.Assign { place = { local; deref; path; _ }; value } ->
      let target =
        Printf.sprintf "%s#%d%s"
          (if deref then "*" else "")
          local
          (String.concat "" (List.map (Printf.sprintf ".%d") path))
      in
      group "assign" (fields [ ("place", Leaf target); ("value", expr value) ])
  | Stat.Eval e -> group "eval" (expr e)
  | Stat.Return e -> group "return" (expr e)
  | Stat.If { cond; body } ->
      group "if" (fields [ ("cond", expr cond); ("body", map_seq stat body) ])
  | Stat.Repeat { count; body } ->
      group "repeat" (fields [ ("count", expr count); ("body", map_seq stat body) ])
  | Stat.Switch { value; cases } ->
      group "switch"
        (fields
           [
             ("value", expr value);
             ( "cases",
               map_seq
                 (fun (i, body) -> group (Printf.sprintf "case %d" i) (map_seq stat body))
                 cases );
           ])
  | Stat.Leave label -> Leaf (Printf.sprintf "leave @%d" label)

let func (f : Func.t) =
  group "func"
    (fields
       [
         ("symbol", Leaf f.Func.symbol);
         ( "params",
           map_seq
             (fun (id, t) -> Leaf (Printf.sprintf "local #%d : %s" id (Ty.to_string t)))
             f.Func.params );
         ("ret", Leaf (Ty.to_string f.Func.ret));
         ("body", map_seq stat f.Func.body);
       ])

let program (p : Program.t) =
  let named (name, ps) =
    group "layout" (fields [ ("type", Leaf name); ("positions", positions ps) ])
  in
  group "program"
    (fields
       [
         ("entry", Leaf p.Program.entry);
         ("layouts", map_seq named p.Program.layouts);
         ("funcs", map_seq func p.Program.funcs);
       ])

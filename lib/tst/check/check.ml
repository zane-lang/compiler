(* Pass 5 (docs/design/semantics.md §3): every verb body, constant and enum-map entry,
   typed against the signatures pass 4 settled.

   Typing is bottom-up (D6): an expression's type comes from its parts, and
   the only place a destination type matters is a coercion site, where the
   destination is the parameter of the candidate being tried. So a call types
   its arguments first and then resolves its overloads in the three phases of
   functions.md §5.

   A generic verb's body is checked once per instantiation (D12). Resolving a
   call to one records the instance; [run] checks each instance once, with its
   parameters replaced by the arguments it was called with, and an instance may
   ask for more.

   This file is the recursive walk. What it reads but is not part of it is
   beside it: [Context], [Instances], [Overloads] and [Termination]; [Program]
   runs the walk over every body of the build. *)

open Env
module N = Sst.Nodes
module T = Nodes
module S = Signature

open Context
open Instances
open Overloads
open Termination

(* ---------------------------------------------------------------------- *)
(* Expressions                                                            *)
(* ---------------------------------------------------------------------- *)

let rec expr env ?(flow = false) ctx (e : N.Expr.t) : T.Expr.t =
  let span = e.N.Expr.span in
  match e.N.Expr.node with
  | N.Expr.IntLit s -> mk (T.Expr.Integer_lit s) (Ty.Concept Ty.Integer_lit) span
  | N.Expr.DecimalLit s -> mk (T.Expr.Decimal_lit s) (Ty.Concept Ty.Decimal_lit) span
  | N.Expr.StrLit s -> mk (T.Expr.Text_lit s) (Ty.Concept Ty.Text_lit) span
  | N.Expr.BoolLit b -> mk (T.Expr.Bool_lit b) Ty.bool_primitive span
  | N.Expr.CollectionLit items -> array_literal env ctx span items
  | N.Expr.MapLit entries -> map_literal env ctx span entries
  | N.Expr.NameExpr n -> name_value env ctx n
  | N.Expr.TypeMember { type_; member } -> type_member env ctx span type_ member
  | N.Expr.TypeValue name -> (
      match Type_decls.resolve_head env (type_scope ctx) name with
      | Type_decls.Unknown -> invalid span
      | head ->
          let t = Type_decls.apply env (type_scope ctx) span head name [] in
          mk (T.Expr.Type_arg t) (Ty.Concept Ty.Type_value) span)
  | N.Expr.DotAccess { target; field; abort_handle } -> member env ~flow ctx span target field abort_handle
  | N.Expr.Subscript { target; args } -> subscript env ctx span target args
  | N.Expr.Ref inner ->
      let v = expr env ctx inner in
      (match v.T.Expr.ty with
      | Ty.Error | Ty.Param _ -> ()
      | Ty.Reference _ -> ()
      | t ->
          if not (Type_decls.is_reference env t) then
            error env span
              (Printf.sprintf
                 "`&` takes a reference to a reference type, and %s is a value type"
                 (quote (Ty.to_string t))));
      mk (T.Expr.Ref v) (Ty.Reference (Ty.strip_mode v.T.Expr.ty)) span
  | N.Expr.Init fields -> init env ctx span fields
  | N.Expr.Spawn call -> spawn env ctx call
  | N.Expr.Match m -> match_ env ~flow ctx m
  | N.Expr.VerbCall call -> fst (verb_call env ~flow ctx call)
  | N.Expr.FuncLambda l ->
      lambda env ctx span ~this_type:None ~params:l.N.Func_lambda.params ~ret_type:l.N.Func_lambda.ret_type
        ~is_mut:false ~body:l.N.Func_lambda.body
  | N.Expr.MethLambda l ->
      lambda env ctx span ~this_type:(Some l.N.Meth_lambda.this_type) ~params:l.N.Meth_lambda.params
        ~ret_type:l.N.Meth_lambda.ret_type ~is_mut:l.N.Meth_lambda.is_mut ~body:l.N.Meth_lambda.body

(* syntax.md §2.9: every element already has the one element type; nothing
   searches for a common one. *)
and array_literal env ctx span items =
  let items = List.map (expr env ctx) items in
  match items with
  | [] ->
      error env span "an array literal holds at least one element; name the type to build an empty one";
      invalid span
  | first :: rest ->
      List.iter
        (fun (item : T.Expr.t) ->
          if not (Ty.equal item.T.Expr.ty first.T.Expr.ty) then
            error env item.T.Expr.span
              (Printf.sprintf
                 "every element of an array literal has one type: this one is %s, and \
                  the first is %s"
                 (quote (Ty.to_string item.T.Expr.ty))
                 (quote (Ty.to_string first.T.Expr.ty))))
        rest;
      mk (T.Expr.Array_lit items)
        (Ty.Concept (Ty.Array_lit (first.T.Expr.ty, Ty.Known (List.length items))))
        span

and map_literal env ctx span entries =
  let entries = List.map (fun (k, v) -> (expr env ctx k, expr env ctx v)) entries in
  match entries with
  | [] ->
      error env span "a map literal holds at least one entry";
      invalid span
  | (k0, v0) :: rest ->
      List.iter
        (fun ((k : T.Expr.t), (v : T.Expr.t)) ->
          if not (Ty.equal k.T.Expr.ty k0.T.Expr.ty) then
            error env k.T.Expr.span
              (Printf.sprintf "every key of a map literal has one type: this one is %s, and the first is %s"
                 (quote (Ty.to_string k.T.Expr.ty)) (quote (Ty.to_string k0.T.Expr.ty)));
          if not (Ty.equal v.T.Expr.ty v0.T.Expr.ty) then
            error env v.T.Expr.span
              (Printf.sprintf "every value of a map literal has one type: this one is %s, and the first is %s"
                 (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string v0.T.Expr.ty))))
        rest;
      mk (T.Expr.Map_lit entries) (Ty.Concept (Ty.Map_lit (k0.T.Expr.ty, v0.T.Expr.ty))) span

and constant_ref env (d : decl) span =
  let ty = Option.value ~default:Ty.Error (Hashtbl.find_opt env.constant_types d.id) in
  mk (T.Expr.Var (T.Name_ref.Global { decl = d.id; name = decl_name d })) ty span

and call_only env span name =
  error env span
    (Printf.sprintf
       "%s is a function, and a function has no value form: call it, or hold a \
        function value in a lambda-variable (functions.md §7.1)"
       (quote name));
  invalid span

and name_value env ctx (n : N.Name_expr.t) =
  let span = n.N.Name_expr.span in
  match n.N.Name_expr.node with
  | N.Name_expr.Ident id -> (
      let text = id.N.Name.text in
      match find_local ctx text with
      | Some b -> mk (T.Expr.Var (T.Name_ref.Local b.local)) b.local.T.Local.ty span
      | None -> (
          match List.assoc_opt text ctx.params with
          | Some (Ty.Number value) ->
              mk (T.Expr.Var (T.Name_ref.Number_param { name = text; value })) (Ty.Concept Ty.Integer_lit) span
          | Some (Ty.Type t) -> mk (T.Expr.Type_arg t) (Ty.Concept Ty.Type_value) span
          | None -> (
              match lookup_values env ctx.file text with
              | d :: _ when not (is_function d) -> constant_ref env d span
              | _ :: _ -> call_only env span text
              | [] ->
                  error env span
                    (Printf.sprintf "no name %s is in scope%s" (quote text)
                       (missing_import_hint env ctx.file text ~members:(package_values env)));
                  invalid span)))
  | N.Name_expr.Qualified { package = q; ident } -> (
      match qualified env ctx.file q.N.Name.text ident.N.Name.text ~members:(package_values env) with
      | Error message ->
          error env q.N.Name.span message;
          invalid span
      | Ok (pkg, found, reachable) -> (
          match reachable with
          | d :: _ when not (is_function d) -> constant_ref env d span
          | _ :: _ -> call_only env span (pkg ^ "$" ^ ident.N.Name.text)
          | [] ->
              error env span
                (if found <> [] then
                   Printf.sprintf "%s is private to the package %s" (quote ident.N.Name.text) (quote pkg)
                 else Printf.sprintf "the package %s has no member %s" (quote pkg) (quote ident.N.Name.text));
              invalid span))
  | N.Name_expr.Intrinsic { package = ns; ident } -> (
      let ns = ns.N.Name.text and text = ident.N.Name.text in
      let spelling = "@" ^ ns ^ "$" ^ text in
      if ns = "program" && not ctx.is_root then begin
        error env span
          (Printf.sprintf
             "only the root package reaches `@program$`; %s receives the console and \
              runtime from it as an argument"
             (quote ctx.package));
        invalid span
      end
      else
        match Intrinsics.find_value ns text with
        | Some ty -> mk (T.Expr.Var (T.Name_ref.Intrinsic spelling)) ty span
        | None ->
            if Intrinsics.find_functions ns text <> [] then
              error env span
                (Printf.sprintf "%s is an intrinsic operation, and has no value form" (quote spelling))
            else error env span (Printf.sprintf "no intrinsic named %s" (quote spelling));
            invalid span)

(* `Colors.red`: a payloadless enum member. A variant case is written with its
   payload, and a named constructor is called. *)
and type_member env ctx span (type_ : N.Name_type.t) (member : N.Name.t) =
  let m = member.N.Name.text in
  let t = Type_decls.apply env (type_scope ctx) span (Type_decls.resolve_head env (type_scope ctx) type_) type_ [] in
  match (t, definition env t) with
  | Ty.Error, _ -> invalid span
  | _, Some (_, Enum members) when List.mem m members -> mk (T.Expr.Enum_member m) t span
  | _, Some (tid, Enum _) ->
      error env member.N.Name.span (Printf.sprintf "%s has no member %s" (quote tid.Ty.name) (quote m));
      invalid span
  | _, Some (tid, Variant cases) when List.mem_assoc m cases ->
      error env span
        (Printf.sprintf "%s is a case of %s, and a case is built with its payload: `%s.%s(...)`"
           (quote m) (quote tid.Ty.name) tid.Ty.name m);
      invalid span
  | _ ->
      error env span
        (Printf.sprintf "%s has no member %s that can be read without a call"
           (quote (Ty.to_string t)) (quote m));
      invalid span

(* D10: a member read is a field read, a case read or an enum-map read, and
   only the target's type says which. D13: a case read can fail, so it takes a
   handler, and the others cannot, so they take none. *)
and member env ~flow ctx span target (field : N.Name.t) handle =
  let target = expr env ctx target in
  let f = field.N.Name.text in
  let no_handler () =
    match handle with
    | Some (h : N.Abort_handle.t) ->
        error env h.N.Abort_handle.span
          (Printf.sprintf "reading %s cannot fail, so it takes no handler" (quote f))
    | None -> ()
  in
  match target.T.Expr.ty with
  | Ty.Error ->
      ignore (handler_opt env ctx ~abort:Ty.Error ~ok:Ty.Error handle);
      invalid span
  | ty -> (
      match definition env ty with
      | Some (tid, Struct fields) -> (
          no_handler ();
          let rec slot i = function
            | [] -> None
            | (n, t) :: rest -> if String.equal n f then Some (i, t) else slot (i + 1) rest
          in
          match slot 0 fields with
          | None -> map_read env ctx span target tid f ~missing:(fun () ->
                error env field.N.Name.span
                  (Printf.sprintf "%s has no field %s" (quote tid.Ty.name) (quote f)))
          | Some (i, t) ->
              if is_private f && not (private_access ctx tid) then
                error env field.N.Name.span
                  (Printf.sprintf
                     "%s is private: only a method whose subject is %s may read it \
                      (types.md §2.3)"
                     (quote f) (quote tid.Ty.name));
              mk (T.Expr.Field { target; field = f; slot = i }) t span)
      | Some (tid, Variant cases) -> (
          match List.assoc_opt f cases with
          | None ->
              no_handler ();
              map_read env ctx span target tid f ~missing:(fun () ->
                  error env field.N.Name.span
                    (Printf.sprintf "%s has no case %s" (quote tid.Ty.name) (quote f)))
          | Some payload -> (
              match handle with
              | None ->
                  error env span
                    (Printf.sprintf
                       "reading the case %s of %s fails when another case is live, so \
                        it takes a `?` or `??` handler"
                       (quote f) (quote tid.Ty.name));
                  mk (T.Expr.Case_read { target; case = f; handler = { T.Handler.binder = None; body = { T.Block.stats = []; span }; span } }) payload span
              | Some h ->
                  let h = type_handler env ctx ~abort:Ty.unit_primitive ~ok:payload h in
                  mk (T.Expr.Case_read { target; case = f; handler = h }) payload span))
      | Some (tid, Enum _) ->
          no_handler ();
          map_read env ctx span target tid f ~missing:(fun () ->
              error env field.N.Name.span
                (Printf.sprintf "no enum map %s is declared for %s" (quote f) (quote tid.Ty.name)))
      | _ ->
          ignore flow;
          no_handler ();
          error env field.N.Name.span
            (Printf.sprintf "%s has no member %s" (quote (Ty.to_string ty)) (quote f));
          invalid span)

and private_access ctx tid =
  match Option.map Ty.strip_mode ctx.this_type with
  | Some (Ty.Named (this_tid, _)) -> this_tid = tid
  | _ -> false

(* An enum map is found where a method is: in the enum's home package, then
   in the current one. *)
and map_read env ctx span target tid property ~missing =
  let maps = Option.value ~default:[] (Hashtbl.find_opt env.enum_maps (tid, property)) in
  let in_package p = List.filter (fun m -> m.map_decl.package = p) maps in
  let visible = in_package tid.Ty.package @ in_package ctx.package in
  match visible with
  | m :: _ -> mk (T.Expr.Map_read { target; map = m.map_decl.id; property }) m.map_ty span
  | [] ->
      missing ();
      invalid span

and subscript env ctx span target args =
  let target = expr env ctx target in
  let args = List.map (expr env ctx) args in
  let homes = List.filter_map Verb_signatures.home [ target.T.Expr.ty ] @ [ S.Package ctx.package ] in
  let cands =
    List.filter (fun (s : S.t) -> List.mem s.home homes && accessible_sig ctx s) !(env.subscripts)
  in
  if target.T.Expr.ty = Ty.Error || List.exists (fun (a : T.Expr.t) -> a.T.Expr.ty = Ty.Error) args then
    invalid span
  else
    let actuals =
      { arg = T.Arg.Value target; aty = target.T.Expr.ty; aspan = target.T.Expr.span; subject = true }
      :: List.map (fun (a : T.Expr.t) -> { arg = T.Arg.Value a; aty = a.T.Expr.ty; aspan = a.T.Expr.span; subject = false }) args
    in
    if cands = [] then begin
      error env span (Printf.sprintf "%s declares no subscript" (quote (Ty.to_string target.T.Expr.ty)));
      invalid span
    end
    else
      match
        report_resolution env ~span ~what:"subscript" ~args:(describe_args actuals)
          (resolve env cands (positional actuals)) cands
      with
      | None -> invalid span
      | Some o ->
          let ty =
            match o.sig_.owner with
            | S.Intrinsic _ -> Ty.subst o.subst o.sig_.ret
            | S.Declared id -> subscript_result env (Hashtbl.find env.decls id) o.sig_ o.subst span
          in
          let args = List.filter_map (function Some (T.Arg.Value e) -> Some e | _ -> None) (List.tl o.converted) in
          mk (T.Expr.Subscript { target; impl = verb_ref o.sig_ o.subst; args }) ty span

and init env ctx span fields =
  match ctx.building with
  | None ->
      error env span "`init{ }` is valid only in a constructor body, which is what naming a verb after a type unlocks";
      List.iter (fun (f : N.Field_arg.t) -> ignore (expr env ctx f.N.Field_arg.value)) fields;
      invalid span
  | Some built -> (
      match definition env built with
      | Some (_, Struct declared) ->
          let seen = Hashtbl.create 8 in
          let values =
            List.filter_map
              (fun (f : N.Field_arg.t) ->
                let name = f.N.Field_arg.name.N.Name.text in
                let value = expr env ctx f.N.Field_arg.value in
                let rec slot i = function
                  | [] -> None
                  | (n, t) :: rest -> if String.equal n name then Some (i, t) else slot (i + 1) rest
                in
                match slot 0 declared with
                | None ->
                    error env f.N.Field_arg.name.N.Name.span
                      (Printf.sprintf "%s has no field %s" (quote (Ty.to_string built)) (quote name));
                    None
                | Some (i, t) ->
                    if Hashtbl.mem seen name then
                      error env f.N.Field_arg.name.N.Name.span
                        (Printf.sprintf "the field %s is already assigned" (quote name))
                    else Hashtbl.add seen name ();
                    if not (Ty.assignable ~dst:t ~src:value.T.Expr.ty) then
                      error env value.T.Expr.span
                        (Printf.sprintf
                           "the field %s is %s, and this is %s; `init{ }` is not a coercion \
                            site, so a conversion is written out"
                           (quote name) (quote (Ty.to_string t)) (quote (Ty.to_string value.T.Expr.ty)));
                    Some { T.Field_value.name; slot = i; value; span = f.N.Field_arg.span })
              fields
          in
          let missing = List.filter (fun (n, _) -> not (Hashtbl.mem seen n)) declared in
          if missing <> [] then
            error env span
              (Printf.sprintf "`init{ }` assigns every field, and this one leaves out %s"
                 (String.concat ", " (List.map (fun (n, _) -> quote n) missing)));
          mk (T.Expr.Init values) built span
      | _ ->
          error env span
            (Printf.sprintf "`init{ }` builds a struct, and %s is not one" (quote (Ty.to_string built)));
          invalid span)

(* ---------------------------------------------------------------------- *)
(* Handlers                                                               *)
(* ---------------------------------------------------------------------- *)

and type_handler env ctx ~abort ~ok (h : N.Abort_handle.t) : T.Handler.t =
  let inner = push { ctx with resolve_target = To_handler ok } in
  let binder = Option.map (fun b -> declare env inner Binder b abort) h.N.Abort_handle.binder in
  let body = block_in env inner h.N.Abort_handle.body in
  if not (ends ~resolve:true body.T.Block.stats) then
    error env h.N.Abort_handle.span
      "every path through a handler ends in `resolve`, `return` or `abort`; this one \
       can fall through (error-handling.md §3.2)";
  { T.Handler.binder; body; span = h.N.Abort_handle.span }

and handler_opt env ctx ~abort ~ok handle = Option.map (type_handler env ctx ~abort ~ok) handle

(* What an abortable operation's call site owes: a handler when it can
   abort, none when it cannot (error-handling.md §6). In the value position
   of an arm's `return`, an unhandled abort flows out through the `match`
   instead (adt.md §5.4). *)
and owe_handler env ~flow ctx ~what ~span ~abort ~ok handle =
  match (abort, handle) with
  | None, None -> None
  | None, Some (h : N.Abort_handle.t) ->
      error env h.N.Abort_handle.span (Printf.sprintf "%s cannot abort, so it takes no handler" what);
      Some (type_handler env ctx ~abort:Ty.Error ~ok h)
  | Some a, Some h -> Some (type_handler env ctx ~abort:a ~ok h)
  | Some a, None -> (
      match (flow, ctx.ret_target) with
      | true, To_arm r ->
          r.aborts <- r.aborts @ [ (a, span) ];
          None
      | _ ->
          if a <> Ty.Error then
            error env span
              (Printf.sprintf
                 "%s can abort with %s, so the call needs a `?` or `??` handler"
                 what (quote (Ty.to_string a)));
          None)

(* ---------------------------------------------------------------------- *)
(* Calls: arguments and dispatch                                          *)
(* ---------------------------------------------------------------------- *)

and actual_of env ctx (a : N.Call_arg.t) =
  match a.N.Call_arg.node with
  | N.Call_arg.Value e ->
      let v = expr env ctx e in
      { arg = T.Arg.Value v; aty = v.T.Expr.ty; aspan = v.T.Expr.span; subject = false }
  | N.Call_arg.Block b ->
      let typed, ty = block_argument env ctx b in
      { arg = T.Arg.Block typed; aty = ty; aspan = a.N.Call_arg.span; subject = false }

(* A block argument captures the scope it is written in (control-flow.md
   §2.2) and yields nothing: a `return`, `resolve` or `abort` in it acts on
   what encloses the call (docs/spec-divergences.md §11). *)
and block_argument env ctx (b : N.Block.t) = (block_in env (push ctx) b, Ty.Concept Ty.Block)

and verb_call env ~flow ctx (vc : N.Verb_call.t) : T.Expr.t * S.t option =
  let span = vc.N.Verb_call.span in
  match vc.N.Verb_call.node with
  | N.Verb_call.Call { callee; args; form; abort_handle } -> (
      let actuals = List.map (actual_of env ctx) args in
      match form with
      | N.Call_form.Function -> function_call env ~flow ctx span callee actuals abort_handle
      | N.Call_form.Method { is_mut } -> method_call env ~flow ctx span callee actuals ~is_mut abort_handle)
  | N.Verb_call.Constructor { name; args; abort_handle } ->
      (constructor_call env ctx span name args abort_handle, None)
  | N.Verb_call.Op { op; left; right; swapped; abort_handle } ->
      operator env ~flow ctx span op left right ~swapped abort_handle
  | N.Verb_call.Flip { value; abort_handle } -> flip env ~flow ctx span value abort_handle

and any_error actuals = List.exists (fun a -> Ty.contains_error a.aty) actuals

and finish_call env ~flow ctx ~span ~what (o : outcome) handle build =
  request env ~args:o.converted o.sig_ o.subst span;
  let ok = Ty.subst o.subst o.sig_.ret in
  let abort = Option.map (Ty.subst o.subst) o.sig_.abort in
  let handler = handle_call env ~flow ctx ~what ~span ~abort ~ok handle in
  let args = List.filter_map Fun.id o.converted in
  (mk (build (verb_ref o.sig_ o.subst) args handler) ok span, Some o.sig_)

and handle_call env ~flow ctx ~what ~span ~abort ~ok h = owe_handler env ~flow ctx ~what ~span ~abort ~ok h

and skip_handler env ctx handle = ignore (handler_opt env ctx ~abort:Ty.Error ~ok:Ty.Error handle)

(* ---------------------------------------------------------------------- *)
(* Calls: functions and function values                                   *)
(* ---------------------------------------------------------------------- *)

and function_call env ~flow ctx span (callee : N.Expr.t) actuals handle =
  let call_decls ~name cands =
    let cands = List.filter_map (fun (d : decl) -> Hashtbl.find_opt env.signatures d.id) cands in
    if any_error actuals then begin
      skip_handler env ctx handle;
      (invalid span, None)
    end
    else
      match
        report_resolution env ~literal:(literal_drives_inference cands actuals) ~span ~what:(quote name)
          ~args:(describe_args actuals) (resolve env cands (positional actuals)) cands
      with
      | None ->
          skip_handler env ctx handle;
          (invalid span, None)
      | Some o ->
          finish_call env ~flow ctx ~span ~what:(quote name) o handle (fun callee args handler ->
              T.Expr.Call { callee; args; handler })
  in
  let value_call (fn : T.Expr.t) = call_value env ~flow ctx span fn actuals handle in
  match callee.N.Expr.node with
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Ident id; span = at } -> (
      let text = id.N.Name.text in
      match find_local ctx text with
      | Some b -> value_call (mk (T.Expr.Var (T.Name_ref.Local b.local)) b.local.T.Local.ty at)
      | None -> (
          match lookup_values env ctx.file text with
          | d :: _ when not (is_function d) -> value_call (constant_ref env d at)
          | [] ->
              let hint = missing_import_hint env ctx.file text ~members:(package_values env) in
              error env at (Printf.sprintf "no function named %s is in scope%s" (quote text) hint);
              skip_handler env ctx handle;
              (invalid span, None)
          | fns -> call_decls ~name:text fns))
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Qualified { package = q; ident }; span = at } -> (
      match qualified env ctx.file q.N.Name.text ident.N.Name.text ~members:(package_values env) with
      | Error message ->
          error env q.N.Name.span message;
          skip_handler env ctx handle;
          (invalid span, None)
      | Ok (pkg, found, reachable) -> (
          let name = pkg ^ "$" ^ ident.N.Name.text in
          match reachable with
          | d :: _ when not (is_function d) -> value_call (constant_ref env d at)
          | [] ->
              error env at
                (if found <> [] then Printf.sprintf "%s is private to the package %s" (quote ident.N.Name.text) (quote pkg)
                 else Printf.sprintf "the package %s has no function %s" (quote pkg) (quote ident.N.Name.text));
              skip_handler env ctx handle;
              (invalid span, None)
          | fns -> call_decls ~name fns))
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Intrinsic { package = ns; ident }; span = at } -> (
      let ns = ns.N.Name.text and text = ident.N.Name.text in
      match Intrinsics.find_functions ns text with
      | [] ->
          error env at (Printf.sprintf "no intrinsic operation named %s" (quote ("@" ^ ns ^ "$" ^ text)));
          skip_handler env ctx handle;
          (invalid span, None)
      | cands -> (
          let name = "@" ^ ns ^ "$" ^ text in
          if any_error actuals then (skip_handler env ctx handle; (invalid span, None))
          else
            match
              report_resolution env ~span ~what:(quote name) ~args:(describe_args actuals)
                (resolve env cands (positional actuals)) cands
            with
            | None ->
                skip_handler env ctx handle;
                (invalid span, None)
            | Some o ->
                finish_call env ~flow ctx ~span ~what:(quote name) o handle (fun callee args handler ->
                    T.Expr.Call { callee; args; handler })))
  | _ -> value_call (expr env ctx callee)

(* Calling a function value. It is one value with one type, so there is one
   candidate; its arguments are still coercion sites. *)
and call_value env ~flow ctx span (fn : T.Expr.t) actuals handle =
  match Ty.strip_mode fn.T.Expr.ty with
  | Ty.Error ->
      skip_handler env ctx handle;
      (invalid span, None)
  | Ty.Verb v -> (
      let params =
        (match v.Ty.this_ with Some t -> [ t ] | None -> []) @ v.Ty.params
      in
      (* A lambda-variable is named in a message by its own name; any other
         function value has none to give. *)
      let name, what =
        match fn.T.Expr.node with
        | T.Expr.Var (T.Name_ref.Local { T.Local.name; _ })
        | T.Expr.Var (T.Name_ref.Global { name; _ }) ->
            (name, quote name)
        | _ -> ("this function value", "this function value")
      in
      let s =
        {
          S.owner = S.Intrinsic "<value>";
          name;
          home = S.Package ctx.package;
          kind = S.Function;
          generics = [];
          params = List.mapi (fun i t -> { S.name = string_of_int i; ty = t; binds = None; has_default = false }) params;
          ret = v.Ty.ret;
          abort = v.Ty.abort;
          is_mut = v.Ty.is_mut;
        }
      in
      if any_error actuals then (skip_handler env ctx handle; (invalid span, None))
      else
        match
          report_resolution env ~span ~what ~args:(describe_args actuals)
            (resolve env [ s ] (positional actuals)) [ s ]
        with
        | None ->
            skip_handler env ctx handle;
            (invalid span, None)
        | Some o ->
            let handler = owe_handler env ~flow ctx ~what ~span ~abort:v.Ty.abort ~ok:v.Ty.ret handle in
            let args = List.filter_map Fun.id o.converted in
            (mk (T.Expr.Call_value { callee = fn; args; handler }) v.Ty.ret span, None))
  | other ->
      error env fn.T.Expr.span (Printf.sprintf "%s is not a function value, so it cannot be called" (quote (Ty.to_string other)));
      skip_handler env ctx handle;
      (invalid span, None)

(* ---------------------------------------------------------------------- *)
(* Calls: methods                                                         *)
(* ---------------------------------------------------------------------- *)

(* A `!` call runs a `mut` method, which writes its subject: the call is a
   write, exactly as an assignment is (effects.md §4.1). A temporary is no
   binding, so writing one is always legal. *)
and write_subject env ctx (subject : actual) =
  match subject.arg with
  | T.Arg.Value e -> check_writable env ctx e ~bang:true
  | T.Arg.Block _ -> ()

(* functions.md §6.1: the subject type's home package first, then the
   current one; a qualified call names its package instead. *)
and method_call env ~flow ctx span (callee : N.Expr.t) actuals ~is_mut handle =
  let actuals = match actuals with a :: rest -> { a with subject = true } :: rest | [] -> [] in
  let subject = List.hd actuals in
  let named_in home name =
    Hashtbl.find_all env.methods name
    |> List.filter (fun (s : S.t) -> s.home = home && accessible_sig ctx s)
    |> List.rev
  in
  let check_marker (s : S.t) =
    if s.is_mut && not is_mut then
      error env span
        (Printf.sprintf "%s is a `mut` method, so it is called with `!`" (quote s.name))
    else if (not s.is_mut) && is_mut then
      error env span
        (Printf.sprintf "%s is not a `mut` method, so it is called with `:`" (quote s.name))
  in
  let resolve_in stages name =
    if any_error actuals then (skip_handler env ctx handle; (invalid span, None))
    else
      let all = List.concat stages in
      let rec try_stages = function
        | [] -> No_match
        | [] :: rest -> try_stages rest
        | cands :: rest -> (
            match resolve env cands (positional actuals) with
            | No_match -> try_stages rest
            | r -> r)
      in
      if all = [] then begin
        let home =
          match Verb_signatures.home subject.aty with
          | Some h -> Printf.sprintf " in %s, the home of %s," (quote (S.home_to_string h)) (quote (Ty.to_string subject.aty))
          | None -> ""
        in
        error env span
          (Printf.sprintf "no method named %s is declared%s or in this package" (quote name) home);
        skip_handler env ctx handle;
        (invalid span, None)
      end
      else
        match
          report_resolution env ~literal:(literal_drives_inference all actuals) ~span
            ~what:(Printf.sprintf "method %s" (quote name))
            ~args:(describe_args actuals) (try_stages stages) all
        with
        | None ->
            skip_handler env ctx handle;
            (invalid span, None)
        | Some o ->
            check_marker o.sig_;
            if o.sig_.is_mut && is_mut then write_subject env ctx subject;
            finish_call env ~flow ctx ~span ~what:(quote name) o handle (fun callee args handler ->
                T.Expr.Call { callee; args; handler })
  in
  match callee.N.Expr.node with
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Ident id; span = at } -> (
      let text = id.N.Name.text in
      (* A lambda-variable with a subject is called the way a method is. *)
      let value =
        match find_local ctx text with
        | Some b -> Some (mk (T.Expr.Var (T.Name_ref.Local b.local)) b.local.T.Local.ty at)
        | None -> None
      in
      match value with
      | Some ({ T.Expr.ty = Ty.Verb { Ty.this_ = Some _; is_mut = m; _ }; _ } as fn) ->
          if m <> is_mut then
            error env span
              (if m then "this function value is `mut`, so it is called with `!`"
               else "this function value is not `mut`, so it is called with `:`")
          else if m then write_subject env ctx subject;
          call_value env ~flow ctx span fn actuals handle
      | _ ->
          let home_stage =
            match Verb_signatures.home subject.aty with Some h -> named_in h text | None -> []
          in
          let current =
            if Verb_signatures.home subject.aty = Some (S.Package ctx.package) then []
            else named_in (S.Package ctx.package) text
          in
          resolve_in [ home_stage; current ] text)
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Qualified { package = q; ident }; _ } -> (
      match qualified_package env ctx.file q.N.Name.text with
      | Error message ->
          error env q.N.Name.span message;
          skip_handler env ctx handle;
          (invalid span, None)
      | Ok pkg -> resolve_in [ named_in (S.Package pkg) ident.N.Name.text ] ident.N.Name.text)
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Intrinsic { package = ns; ident }; _ } ->
      resolve_in [ named_in (S.Namespace ns.N.Name.text) ident.N.Name.text ] ident.N.Name.text
  | _ ->
      error env callee.N.Expr.span "a method is called by its name";
      skip_handler env ctx handle;
      (invalid span, None)

(* ---------------------------------------------------------------------- *)
(* Calls: constructors and case forms                                     *)
(* ---------------------------------------------------------------------- *)

and constructor_call env ctx span (name : N.Constructor_name.t) (args : N.Constructor_args.t) handle =
  let sc = type_scope ctx in
  let member = Option.map (fun (m : N.Name.t) -> m.N.Name.text) name.N.Constructor_name.member in
  let head = Type_decls.resolve_head env sc name.N.Constructor_name.type_ in
  let no_handler () =
    match handle with
    | Some (h : N.Abort_handle.t) ->
        error env h.N.Abort_handle.span "a constructor cannot abort, so it takes no handler";
        skip_handler env ctx handle
    | None -> ()
  in
  let type_args () =
    match args.N.Constructor_args.node with
    | N.Constructor_args.Positional ps -> List.iter (fun a -> ignore (actual_of env ctx a)) ps
    | N.Constructor_args.Fields fs -> List.iter (fun (f : N.Field_arg.t) -> ignore (expr env ctx f.N.Field_arg.value)) fs
  in
  (* What the name builds, before any arguments: a generic type is named
     bare, and its arguments are inferred (generics.md §5.1). *)
  let target : [ `Type of Ty.t * Ty.param list | `None ] =
    match head with
    | Type_decls.Unknown -> `None
    | Type_decls.Declared d -> (
        match Hashtbl.find_opt env.type_infos d.id with
        | Some info -> `Type (Ty.Named (info.tid, List.map Type_decls.param_arg info.params), info.params)
        | None -> (
            match Hashtbl.find_opt env.alias_infos d.id with
            | Some a when a.alias_params = [] -> `Type (Type_decls.alias_target env a, [])
            | Some _ ->
                error env span "a generic alias cannot name a constructor; name the type it stands for";
                `None
            | None -> `None))
    | Type_decls.Intrinsic_type info ->
        let params = List.map (fun k -> Env.fresh_param env ~name:"_" ~kind:k) info.params in
        `Type (Ty.Intrinsic { namespace = info.namespace; name = info.name; args = List.map Type_decls.param_arg params }, params)
    | Type_decls.Bound (Ty.Type t) -> `Type (t, [])
    | Type_decls.Bound (Ty.Number _) ->
        error env span "a number parameter has no constructor";
        `None
    | Type_decls.Concept_type c ->
        error env span (Printf.sprintf "%s is a concept type, which has no constructor" (quote ("@concepts$" ^ c)));
        `None
  in
  match target with
  | `None ->
      type_args ();
      skip_handler env ctx handle;
      invalid span
  | `Type (built, open_) -> (
      match (definition env built, member) with
      | Some (tid, Variant cases), Some m when List.mem_assoc m cases ->
          no_handler ();
          case_form env ctx span tid (List.assoc m cases) built open_ m args
      | Some (tid, Variant _), None ->
          type_args ();
          no_handler ();
          error env span
            (Printf.sprintf "a variant is built by naming a case, as `%s.case(payload)`" tid.Ty.name);
          invalid span
      | Some (tid, Enum members), Some m when List.mem m members ->
          type_args ();
          no_handler ();
          error env span
            (Printf.sprintf "%s is a member of the enum %s and carries no payload; it is written `%s.%s`"
               (quote m) (quote tid.Ty.name) tid.Ty.name m);
          invalid span
      | _ -> (
          let what =
            quote
              ((match built with Ty.Named (tid, _) -> tid.Ty.name | t -> Ty.to_string t)
              ^ Option.fold ~none:"" ~some:(fun m -> "." ^ m) member)
          in
          let homes =
            List.filter_map Verb_signatures.home [ built ] @ [ S.Package ctx.package ]
          in
          let cands =
            match Verb_signatures.type_key built with
            | None -> []
            | Some key ->
                Hashtbl.find_all env.constructors key
                |> List.rev
                |> List.filter (fun (s : S.t) ->
                       (match s.kind with S.Constructor c -> c.member = member | _ -> false)
                       && List.mem s.home homes && accessible_sig ctx s)
          in
          no_handler ();
          if cands = [] then begin
            type_args ();
            error env span
              (Printf.sprintf "%s has no constructor%s" (quote (Ty.to_string built))
                 (match member with Some m -> " named " ^ quote m | None -> ""));
            invalid span
          end
          else
            match args.N.Constructor_args.node with
            | N.Constructor_args.Positional ps -> (
                let actuals = List.map (actual_of env ctx) ps in
                if any_error actuals then invalid span
                else
                  match
                    report_resolution env ~literal:(literal_drives_inference cands actuals) ~span ~what
                      ~args:(describe_args actuals)
                      (resolve env (List.filter (fun (s : S.t) -> match s.kind with S.Constructor { fields; _ } -> not fields | _ -> false) cands)
                         (positional actuals))
                      cands
                  with
                  | None -> invalid span
                  | Some o ->
                      request env ~args:o.converted o.sig_ o.subst span;
                      let ret = Ty.subst o.subst o.sig_.ret in
                      mk
                        (T.Expr.Construct
                           { ctor = verb_ref o.sig_ o.subst; args = List.filter_map Fun.id o.converted; handler = None })
                        ret span)
            | N.Constructor_args.Fields fs -> field_constructor_call env ctx span what cands fs))

(* `Type{ a = x; b = y; }` against the field constructors: each entry fills
   the slot of the same name and is a coercion site; an entry left out must
   have a default (types.md §3.3). *)
and field_constructor_call env ctx span what cands (fs : N.Field_arg.t list) =
  let seen = Hashtbl.create 8 in
  let entries =
    List.map
      (fun (f : N.Field_arg.t) ->
        let name = f.N.Field_arg.name.N.Name.text in
        if Hashtbl.mem seen name then
          error env f.N.Field_arg.name.N.Name.span (Printf.sprintf "the field %s is given twice" (quote name))
        else Hashtbl.add seen name ();
        let v = expr env ctx f.N.Field_arg.value in
        (name, f, { arg = T.Arg.Value v; aty = v.T.Expr.ty; aspan = v.T.Expr.span; subject = false }))
      fs
  in
  let field_cands =
    List.filter (fun (s : S.t) -> match s.kind with S.Constructor { fields; _ } -> fields | _ -> false) cands
  in
  let slots_for (s : S.t) =
    let names = List.map (fun (p : S.param) -> p.name) s.params in
    if List.exists (fun (n, _, _) -> not (List.mem n names)) entries then None
    else
      Some
        (List.map
           (fun (p : S.param) ->
             List.find_map (fun (n, _, a) -> if String.equal n p.name then Some a else None) entries)
           s.params)
  in
  if List.exists (fun (_, _, a) -> Ty.contains_error a.aty) entries then invalid span
  else if field_cands = [] then begin
    error env span (Printf.sprintf "%s has no field constructor" what);
    invalid span
  end
  else
    let args =
      "{" ^ String.concat "; " (List.map (fun (n, _, a) -> n ^ " = " ^ Ty.to_string a.aty) entries) ^ "}"
    in
    match report_resolution env ~span ~what ~args (resolve env field_cands slots_for) field_cands with
    | None -> invalid span
    | Some o ->
        request env ~args:o.converted o.sig_ o.subst span;
        let converted = List.combine o.sig_.params o.converted in
        let fields =
          List.filter_map
            (fun (name, (f : N.Field_arg.t), _) ->
              let rec find i = function
                | [] -> None
                | ((p : S.param), Some (T.Arg.Value v)) :: _ when String.equal p.name name ->
                    Some { T.Field_value.name; slot = i; value = v; span = f.N.Field_arg.span }
                | _ :: rest -> find (i + 1) rest
              in
              find 0 converted)
            entries
        in
        mk
          (T.Expr.Construct_fields { ctor = verb_ref o.sig_ o.subst; fields; handler = None })
          (Ty.subst o.subst o.sig_.ret) span

(* adt.md §3.2: naming a case and supplying its one payload, which is a
   coercion site. Not a constructor verb, so there is nothing to name. *)
and case_form env ctx span tid payload built open_ case (args : N.Constructor_args.t) =
  match args.N.Constructor_args.node with
  | N.Constructor_args.Positional [ a ] -> (
      let actual = actual_of env ctx a in
      if Ty.contains_error actual.aty then invalid span
      else
        let s =
          {
            S.owner = S.Intrinsic "<case>";
            name = tid.Ty.name ^ "." ^ case;
            home = S.Package tid.Ty.package;
            kind = S.Function;
            generics = open_;
            params = [ { S.name = case; ty = payload; binds = None; has_default = false } ];
            ret = built;
            abort = None;
            is_mut = false;
          }
        in
        match
          report_resolution env ~span ~what:(quote s.S.name) ~args:(describe_args [ actual ])
            (resolve env [ s ] (positional [ actual ])) [ s ]
        with
        | None -> invalid span
        | Some o -> (
            match o.converted with
            | [ Some (T.Arg.Value v) ] -> mk (T.Expr.Case { case; payload = v }) (Ty.subst o.subst built) span
            | _ -> invalid span))
  | N.Constructor_args.Positional ps ->
      List.iter (fun a -> ignore (actual_of env ctx a)) ps;
      error env span
        (Printf.sprintf "a case carries exactly one payload, so `%s.%s(...)` takes one argument"
           tid.Ty.name case);
      invalid span
  | N.Constructor_args.Fields fs ->
      List.iter (fun (f : N.Field_arg.t) -> ignore (expr env ctx f.N.Field_arg.value)) fs;
      error env span
        (Printf.sprintf "a case is built from one positional payload, `%s.%s(value)`" tid.Ty.name case);
      invalid span

(* operators.md §2.2: the candidates are the operand types' home packages'
   operators, and nothing an import brings. Operands evaluate in written
   order and are passed in the order the desugaring gives (§2.3). *)
(* ---------------------------------------------------------------------- *)
(* Calls: operators, flips and spawns                                     *)
(* ---------------------------------------------------------------------- *)

and operator env ~flow ctx span (op : N.Operator.t) left right ~swapped handle =
  let left = expr env ctx left and right = expr env ctx right in
  let token = Intrinsics.operator_token op.N.Operator.node in
  let passed = if swapped then [ right; left ] else [ left; right ] in
  let actuals =
    List.map (fun (e : T.Expr.t) -> { arg = T.Arg.Value e; aty = e.T.Expr.ty; aspan = e.T.Expr.span; subject = false }) passed
  in
  if any_error actuals then (skip_handler env ctx handle; (invalid span, None))
  else
    let homes = List.filter_map (fun (e : T.Expr.t) -> Verb_signatures.home e.T.Expr.ty) passed in
    let cands =
      Hashtbl.find_all env.operators op.N.Operator.node |> List.rev
      |> List.filter (fun (s : S.t) -> List.mem s.home homes)
    in
    if cands = [] then begin
      error env span
        (Printf.sprintf "no operator %s is declared for %s in the home package of either operand"
           (quote token) (describe_args actuals));
      skip_handler env ctx handle;
      (invalid span, None)
    end
    else
      match
        report_resolution env ~span ~what:(Printf.sprintf "operator %s" (quote token))
          ~args:(describe_args actuals) (resolve env cands (positional actuals)) cands
      with
      | None ->
          skip_handler env ctx handle;
          (invalid span, None)
      | Some o ->
          finish_call env ~flow ctx ~span ~what:(quote token) o handle (fun impl args handler ->
              match List.filter_map arg_expr args with
              | [ a; b ] ->
                  let left, right = if swapped then (b, a) else (a, b) in
                  T.Expr.Op { op = op.N.Operator.node; impl; left; right; swapped; handler }
              | _ -> T.Expr.Invalid)

and flip env ~flow ctx span value handle =
  let value = expr env ctx value in
  let actual = { arg = T.Arg.Value value; aty = value.T.Expr.ty; aspan = value.T.Expr.span; subject = false } in
  if Ty.contains_error value.T.Expr.ty then (skip_handler env ctx handle; (invalid span, None))
  else
    let homes = Option.to_list (Verb_signatures.home value.T.Expr.ty) in
    let cands = List.filter (fun (s : S.t) -> List.mem s.home homes) !(env.flips) in
    if cands = [] then begin
      error env span
        (Printf.sprintf "no operator `~` is declared for %s in its home package"
           (quote (Ty.to_string value.T.Expr.ty)));
      skip_handler env ctx handle;
      (invalid span, None)
    end
    else
      match
        report_resolution env ~span ~what:"operator `~`" ~args:(describe_args [ actual ])
          (resolve env cands (positional [ actual ])) cands
      with
      | None ->
          skip_handler env ctx handle;
          (invalid span, None)
      | Some o ->
          finish_call env ~flow ctx ~span ~what:"`~`" o handle (fun impl args handler ->
              match List.filter_map arg_expr args with
              | [ v ] -> T.Expr.Flip { impl; value = v; handler }
              | _ -> T.Expr.Invalid)

(* concurrency.md §3.1, syntax.md §4.4. *)
and spawn env ctx (call : N.Verb_call.t) =
  let span = call.N.Verb_call.span in
  let e, s = verb_call env ~flow:false ctx call in
  (match (e.T.Expr.node, s) with
  | T.Expr.Invalid, _ -> ()
  | T.Expr.Call _, Some s ->
      if S.has_block_param s then
        error env span
          (Printf.sprintf "%s takes a block, and a verb that takes a block cannot be spawned"
             (quote s.name))
  | T.Expr.Call_value _, _ -> ()
  | _ -> error env span "`spawn` starts a function or method call, and this is neither");
  mk (T.Expr.Spawn e) e.T.Expr.ty span

(* ---------------------------------------------------------------------- *)
(* Match                                                                  *)
(* ---------------------------------------------------------------------- *)

and match_ env ~flow ctx (m : N.Match_expr.t) =
  let span = m.N.Match_expr.span in
  let scrutinees = List.map (expr env ctx) m.N.Match_expr.scrutinees in
  let shapes =
    List.map
      (fun (s : T.Expr.t) ->
        match (s.T.Expr.ty, definition env s.T.Expr.ty) with
        | Ty.Error, _ -> `Unknown
        | _, Some (tid, Variant cases) -> `Variant (tid, cases)
        | _, Some (tid, Enum members) -> `Enum (tid, members)
        | t, _ ->
            error env s.T.Expr.span
              (Printf.sprintf "a match dispatches on a variant or an enum, and %s is neither"
                 (quote (Ty.to_string t)));
            `Unknown)
      scrutinees
  in
  let results = { results = []; aborts = [] } in
  let arm_ctx = { ctx with ret_target = To_arm results } in
  let covered = Hashtbl.create 16 in
  let arms =
    List.map
      (fun (arm : N.Match_arm.t) ->
        let inner = push arm_ctx in
        let patterns = arm.N.Match_arm.patterns in
        if List.length patterns <> List.length shapes then
          error env arm.N.Match_arm.span
            (Printf.sprintf "this arm selects %d case%s, and the match has %d scrutinee%s"
               (List.length patterns) (if List.length patterns = 1 then "" else "s")
               (List.length shapes) (if List.length shapes = 1 then "" else "s"));
        let typed =
          List.mapi
            (fun i (p : N.Match_pattern.t) ->
              let case = p.N.Match_pattern.case.N.Name.text in
              let shape = match List.nth_opt shapes i with Some s -> s | None -> `Unknown in
              let payload =
                match shape with
                | `Variant (tid, cases) -> (
                    match List.assoc_opt case cases with
                    | Some t -> Some t
                    | None ->
                        error env p.N.Match_pattern.case.N.Name.span
                          (Printf.sprintf "%s has no case %s" (quote tid.Ty.name) (quote case));
                        Some Ty.Error)
                | `Enum (tid, members) ->
                    if not (List.mem case members) then
                      error env p.N.Match_pattern.case.N.Name.span
                        (Printf.sprintf "%s has no member %s" (quote tid.Ty.name) (quote case));
                    (match p.N.Match_pattern.binder with
                    | Some b ->
                        error env b.N.Name.span
                          (Printf.sprintf "%s is an enum member and carries no payload to bind" (quote case))
                    | None -> ());
                    None
                | `Unknown -> Some Ty.Error
              in
              let binder =
                match (p.N.Match_pattern.binder, payload) with
                | Some b, Some t -> Some (declare env inner Binder b t)
                | _ -> None
              in
              { T.Pattern.binder; case; span = p.N.Match_pattern.span })
            patterns
        in
        let key = String.concat "," (List.map (fun (p : T.Pattern.t) -> p.T.Pattern.case) typed) in
        (match Hashtbl.find_opt covered key with
        | Some (first : Span.t) ->
            error env arm.N.Match_arm.span
              (Printf.sprintf "%s is already covered by the arm at %s; every case is covered exactly once"
                 (quote key) (where first))
        | None -> Hashtbl.add covered key arm.N.Match_arm.span);
        let body = block_in env inner arm.N.Match_arm.body in
        if not (ends ~resolve:false body.T.Block.stats) then
          error env arm.N.Match_arm.body.N.Block.span "every path through a match arm ends in `return` or `abort`";
        { T.Arm.patterns = typed; body; span = arm.N.Match_arm.span })
      m.N.Match_expr.arms
  in
  (* Every combination of cases, covered (adt.md §5.2, §5.6). *)
  if List.for_all (fun s -> s <> `Unknown) shapes && List.length shapes > 0 then begin
    let cases_of = function
      | `Variant (_, cases) -> List.map fst cases
      | `Enum (_, members) -> members
      | `Unknown -> []
    in
    let combos =
      List.fold_right
        (fun shape acc -> List.concat_map (fun c -> List.map (fun rest -> c :: rest) acc) (cases_of shape))
        shapes [ [] ]
    in
    let missing = List.filter (fun combo -> not (Hashtbl.mem covered (String.concat "," combo))) combos in
    if missing <> [] then
      let shown = List.filteri (fun i _ -> i < 3) missing in
      error env span
        (Printf.sprintf "the match does not cover %s%s; every case needs an arm, and there is no default"
           (String.concat ", " (List.map (fun c -> quote (String.concat ", " c)) shown))
           (if List.length missing > 3 then Printf.sprintf " (and %d more)" (List.length missing - 3) else ""))
  end;
  let ty =
    match results.results with
    | [] -> Ty.Error
    | (first, _) :: rest ->
        List.iter
          (fun (t, at) ->
            if not (Ty.equal t first) then
              error env at
                (Printf.sprintf
                   "every arm of a match yields one type: this yields %s, and the first \
                    arm yields %s; an arm is not a coercion site"
                   (quote (Ty.to_string t)) (quote (Ty.to_string first))))
          rest;
        first
  in
  let abort =
    match results.aborts with
    | [] -> None
    | (first, _) :: rest ->
        List.iter
          (fun (t, at) ->
            if not (Ty.equal t first) then
              error env at
                (Printf.sprintf "the arms of a match abort with one type: this is %s, and an earlier arm's is %s"
                   (quote (Ty.to_string t)) (quote (Ty.to_string first))))
          rest;
        Some first
  in
  let handler = owe_handler env ~flow ctx ~what:"this match" ~span ~abort ~ok:ty m.N.Match_expr.abort_handle in
  mk (T.Expr.Match { scrutinees; arms; handler }) ty span

(* ---------------------------------------------------------------------- *)
(* Lambdas                                                                *)
(* ---------------------------------------------------------------------- *)

(* A lambda does not capture (functions.md §7.4): its body sees its own
   parameters and the package-scope names of its file, and no local of the
   verb it is written in. *)
and lambda env ctx span ~this_type ~params ~ret_type ~is_mut ~body =
  let sc = type_scope ctx in
  let inner_scope = Hashtbl.create 8 in
  let this_ =
    Option.map
      (fun te ->
        let t = Type_decls.resolve env sc te in
        let local = fresh_local env "this" t te.N.Type_expr.span in
        Hashtbl.replace inner_scope "this" { local; role = This };
        (t, local))
      this_type
  in
  let ps =
    List.map
      (fun (p : N.Param.t) ->
        let t = Type_decls.param_type env sc p.N.Param.type_ in
        let local = fresh_local env p.N.Param.name.N.Name.text t p.N.Param.span in
        Hashtbl.replace inner_scope local.T.Local.name { local; role = Parameter };
        (t, local))
      params
  in
  let ret, abort = Type_decls.ret_type_of env sc ret_type in
  let inner =
    {
      ctx with
      scopes = [ inner_scope ];
      ret_target = To_verb { ret; abort };
      resolve_target = No_resolve;
      this_type = Option.map fst this_;
      is_mut;
      building = None;
    }
  in
  let typed = block_in env inner body in
  if not (ends ~resolve:false typed.T.Block.stats) then
    error env body.N.Block.span "not every path through this lambda returns; a block body returns explicitly";
  let v = { Ty.this_ = Option.map fst this_; params = List.map fst ps; ret; abort; is_mut } in
  (match this_ with
  | Some (((Ty.Reference _ | Ty.Roaming _) as t), _) ->
      error env span
        (Printf.sprintf
           "the subject is written %s, and it is always a borrow, so neither `^` nor `&` is \
            written on `this`"
           (quote (Ty.to_string t)))
  | _ -> ());
  Type_decls.check_function_types env span (Ty.Verb v);
  mk
    (T.Expr.Lambda { params = List.map snd (Option.to_list this_) @ List.map snd ps; body = typed })
    (Ty.Verb v) span

(* ---------------------------------------------------------------------- *)
(* Statements                                                             *)
(* ---------------------------------------------------------------------- *)

and block_in env ctx (b : N.Block.t) : T.Block.t =
  { T.Block.stats = List.map (stat env ctx) b.N.Block.stats; span = b.N.Block.span }

and stat env ctx (s : N.Stat.t) : T.Stat.t =
  let span = s.N.Stat.span in
  let node =
    match s.N.Stat.node with
    | N.Stat.VerbCall call -> T.Stat.Expr (fst (verb_call env ~flow:false ctx call))
    | N.Stat.Spawn call -> T.Stat.Spawn (spawn env ctx call)
    | N.Stat.Decl d -> local_declaration env ctx d
    | N.Stat.Assign { target; value } -> assign env ctx span target value
    | N.Stat.Abort value -> (
        let v = expr env ctx value in
        match ctx.ret_target with
        | To_verb { abort = None; _ } ->
            error env span "`abort` leaves by the abort path, and this verb declares no abort type";
            T.Stat.Abort v
        | To_verb { abort = Some a; _ } ->
            if not (Ty.assignable ~dst:a ~src:v.T.Expr.ty) then
              error env v.T.Expr.span
                (Printf.sprintf "this aborts with %s, and the verb's abort type is %s"
                   (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string a)));
            T.Stat.Abort v
        | To_arm r ->
            r.aborts <- r.aborts @ [ (v.T.Expr.ty, v.T.Expr.span) ];
            T.Stat.Abort v
        | No_return ->
            error env span "`abort` leaves a verb, and this is not in one";
            T.Stat.Abort v)
    | N.Stat.Ret value -> (
        match ctx.ret_target with
        | To_arm r ->
            let v = expr env ~flow:true ctx value in
            escapes env v;
            r.results <- r.results @ [ (v.T.Expr.ty, v.T.Expr.span) ];
            T.Stat.Return v
        | To_verb { ret; _ } ->
            let v = expr env ctx value in
            escapes env v;
            if not (Ty.assignable ~dst:ret ~src:v.T.Expr.ty) then
              error env v.T.Expr.span
                (Printf.sprintf
                   "this returns %s, and the verb returns %s; `return` is not a coercion \
                    site, so a conversion is written out"
                   (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string ret)));
            T.Stat.Return v
        | No_return ->
            let v = expr env ctx value in
            error env span "`return` leaves a verb, and this is not in one";
            T.Stat.Return v)
    | N.Stat.Resolve value -> (
        let v = expr env ctx value in
        match ctx.resolve_target with
        | To_handler ok ->
            if not (Ty.assignable ~dst:ok ~src:v.T.Expr.ty) then
              error env v.T.Expr.span
                (Printf.sprintf
                   "this resolves %s, and the handled operation yields %s; `resolve` is \
                    not a coercion site"
                   (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string ok)));
            T.Stat.Resolve v
        | No_resolve ->
            error env span
              "`resolve` finishes a handler, and this is in none: a block yields nothing, so \
               it is not one";
            T.Stat.Resolve v)
  in
  { T.Stat.node; span }

(* A block never escapes the call it is written at (control-flow.md §2.2). *)
and escapes env (v : T.Expr.t) =
  match v.T.Expr.ty with
  | Ty.Concept Ty.Block ->
      error env v.T.Expr.span "a block cannot be returned: it never escapes the call it is written at"
  | _ -> ()

(* A declaration is not a coercion site (types.md §4.2): the value has the
   declared type already. *)
and local_declaration env ctx (d : N.Decl.t) =
  match d.N.Decl.node with
  | N.Decl.Var { name; type_; value } ->
      let v = expr env ctx value in
      let declared = declared_type env ctx type_ v.T.Expr.ty in
      Type_decls.check_storage env ~roaming:true type_.N.Type_expr.span "a local" declared;
      Type_decls.check_function_types env type_.N.Type_expr.span declared;
      if not (Ty.assignable ~dst:declared ~src:v.T.Expr.ty) then
        error env v.T.Expr.span
          (Printf.sprintf
             "%s is declared %s, and its value is %s; a declaration is not a coercion \
              site, so a conversion is written out"
             (quote name.N.Name.text) (quote (Ty.to_string declared))
             (quote (Ty.to_string v.T.Expr.ty)));
      let local = declare env ctx Symbol name declared in
      T.Stat.Let { local; value = v }
  | _ ->
      error env d.N.Decl.span "only a symbol is declared in a body; every other declaration is at package scope";
      T.Stat.Expr (invalid d.N.Decl.span)

(* `p Pair(Int(1), Int(2))` declares `p` as the bare `Pair`, since the
   shorthand writes the constructor's name and a call carries no `< >`
   (docs/design/desugaring.md §2.7). A generic type named with no arguments takes
   them from the value it is declared with. *)
and declared_type env ctx (te : N.Type_expr.t) (value_ty : Ty.t) =
  match te.N.Type_expr.node with
  | N.Type_expr.Path { name; generics = [] } -> (
      match Type_decls.resolve_head env (type_scope ctx) name with
      | Type_decls.Declared d as head -> (
          match (Hashtbl.find_opt env.type_infos d.id, Ty.strip_mode value_ty) with
          | Some info, Ty.Named (tid, _) when info.params <> [] && tid = info.tid -> Ty.strip_mode value_ty
          | Some info, Ty.Error when info.params <> [] -> Ty.Error
          | _ -> Type_decls.apply env (type_scope ctx) te.N.Type_expr.span head name [])
      | Type_decls.Intrinsic_type info as head when info.params <> [] -> (
          match Ty.strip_mode value_ty with
          | Ty.Intrinsic { namespace; name = n; _ } when namespace = info.namespace && n = info.name ->
              Ty.strip_mode value_ty
          | Ty.Error -> Ty.Error
          | _ -> Type_decls.apply env (type_scope ctx) te.N.Type_expr.span head name [])
      | Type_decls.Unknown -> Ty.Error
      | head -> Type_decls.apply env (type_scope ctx) te.N.Type_expr.span head name [])
  | _ -> Type_decls.resolve env (type_scope ctx) te

(* The binding a place is reached through. A field, an element or a case
   payload of a read-only binding is read-only too (effects.md §4.1). A case
   read is a subject a `!` call may name, but not a place an assignment may
   write, so only [~cases] follows it. *)
and place_root ?(cases = false) (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> `Local l
  | T.Expr.Var (T.Name_ref.Global _) -> `Global
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } -> place_root ~cases target
  | T.Expr.Case_read { target; _ } when cases -> place_root ~cases target
  | T.Expr.Invalid -> `Invalid
  | _ -> `Not_place

(* effects.md §4.1: a verb writes a place by assigning to it or by making it
   the subject of a `!` call, and a read-only binding admits neither. The
   read-only bindings are every parameter other than `this`, and `this` in a
   method without `mut`. [bang] says the write is a `!` call. *)
and check_writable env ctx (e : T.Expr.t) ~bang =
  let say plain because =
    error env e.T.Expr.span
      (if bang then "a `!` call writes its subject, and " ^ because else plain)
  in
  match place_root ~cases:bang e with
  | `Invalid | `Not_place -> ()
  | `Global ->
      say "a package constant is immutable: package scope holds no mutable state"
        "a package constant is immutable"
  | `Local l -> (
      let name = quote l.T.Local.name in
      match find_local ctx l.T.Local.name with
      | Some { role = Parameter; _ } ->
          say
            (Printf.sprintf "%s is a parameter, and a parameter is read-only" name)
            (Printf.sprintf "%s is a parameter, which is read-only" name)
      | Some { role = This; _ } when not ctx.is_mut ->
          say "a method that is not `mut` may not write through `this`"
            "`this` is read-only in a method that is not `mut`"
      | _ -> ())

(* functions.md §2.3, §2.7; packages.md §5.1. *)
and assign env ctx span target value =
  let t = expr env ctx target in
  let v = expr env ctx value in
  (match place_root t with
  | `Not_place -> error env t.T.Expr.span "only a symbol, a field or a subscript can be assigned"
  | _ -> check_writable env ctx t ~bang:false);
  if not (Ty.assignable ~dst:t.T.Expr.ty ~src:v.T.Expr.ty) then
    error env v.T.Expr.span
      (Printf.sprintf
         "this assigns %s to %s; an assignment is not a coercion site, so a conversion \
          is written out"
         (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string t.T.Expr.ty)));
  ignore span;
  T.Stat.Assign { target = t; value = v }

(* ---------------------------------------------------------------------- *)
(* Subscripts                                                             *)
(* ---------------------------------------------------------------------- *)

(* A subscript declares no result type: it is the type of the place its body
   projects (functions.md §2.9), typed per set of arguments like any generic
   body. *)
and subscript_key id subst (s : S.t) =
  string_of_int id ^ ":"
  ^ String.concat "," (List.map (fun (_, a) -> Ty.arg_to_string a) (binding_args s subst))

and subscript_result env (d : decl) (s : S.t) subst at =
  let key = subscript_key d.id subst s in
  match Hashtbl.find_opt env.subscript_results key with
  | Some (Some t) -> t
  | Some None ->
      error env at "this subscript's type depends on itself";
      Ty.Error
  | None -> (
      Hashtbl.replace env.subscript_results key None;
      let body () = subscript_body env d s subst in
      let checked = if subst <> [] then with_note env (describe_instance s subst at) body else body () in
      match checked with
      | Some (locals, v) ->
          Hashtbl.replace env.subscript_results key (Some v.T.Expr.ty);
          Hashtbl.replace env.subscript_instances key (s, subst, locals, v);
          v.T.Expr.ty
      | None -> Ty.Error)

(* A subscript's body typed at one set of arguments, with its parameters as
   locals. *)
and subscript_body env (d : decl) (s : S.t) subst =
  match d.kind with
  | Verb { N.Verb_decl.node = N.Verb_decl.Subscript { value; _ }; _ } ->
      let ctx, locals = verb_context env d s subst in
      let v = expr env ctx value in
      let rec is_place (e : T.Expr.t) =
        match e.T.Expr.node with
        | T.Expr.Var (T.Name_ref.Local _) -> true
        | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } -> is_place target
        | T.Expr.Invalid -> true
        | _ -> false
      in
      if not (is_place v) then
        error env v.T.Expr.span
          "a subscript's body is a place expression: a symbol, a field of one, or a \
           subscript of one (syntax.md §3.6)";
      Some (locals, v)
  | _ -> None

(* ---------------------------------------------------------------------- *)
(* Verb bodies                                                            *)
(* ---------------------------------------------------------------------- *)

(* Where each of a verb's parameters was written, by name: the spans its
   locals take, the same ones a lambda's parameters take. *)
and param_spans (d : decl) =
  let params ps = List.map (fun (p : N.Param.t) -> (p.N.Param.name.N.Name.text, p.N.Param.span)) ps in
  let this_ (t : N.Type_expr.t) = ("this", t.N.Type_expr.span) in
  match d.kind with
  | Verb v -> (
      match v.N.Verb_decl.node with
      | N.Verb_decl.Func { params = ps; _ }
      | N.Verb_decl.Op { params = ps; _ }
      | N.Verb_decl.Flip { params = ps; _ } ->
          params ps
      | N.Verb_decl.Meth { this_type; params = ps; _ }
      | N.Verb_decl.Subscript { this_type; params = ps; _ } ->
          this_ this_type :: params ps
      | N.Verb_decl.Constructor { params = { N.Constructor_params.node = N.Constructor_params.Positional ps; _ }; _ } ->
          params ps
      | N.Verb_decl.Constructor { params = { N.Constructor_params.node = N.Constructor_params.Fields fs; _ }; _ } ->
          List.map
            (fun (f : N.Constructor_field.t) -> (f.N.Constructor_field.name.N.Name.text, f.N.Constructor_field.span))
            fs)
  | _ -> []

(* The context a verb's body is checked in, at one set of generic arguments:
   its parameters as locals, and the explicit `T Type` / `n @concepts$Int` ones as the
   types and numbers they were given. *)
and verb_context env (d : decl) (s : S.t) subst =
  let pkg = package env d.package in
  let spans = param_spans d in
  let span_of name = Option.value ~default:d.span (List.assoc_opt name spans) in
  let params = List.map (fun ((p : Ty.param), a) -> (p.name, a)) (binding_args s subst) in
  let scope = Hashtbl.create 8 in
  let locals =
    List.filter_map
      (fun (p : S.param) ->
        match p.binds with
        | Some _ -> None
        | None ->
            let local = fresh_local env p.name (Ty.subst subst p.ty) (span_of p.name) in
            let role = if p.name = "this" && S.is_method s then This else Parameter in
            Hashtbl.replace scope p.name { local; role };
            Some local)
      s.params
  in
  let this_type =
    if S.is_method s then Option.map (fun (p : S.param) -> Ty.subst subst p.ty) (List.nth_opt s.params 0)
    else None
  in
  let ctx =
    {
      file = d.file;
      package = d.package;
      is_root = pkg.is_root;
      params;
      scopes = [ scope ];
      ret_target = To_verb { ret = Ty.subst subst s.ret; abort = Option.map (Ty.subst subst) s.abort };
      resolve_target = No_resolve;
      this_type;
      is_mut = s.is_mut;
      building = (match s.kind with S.Constructor _ -> Some (Ty.subst subst s.ret) | _ -> None);
    }
  in
  (ctx, locals)

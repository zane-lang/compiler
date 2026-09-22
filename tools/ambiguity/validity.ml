(* The syntax rules the compiler enforces after parsing, modelled where the
   recognizer can apply them to one derivation at a time.

   What the raw grammar accepts and what Zane accepts are deliberately not the
   same language. A statement's `;` is optional in the grammar because whether
   it is required depends on whether the statement ends in a `}`, and that is
   not a question the parser can answer when it has to choose -- so the
   grammar takes either spelling, [Statement_shape] records the mismatch, and
   [Statement_check] rejects the surviving tree afterwards. See
   `docs/ambiguity/proof-obligations.md`, "What a semantic action may do".

   A recognizer that counts raw derivations therefore counts readings that are
   not programs, and two of those are not an ambiguity of Zane. The check
   cannot be deferred here the way the compiler defers it, because there is no
   tree to walk afterwards and the whole question is how many *derivations*
   survive rather than whether one did. So it is applied where the derivation
   is still separable: at the reduction that completes a statement, which is
   the only place the rule is about.

   The rule needs no tree. [Statement_shape.expr_ends_in_brace] and its
   siblings walk the tail of a statement's tree to answer one question --
   whether the statement's last token is a `}` -- and at the reduction that
   completes the statement, that token is simply the one last shifted. Every
   form in that walk agrees: a map literal, a field body, a match's arms and a
   call's trailing argument end on the brace and answer yes; a subscript, a
   collection, parentheses and a bare name end on `]`, `)` or the name and
   answer no.

   So a statement is spelled correctly exactly when, at the point it is
   reduced, either its last token is the closer and no terminator follows it,
   or a terminator ends it and the token before that terminator is not the
   closer. One predicate covers every statement form, including the two the
   grammar itself settles -- a braced statement ends on the closer, and
   `header_decl ";"` ends on a terminator preceded by a name. *)

open Automaton

type t = {
  (* The nonterminal whose reduction completes a statement. *)
  statement : string;
  (* The terminal that closes a statement on its own. *)
  closer : string;
  (* The terminal that closes every statement not ending in [closer]. *)
  terminator : string;
}

let zane = { statement = "stat"; closer = "RCURLY"; terminator = "SEMICOLON" }

let describe model =
  Printf.sprintf
    "a %s must end in %s, or in %s preceded by something other than %s"
    model.statement model.closer model.terminator model.closer

let reduces_to automaton name =
  Array.exists
    (fun state ->
      Hashtbl.fold
        (fun _ reductions found ->
          found || List.exists (fun reduction -> reduction.lhs = name) reductions)
        state.reductions false)
    automaton.states

(* Whether this grammar is the one the model is about.

   The model names Zane's own statement rule, so it must be inert on every
   other grammar a run may be pointed at -- the soundness corpus is grammars
   ambiguous or unambiguous by construction, and a filter that fired on one
   would be measuring something other than the grammar. Requiring all three
   names is what keeps it inert: a grammar reducing a [stat] while declaring
   both terminals is Zane's grammar or a reproducer cut from it, which is
   exactly where the rule holds. *)
let detect automaton =
  if
    reduces_to automaton zane.statement
    && StringSet.mem zane.closer automaton.terminals
    && StringSet.mem zane.terminator automaton.terminals
  then begin
    (* The search tries one terminal per equivalence class, which is sound
       because swapping two members is an automorphism of the recognition
       relation. This model gives [closer] and [terminator] meaning beyond the
       automaton's shape, so a class holding either alongside another terminal
       would no longer be interchangeable and the search would skip sentences
       that differ where the model reads. Both are singletons in the grammar
       today; a grammar change that merged one is a broken assumption rather
       than a slower run, so it stops the tool instead of being counted on. *)
    List.iter
      (fun terminal ->
        let identity = Hashtbl.find_opt automaton.terminal_class terminal in
        let shared =
          Hashtbl.fold
            (fun other other_identity found ->
              found || (other <> terminal && Some other_identity = identity))
            automaton.terminal_class false
        in
        if shared then
          failwith
            (terminal
           ^ " shares a terminal equivalence class, which the validity model \
              cannot be applied under; pass --raw-derivations to measure the \
              grammar without it"))
      [ zane.closer; zane.terminator ];
    Some zane
  end
  else None

(* What the tokens already shifted say about a statement ending here, as three
   bits.

   Small and comparable because it joins the closure cache's key: a reduction
   the model refuses at one point in a sentence is taken at another, so a
   cache keyed on the stack and the lookahead alone would answer the second
   with the first. These three bits are the whole of what the decision reads,
   so two steps agreeing on them agree on every reduction. *)
let ends_with_terminator = 1
let ends_with_closer = 2
let terminator_follows_closer = 4

let context model shifted =
  match shifted with
  | [] -> 0
  | last :: earlier ->
      let before = match earlier with [] -> "" | token :: _ -> token in
      (if last = model.terminator then ends_with_terminator else 0)
      lor (if last = model.closer then ends_with_closer else 0)
      lor
      if last = model.terminator && before = model.closer then
        terminator_follows_closer
      else 0

(* Whether the derivation this reduction belongs to is still a program.

   Only a statement's own reduction is judged. Everything else -- the
   expression inside it, the list it joins, the body around that -- carries no
   rule of this kind, and refusing any of them would remove derivations the
   compiler accepts. *)
let admits model context (reduction : reduction) =
  reduction.lhs <> model.statement
  || (if context land ends_with_terminator <> 0 then
        context land terminator_follows_closer = 0
      else context land ends_with_closer <> 0)

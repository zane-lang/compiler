import Ambiguity.Mly
import Ambiguity.Automaton

/-!
# The canonical LR(1) automaton of the source grammar

The source parse relation is defined by the canonical LR(1) automaton of the
expanded grammar (Knuth's construction, end of input `#`), with conflicts
resolved by the precedence declarations exactly as Menhir's manual (§6.3,
"When is a conflict benign?") specifies:

* one reduction against a shift: the higher level wins; at equal levels the
  token's associativity decides (left: reduce, right: shift, nonassoc:
  neither);
* several reductions against a shift: resolved only if every reduction,
  taken alone, resolves the same way in favour of shifting or of neither;
* anything else is a severe conflict, whose resolution Menhir leaves
  unspecified, so every one of its actions is retained.

The construction is part of the definition of the source relation, which is
`Accepted (canonical g)` for the grammar `g` that `Mly.sourceGrammar` reads
from `parser.mly`.
-/

namespace Ambiguity.Lr1

open Mly

/-- An item: production (the augmented start production is `prods.size`),
dot position, lookahead. -/
abbrev Item := Nat × Nat × Tok

structure Ctx where
  g : Grammar
  isNt : Std.HashSet String
  prodsOf : Std.HashMap String (List Nat)
  nullable : Std.HashSet String
  first : Std.HashMap String (Std.HashSet Tok)

def Ctx.rhs (c : Ctx) (p : Nat) : List String :=
  if p < c.g.prods.size then c.g.prods[p]!.rhs else [c.g.start]

def mkCtx (g : Grammar) : Ctx := Id.run do
  let isNt : Std.HashSet String := g.prods.foldl (fun s p => s.insert p.lhs) {}
  let mut prodsOf : Std.HashMap String (List Nat) := {}
  for i in [0:g.prods.size] do
    let p := g.prods[i]!
    prodsOf := prodsOf.insert p.lhs ((prodsOf.getD p.lhs []) ++ [i])
  -- nullable symbols
  let mut nullable : Std.HashSet String := {}
  let mut changed := true
  while changed do
    changed := false
    for p in g.prods do
      if !nullable.contains p.lhs && p.rhs.all nullable.contains then
        nullable := nullable.insert p.lhs; changed := true
  -- FIRST sets of nonterminals
  let mut first : Std.HashMap String (Std.HashSet Tok) := {}
  changed := true
  while changed do
    changed := false
    for p in g.prods do
      let mut acc := first.getD p.lhs {}
      let before := acc.size
      for s in p.rhs do
        if isNt.contains s then
          for t in first.getD s {} do acc := acc.insert t
          if !nullable.contains s then break
        else
          acc := acc.insert s; break
      if acc.size != before then
        first := first.insert p.lhs acc; changed := true
  return { g, isNt, prodsOf, nullable, first }

/-- FIRST of a symbol string followed by a lookahead. -/
def Ctx.firstSeq (c : Ctx) (β : List String) (la : Tok) : List Tok := Id.run do
  let mut acc : Std.HashSet Tok := {}
  for s in β do
    if c.isNt.contains s then
      for t in c.first.getD s {} do acc := acc.insert t
      if !c.nullable.contains s then return acc.toList
    else
      return (acc.insert s).toList
  return (acc.insert la).toList

/-- The closure of a kernel. -/
def Ctx.closure (c : Ctx) (kernel : List Item) : Array Item := Id.run do
  let mut seen : Std.HashSet Item := {}
  let mut out : Array Item := #[]
  let mut stack := kernel
  while true do
    match stack with
    | [] => break
    | it :: rest =>
      stack := rest
      if seen.contains it then continue
      seen := seen.insert it
      out := out.push it
      let (p, d, la) := it
      match (c.rhs p).drop d with
      | b :: β =>
        if c.isNt.contains b then
          let las := c.firstSeq β la
          for q in c.prodsOf.getD b [] do
            for l in las do
              if !seen.contains (q, 0, l) then stack := (q, 0, l) :: stack
      | [] => pure ()
  return out

def itemLt (a b : Item) : Bool :=
  a.1 < b.1 || (a.1 == b.1 && (a.2.1 < b.2.1 || (a.2.1 == b.2.1 && a.2.2 < b.2.2)))

def normalize (k : List Item) : List Item := (k.mergeSort fun a b => !itemLt b a).eraseDups

/-! ## Conflict resolution -/

/-- Level (index in the declarations, loosest first) and associativity of a symbol. -/
def levelOf (g : Grammar) (s : String) : Option (Nat × Assoc) := Id.run do
  let mut i := 0
  for (a, syms) in g.levels do
    if syms.contains s then return some (i, a)
    i := i + 1
  return none

/-- A production's level: its `%prec` symbol's, or its rightmost terminal's. -/
def prodLevel (c : Ctx) (p : Nat) : Option Nat :=
  let pr := c.g.prods[p]!
  match pr.prec with
  | some x => (levelOf c.g x).map (·.1)
  | none =>
    match (pr.rhs.filter fun s => !c.isNt.contains s).getLast? with
    | some t => (levelOf c.g t).map (·.1)
    | none => none

inductive Res where
  | reduce | shift | neither
  deriving BEq

/-- One reduction against a shift of token `a`. -/
def resolve1 (c : Ctx) (p : Nat) (a : Tok) : Option Res :=
  match prodLevel c p, levelOf c.g a with
  | some lp, some (la, assoc) =>
    if lp > la then some .reduce
    else if lp < la then some .shift
    else match assoc with
      | .left => some .reduce
      | .right => some .shift
      | .nonassoc => some .neither
  | _, _ => none

/-- The retained actions on token `a`: whether to keep the shift, and which
reductions to keep. -/
def resolve (c : Ctx) (shift : Bool) (reds : List Nat) (a : Tok) : Bool × List Nat :=
  if !shift || reds.isEmpty then (shift, reds)
  else match reds with
    | [p] =>
      match resolve1 c p a with
      | some .reduce => (false, [p])
      | some .shift => (true, [])
      | some .neither => (false, [])
      | none => (true, [p])
    | _ =>
      let rs := reds.map fun p => resolve1 c p a
      if rs.all (· == some .shift) then (true, [])
      else if rs.all (· == some .neither) then (false, [])
      else (true, reds)

/-! ## The automaton -/

/-- Build the canonical automaton: states numbered in breadth-first order from
the initial state. -/
def canonical (g : Grammar) (limit : Nat := 1000000) : Except String Automaton := do
  let c := mkCtx g
  let aug := g.prods.size
  let k0 := normalize [(aug, 0, endTok)]
  let mut ids : Std.HashMap (List Item) Nat := ({} : Std.HashMap (List Item) Nat).insert k0 0
  let mut kernels : Array (List Item) := #[k0]
  let mut trans : Array (List (String × Nat)) := #[]
  let mut reds : Array (List (Nat × List Tok)) := #[]
  let mut accept : Array (List Tok) := #[]
  let mut i := 0
  while i < kernels.size do
    if kernels.size > limit then throw "state limit"
    let items := c.closure kernels[i]!
    -- successors, symbols in first-seen order
    let mut syms : Array String := #[]
    let mut succ : Std.HashMap String (List Item) := {}
    let mut red : Std.HashMap Tok (List Nat) := {}
    let mut acc : List Tok := []
    for (p, d, la) in items do
      match (c.rhs p).drop d with
      | x :: _ =>
        if !succ.contains x then syms := syms.push x
        succ := succ.insert x ((p, d + 1, la) :: succ.getD x [])
      | [] =>
        if p == aug then acc := acc ++ [la]
        else
          let cur := red.getD la []
          if !cur.contains p then red := red.insert la (cur ++ [p])
    let mut tr : List (String × Nat) := []
    for x in syms do
      let k := normalize (succ.getD x [])
      let j ← match ids.get? k with
        | some j => pure j
        | none => do
          let j := kernels.size
          ids := ids.insert k j
          kernels := kernels.push k
          pure j
      tr := tr ++ [(x, j)]
    -- conflict resolution, token by token
    let mut keepShift : Std.HashSet Tok := {}
    let mut rds : Std.HashMap Nat (List Tok) := {}
    let tokens := (syms.toList.filter fun x => !c.isNt.contains x) ++ red.keys
    for a in tokens.eraseDups do
      let sh := !c.isNt.contains a && succ.contains a
      let (s, rs) := resolve c sh (red.getD a []) a
      if s then keepShift := keepShift.insert a
      for p in rs do rds := rds.insert p ((rds.getD p []) ++ [a])
    trans := trans.push (tr.filter fun (x, _) => c.isNt.contains x || keepShift.contains x)
    reds := reds.push ((rds.toList.mergeSort fun a b => a.1 ≤ b.1).map fun (p, ts) => (p, ts.mergeSort))
    accept := accept.push acc
    i := i + 1
  let nts := (g.prods.foldl (fun (l : List String) p => if l.contains p.lhs then l else l ++ [p.lhs]) []).toArray
  return { prods := g.prods.map fun p => (p.lhs, p.rhs), nts, trans, reds, accept, start := g.start }

end Ambiguity.Lr1

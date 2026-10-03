import Ambiguity.Product

/-!
# Lookahead elimination with bracket groups

A plain grammar `E` whose nonterminals are *keys* over the guarded grammar `T`:

* `nt x f t` — `x` followed by token `t`, whose yield starts with `f`
  (`none`: unconstrained; `some none`: empty; `some (some a)`: starts with `a`);
* `seq x i a b f t` — symbols `[a, b)` of rule `i` of `x`, likewise annotated;
* `grp x i a` — the bracket group opened at position `a` of that rule;
* `inner x i a` — its interior;
* `dead` — no rules.

`specRules` gives each key's rules as a pure function of `T` and a FIRST table.
A finite part of this grammar is explored from `nt start none "#"` and checked
key by key against `specRules`; the table is checked as a post-fixpoint.
-/

namespace Ambiguity

inductive LKey where
  | nt (x : Nat) (f : Option (Option Tok)) (t : Tok)
  | seq (x i a b : Nat) (f : Option (Option Tok)) (t : Tok)
  | grp (x i a : Nat)
  | inner (x i a : Nat)
  | dead
  deriving DecidableEq, Hashable, Repr, Inhabited

inductive LSym where
  | t (a : Tok)
  | n (k : LKey)
  deriving DecidableEq, Hashable, Repr, Inhabited

/-- Position of the bracket closing the opener at `a`, by depth counting. -/
def matchClose (rhs : List Sym) (a : Nat) : Option Nat :=
  let rec go (j depth : Nat) : List Sym → Option Nat
    | [] => none
    | .t s :: rest =>
      if isOpen s then go (j + 1) (depth + 1) rest
      else if isClose s then (if depth = 0 then some j else go (j + 1) (depth - 1) rest)
      else go (j + 1) depth rest
    | .n _ :: rest => go (j + 1) depth rest
  go (a + 1) 0 (rhs.drop (a + 1))

/-- The group at `a`: opener, closer, and closing position, when well formed. -/
def groupAt (rhs : List Sym) (a : Nat) : Option (Tok × Tok × Nat) :=
  match rhs[a]? with
  | some (.t o) =>
    match closerOf o, matchClose rhs a with
    | some c, some m => if a < m ∧ rhs[m]? = some (.t c) then some (o, c, m) else none
    | _, _ => none
  | _ => none

abbrev FirstTbl := Nat → Tok → List (Option Tok)

/-- First tokens of `rhs[a, b)` followed by `t` (`none`: it can be empty). -/
def sFirst (F : FirstTbl) (rhs : List Sym) (a b : Nat) (t : Tok) : List (Option Tok) :=
  if h : a < b then
    match rhs[a]? with
    | some (.t s) =>
      match groupAt rhs a with
      | some (o, _, m) => if m < b then [some o] else []
      | none => [some s]
    | some (.n y) =>
      ((sFirst F rhs (a + 1) b t).flatMap fun g =>
        (F y (g.getD t)).map fun e => if e.isNone then g else e).eraseDups
    | none => []
  else [none]
termination_by b - a

def fOk (f : Option (Option Tok)) (s : List (Option Tok)) : Bool :=
  match f with
  | none => true
  | some fv => s.contains fv

def ruleAt (T : GGrammar) (x i : Nat) : Option GRule := (T.rulesOf x)[i]?

def specRules (T : GGrammar) (F : FirstTbl) : LKey → List (List LSym)
  | .dead => []
  | .nt x f t =>
    (T.rulesOf x).zipIdx.map fun (r, i) =>
      if r.guard.contains t && fOk f (sFirst F r.rhs 0 r.rhs.length t) then
        [.n (.seq x i 0 r.rhs.length f t)]
      else [.n .dead]
  | .seq x i a b f t =>
    match ruleAt T x i with
    | none => []
    | some r =>
      if a < b then
        match r.rhs[a]? with
        | some (.t s) =>
          match groupAt r.rhs a with
          | some (o, _, m) =>
            if m < b ∧ (f = none ∨ f = some (some o)) then
              [[.n (.grp x i a), .n (.seq x i (m + 1) b none t)]]
            else []
          | none =>
            if f = none ∨ f = some (some s) then [[.t s, .n (.seq x i (a + 1) b none t)]] else []
        | some (.n y) =>
          (sFirst F r.rhs (a + 1) b t).eraseDups.flatMap fun g =>
            let after := g.getD t
            let rest := LSym.n (.seq x i (a + 1) b (some g) t)
            let child := F y after
            match f with
            | none => if child.isEmpty then [] else [[.n (.nt y none after), rest]]
            | some fv =>
              (if fv.isSome && child.contains fv then [[.n (.nt y (some fv) after), rest]] else []) ++
              (if child.contains none && fv == g then [[.n (.nt y (some none) after), rest]] else [])
        | none => []
      else if f = none ∨ f = some none then [[]] else []
  | .grp x i a =>
    match ruleAt T x i with
    | none => []
    | some r =>
      match groupAt r.rhs a with
      | some (o, c, m) => if m = a + 1 then [[.t o, .t c]] else [[.t o, .n (.inner x i a), .t c]]
      | none => []
  | .inner x i a =>
    match ruleAt T x i with
    | none => []
    | some r =>
      match groupAt r.rhs a with
      | some (_, c, m) => [[.n (.seq x i (a + 1) m none c)]]
      | none => []

def startKey (T : GGrammar) : LKey := .nt T.start none endTok

/-! ## FIRST table (producer) and its post-fixpoint check -/

def firstTable (T : GGrammar) : Std.HashMap (Nat × Tok) (List (Option Tok)) := Id.run do
  let mut first : Std.HashMap (Nat × Tok) (List (Option Tok)) := {}
  let mut changed := true
  while changed do
    changed := false
    for x in List.range T.rules.size do
      for r in T.rulesOf x do
        for t in r.guard do
          let F : FirstTbl := fun y t => first.getD (y, t) []
          let res := sFirst F r.rhs 0 r.rhs.length t
          let old := first.getD (x, t) []
          let new := (old ++ res).eraseDups
          if new.length != old.length then
            first := first.insert (x, t) new
            changed := true
  return first

def checkFirst (T : GGrammar) (F : FirstTbl) : Bool :=
  (List.range T.rules.size).all fun x => (T.rulesOf x).all fun r =>
    r.guard.all fun t => (sFirst F r.rhs 0 r.rhs.length t).all fun e => (F x t).contains e

/-! ## Exploration (producer) and the closure check -/

structure LGrammar where
  keys : Array LKey
  rules : Array (List (List Sym))

def toSym (ids : Std.HashMap LKey Nat) : LSym → Sym
  | .t a => .t a
  | .n k => .n (ids.getD k 0)

def explore (T : GGrammar) (F : FirstTbl) : LGrammar := Id.run do
  let mut ids : Std.HashMap LKey Nat := ({} : Std.HashMap LKey Nat).insert (startKey T) 0
  let mut keys : Array LKey := #[startKey T]
  let mut i := 0
  while i < keys.size do
    for r in specRules T F keys[i]! do
      for s in r do
        match s with
        | .n k =>
          if !ids.contains k then
            ids := ids.insert k keys.size
            keys := keys.push k
        | _ => pure ()
    i := i + 1
  let rules := keys.map fun k => (specRules T F k).map fun r => r.map (toSym ids)
  return { keys, rules }

/-- Each explored key's rules are its specification, with every key symbol
pointing at the id of that key. -/
def symOk (keys : Array LKey) : LSym → Sym → Bool
  | .t a, .t b => a == b
  | .n k, .n j => keys[j]? == some k
  | _, _ => false

def checkExplore (T : GGrammar) (F : FirstTbl) (L : LGrammar) : Bool :=
  L.keys.size == L.rules.size && L.keys[0]? == some (startKey T) &&
  (List.range L.keys.size).all fun j =>
    let spec := specRules T F (L.keys[j]?.getD .dead)
    let rs := L.rules[j]?.getD []
    spec.length == rs.length &&
      (spec.zip rs).all fun (s, r) => s.length == r.length && (s.zip r).all fun (a, b) => symOk L.keys a b

def LGrammar.plain (L : LGrammar) : PGrammar := { rules := L.rules, start := 0 }

end Ambiguity

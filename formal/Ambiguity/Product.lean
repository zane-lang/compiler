import Ambiguity.Quotient

/-!
# Angle tagging, bracket grouping, and lookahead elimination (producers)

These functions compute the grammars of the pipeline. The facts the proof
needs about them are established by verified checks or by their own lemmas.
-/

namespace Ambiguity

/-! ## Angle tagging -/

def tagSym : Sym → Sym
  | .t a => .t (if a = "LESS" then "GLESS" else if a = "MORE" then "GMORE" else a)
  | s => s

def tagRule (r : GRule) : GRule :=
  if r.rhs.contains (.t "LESS") && r.rhs.contains (.t "MORE") then
    { rhs := r.rhs.map tagSym, guard := r.guard }
  else r

def tagGuard (g : List Tok) : List Tok :=
  g ++ (if g.contains "LESS" then ["GLESS"] else []) ++ (if g.contains "MORE" then ["GMORE"] else [])

def tagGrammar (G : GGrammar) : GGrammar :=
  { rules := G.rules.map fun rs => rs.map fun r => let r' := tagRule r; { r' with guard := tagGuard r'.guard },
    start := G.start }

/-! ## Bracket grouping -/

def bracketPairs : List (Tok × Tok) :=
  [("LPAREN", "RPAREN"), ("LBRACKET", "RBRACKET"), ("LCURLY", "RCURLY"), ("GLESS", "GMORE")]

def closerOf (o : Tok) : Option Tok := bracketPairs.lookup o
def isOpen (a : Tok) : Bool := (closerOf a).isSome
def isClose (a : Tok) : Bool := bracketPairs.any (·.2 == a)

/-- Split a right-hand side into its first bracket group: `pre`, the opener,
the interior, the closer, and the rest. -/
partial def splitGroup (rhs : List Sym) : Option (List Sym × Tok × List Sym × Tok × List Sym) :=
  let rec find (pre : List Sym) : List Sym → Option (List Sym × Tok × List Sym × Tok × List Sym)
    | [] => none
    | .t o :: rest =>
      match closerOf o with
      | some _ =>
        let rec scan (depth : Nat) (acc : List Sym) : List Sym → Option (List Sym × Tok × List Sym)
          | [] => none
          | s :: tl =>
            match s with
            | .t a =>
              if isOpen a then scan (depth + 1) (s :: acc) tl
              else if isClose a then
                if depth == 0 then some (acc.reverse, a, tl) else scan (depth - 1) (s :: acc) tl
              else scan depth (s :: acc) tl
            | _ => scan depth (s :: acc) tl
        match scan 0 [] rest with
        | some (inner, c, tl) => some (pre.reverse, o, inner, c, tl)
        | none => none
      | none => find (.t o :: pre) rest
    | s :: rest => find (s :: pre) rest
  find [] rhs

structure GroupState where
  rules : Array (List GRule)
  ids : Std.HashMap (Tok × List Sym × Tok) Nat := {}

/-- Replace each bracket group by a fresh nonterminal `b` with the single rule
`o inner c` (the interior grouped recursively through `binner`). -/
partial def groupRhs (allTok : List Tok) (st : GroupState) (rhs : List Sym) : List Sym × GroupState :=
  match splitGroup rhs with
  | none => (rhs, st)
  | some (pre, o, inner, c, rest) =>
    let (inner', st) := groupRhs allTok st inner
    let key := (o, inner', c)
    let (b, st) := match st.ids.get? key with
      | some b => (b, st)
      | none =>
        let b := st.rules.size
        if inner'.isEmpty then
          (b, { st with rules := st.rules.push [{ rhs := [.t o, .t c], guard := allTok }],
                        ids := st.ids.insert key b })
        else
          (b, { st with rules := (st.rules.push [{ rhs := [.t o, .n (b + 1), .t c], guard := allTok }]).push
                          [{ rhs := inner', guard := allTok }],
                        ids := st.ids.insert key b })
    let (rest', st) := groupRhs allTok st rest
    (pre ++ [.n b] ++ rest', st)

def allTokens (G : GGrammar) : List Tok :=
  (endTok :: (G.rules.toList.flatMap fun rs => rs.flatMap fun r =>
    r.guard ++ r.rhs.filterMap fun | .t a => some a | _ => none)).eraseDups

def groupGrammar (G : GGrammar) : GGrammar := Id.run do
  let allTok := allTokens G
  let mut st : GroupState := { rules := G.rules }
  for x in List.range G.rules.size do
    let mut out := []
    for r in G.rulesOf x do
      let (rhs', st') := groupRhs allTok st r.rhs
      st := st'
      out := out ++ [{ r with rhs := rhs' }]
    st := { st with rules := st.rules.set! x out }
  return { rules := st.rules, start := G.start }

/-! ## Lookahead elimination

Nonterminal keys of the product: the start, `plain x t` (`x` followed by `t`,
first token unconstrained), `nt x f t` (`x` with first token `f`, or `none` for
an empty yield, followed by `t`), and `seq k i f t` (the suffix of rule `k`
from position `i`). -/

inductive PKey where
  | start
  | plain (x : Nat) (t : Tok)
  | nt (x : Nat) (f : Option Tok) (t : Tok)
  | seq (k i : Nat) (f : Option (Option Tok)) (t : Tok)
  deriving DecidableEq, Hashable, Repr, Inhabited

/-- A plain grammar: rules are right-hand sides only. -/
structure PGrammar where
  rules : Array (List (List Sym))
  start : Nat
  deriving Inhabited

namespace PGrammar
def rulesOf (G : PGrammar) (x : Nat) : List (List Sym) := G.rules.getD x []
end PGrammar

/-- Flattened rule table of a guarded grammar: `(lhs, rhs, guard)`. -/
def ruleTable (G : GGrammar) : Array (Nat × List Sym × List Tok) :=
  (List.range G.rules.size).toArray.flatMap fun x =>
    ((G.rulesOf x).map fun r => (x, r.rhs, r.guard)).toArray

/-- FIRST sets per (nonterminal, follow): `none` stands for the empty yield.
Least fixpoint by iteration (unverified producer; checked as a post-fixpoint). -/
def firstSets (G : GGrammar) (tab : Array (Nat × List Sym × List Tok)) :
    Std.HashMap (Nat × Tok) (List (Option Tok)) := Id.run do
  let mut first : Std.HashMap (Nat × Tok) (List (Option Tok)) := {}
  let mut changed := true
  while changed do
    changed := false
    for (x, rhs, guard) in tab do
      for t in guard do
        -- first tokens of rhs followed by t
        let mut res : List (Option Tok) := [none]
        for s in rhs.reverse do
          match s with
          | .t a => res := if res.isEmpty then [] else [some a]
          | .n y =>
            res := (res.flatMap fun f =>
              let fol := f.getD t
              (first.getD (y, fol) []).map fun a => if a.isNone then f else a).eraseDups
        let old := first.getD (x, t) []
        let new := (old ++ res).eraseDups
        if new.length != old.length then
          first := first.insert (x, t) new
          changed := true
  return first

def seqFirst (first : Std.HashMap (Nat × Tok) (List (Option Tok))) (rhs : List Sym) (i : Nat) (t : Tok) :
    List (Option Tok) := Id.run do
  let mut res : List (Option Tok) := [none]
  for s in (rhs.drop i).reverse do
    match s with
    | .t a => res := if res.isEmpty then [] else [some a]
    | .n y =>
      res := (res.flatMap fun f =>
        let fol := f.getD t
        (first.getD (y, fol) []).map fun a => if a.isNone then f else a).eraseDups
  return res

/-- The lookahead product, explored from the start. `wrapped` are the bracket
nonterminals introduced by grouping (kept as `o (plain inner c) c`). -/
def product (G : GGrammar) (wrapped : Nat → Bool) : PGrammar × Array PKey := Id.run do
  let tab := ruleTable G
  let byNt : Array (List Nat) := Id.run do
    let mut a := Array.replicate G.rules.size []
    for k in List.range tab.size do
      let x := tab[k]!.1
      a := a.set! x (a[x]! ++ [k])
    return a
  let first := firstSets G tab
  let mut ids : Std.HashMap PKey Nat := {}
  let mut keys : Array PKey := #[]
  let mut out : Array (List (List Sym)) := #[]
  let mut queue : Array PKey := #[]
  ids := ids.insert .start 0; keys := keys.push .start; out := out.push []; queue := queue.push .start
  let mut qi := 0
  while qi < queue.size do
    let key := queue[qi]!
    qi := qi + 1
    let mut rs : List (List PKey ⊕ List Sym) := []
    -- build rules as lists of (Sum PKey Tok) then intern
    let mut built : List (List (Sum PKey Tok)) := []
    match key with
    | .start => built := [[.inl (.plain G.start endTok)]]
    | .plain x t | .nt x _ t =>
      let f? : Option (Option Tok) := match key with | .nt _ f _ => some f | _ => none
      for k in byNt.getD x [] do
        let (_, rhs, guard) := tab[k]!
        let sf := seqFirst first rhs 0 t
        if !guard.contains t || sf.isEmpty then continue
        match f? with
        | some f => if !sf.contains f then continue
        | none => pure ()
        if wrapped x then
          match rhs with
          | [.t o, .t c] => built := built ++ [[.inr o, .inr c]]
          | [.t o, .n y, .t c] => built := built ++ [[.inr o, .inl (.plain y c), .inr c]]
          | _ => pure ()
        else
          built := built ++ [[.inl (.seq k 0 f? t)]]
    | .seq k i f t =>
      let (_, rhs, _) := tab[k]!
      if i == rhs.length then
        built := [[]]
      else
        match rhs[i]! with
        | .t a =>
          if f.isNone || f == some (some a) then
            built := [[.inr a, .inl (.seq k (i+1) none t)]]
        | .n y =>
          for a in seqFirst first rhs (i+1) t do
            let after := a.getD t
            let rest := PKey.seq k (i+1) (some a) t
            let child := first.getD (y, after) []
            match f with
            | none => if !child.isEmpty then built := built ++ [[.inl (.plain y after), .inl rest]]
            | some fv =>
              if fv.isSome && child.contains fv then
                built := built ++ [[.inl (.nt y fv after), .inl rest]]
              if child.contains none && fv == a then
                built := built ++ [[.inl (.nt y none after), .inl rest]]
    let _ := rs
    let mut rules : List (List Sym) := []
    for b in built do
      let mut rhs : List Sym := []
      for s in b do
        match s with
        | .inr a => rhs := rhs ++ [.t a]
        | .inl pk =>
          match ids.get? pk with
          | some j => rhs := rhs ++ [.n j]
          | none =>
            let j := keys.size
            ids := ids.insert pk j; keys := keys.push pk; out := out.push []; queue := queue.push pk
            rhs := rhs ++ [.n j]
      rules := rules ++ [rhs]
    out := out.set! (ids.getD key 0) rules
  return ({ rules := out, start := 0 }, keys)

/-- Quotient of a plain grammar by rule signatures (as for guarded grammars). -/
def pquotient (G : PGrammar) : PGrammar × Array Nat :=
  let (Q, h) := quotient { rules := G.rules.map fun rs => rs.map fun r => { rhs := r, guard := [] },
                           start := G.start } (fun _ => 0)
  ({ rules := Q.rules.map fun rs => rs.map (·.rhs), start := Q.start }, h)

end Ambiguity

import Ambiguity.Product

/-!
# The angle certificate

Generic angle brackets reuse the comparison tokens `LESS` and `MORE`. A rule
containing both is a generic rule, and tagging renames its pair to `GLESS` and
`GMORE` (`tagGrammar`). `checkAngles` verifies, on the tagged grammar, that the
tags of every sentence are a function of its untagged tokens:

* every `GLESS` follows `UIDENT` and precedes something other than `LPAREN`,
  while no untagged `LESS` does both;
* inside a generic region no untagged `LESS` or `MORE` can occur, so a `MORE`
  is a generic close exactly when a generic region is open.

Neighbours are over-approximated by FIRST/LAST/PREV/AFTER sets, each checked as
a post-fixpoint of its defining inequalities.
-/

namespace Ambiguity

def startTok : Tok := "^"

/-- First tokens of a sequence, with `none` when it can derive the empty word. -/
def endseq (tbl : Nat → List (Option Tok)) : List Sym → List (Option Tok)
  | [] => [none]
  | .t a :: _ => [some a]
  | .n y :: rest =>
    (tbl y).filter (·.isSome) ++ (if (tbl y).contains none then endseq tbl rest else [])

/-- Concrete tokens of a FIRST-style set, extended by `ctx` when it is nullable. -/
def withCtx (s : List (Option Tok)) (ctx : List Tok) : List Tok :=
  s.filterMap id ++ (if s.contains none then ctx else [])

structure AngleSets where
  first : Array (List (Option Tok))
  last : Array (List (Option Tok))
  prev : Array (List Tok)
  after : Array (List Tok)
  interior : Array Bool

namespace AngleSets
def fst (A : AngleSets) (y : Nat) : List (Option Tok) := A.first.getD y []
def lst (A : AngleSets) (y : Nat) : List (Option Tok) := A.last.getD y []
def prv (A : AngleSets) (y : Nat) : List Tok := A.prev.getD y []
def aft (A : AngleSets) (y : Nat) : List Tok := A.after.getD y []
def inner (A : AngleSets) (y : Nat) : Bool := A.interior.getD y false
end AngleSets

/-- The previous-token set after reading symbol `s`, from the set `P` before it. -/
def prevStep (S : AngleSets) (P : List Tok) : Sym → List Tok
  | .t a => [a]
  | .n y => withCtx (S.lst y) P

/-- The tokens that can come right after a position followed by `rest`. -/
def nextAt (S : AngleSets) (rest : List Sym) (A : List Tok) : List Tok :=
  withCtx (endseq S.fst rest) A

def subsetT (a b : List Tok) : Bool := a.all (b.contains ·)

/-- Conditions at one position, with `P` the possible previous tokens and `N`
the possible next tokens. -/
def posOk (S : AngleSets) (P N : List Tok) : Sym → Bool
  | .n y => subsetT P (S.prv y) && subsetT N (S.aft y)
  | .t a =>
    if a = "GLESS" then subsetT P ["UIDENT"] && !N.contains "LPAREN"
    else if a = "LESS" then !P.contains "UIDENT" || subsetT N ["LPAREN"]
    else true

/-- `posOk` along a right-hand side, left to right. -/
def checkSeq (S : AngleSets) (A : List Tok) : List Tok → List Sym → Bool
  | _, [] => true
  | P, s :: rest => posOk S P (nextAt S rest A) s && checkSeq S A (prevStep S P s) rest

def isAngleTok (a : Tok) : Bool := a == "LESS" || a == "MORE" || a == "GLESS" || a == "GMORE"

/-- Shape of a rule: either no angle tokens of the generic kind and no
`GMORE`, or exactly `pre GLESS mid GMORE post` with no other angle tokens. -/
def genericSplit (rhs : List Sym) : Option (List Sym × List Sym × List Sym) :=
  match rhs.idxOf (.t "GLESS") with
  | i =>
    if i < rhs.length then
      let pre := rhs.take i
      let tl := rhs.drop (i + 1)
      let j := tl.idxOf (.t "GMORE")
      if j < tl.length then some (pre, tl.take j, tl.drop (j + 1)) else none
    else none

def noAngles (l : List Sym) : Bool := l.all fun | .t a => !isAngleTok a | _ => true

def noUntagged (l : List Sym) : Bool := l.all fun | .t a => a != "LESS" && a != "MORE" | _ => true

def noGTok (l : List Sym) : Bool := l.all fun | .t a => a != "GLESS" && a != "GMORE" | _ => true

/-- Simulate the open-region counter along a rule, as `k + d` where the
caller's `k` is zero (`pos = false`) or positive (`pos = true`). -/
def simOk (I : Nat → Bool) (pos : Bool) : Nat → List Sym → Bool
  | d, [] => d == 0
  | d, .t a :: rest =>
    if a = "MORE" then (!pos && d == 0) && simOk I pos d rest
    else if a = "GMORE" then decide (0 < d) && simOk I pos (d - 1) rest
    else if a = "GLESS" then simOk I pos (d + 1) rest
    else simOk I pos d rest
  | d, .n y :: rest => (!(pos || decide (0 < d)) || I y) && simOk I pos d rest

def checkRuleAngles (S : AngleSets) (x : Nat) (r : GRule) : Bool :=
  r.guard.isEmpty ||
  -- post-fixpoint inequalities of FIRST and LAST
  ((endseq S.fst r.rhs).all fun e => (S.fst x).contains e) &&
  ((endseq S.lst r.rhs.reverse).all fun e => (S.lst x).contains e) &&
  -- context sets of the nonterminal positions, and the LESS/GLESS conditions
  checkSeq S (S.aft x) (S.prv x) r.rhs &&
  -- the open-region counter: a `MORE` only where none is open, a `GMORE` only
  -- closing this rule's own `GLESS`, nonterminals in an open region interior
  simOk S.inner false 0 r.rhs && (!S.inner x || simOk S.inner true 0 r.rhs)

/-- The untagged grammar contains no generic tokens. -/
def noGTokens (Q : GGrammar) : Bool :=
  Q.rules.all fun rs => rs.all fun r => noGTok r.rhs

def checkAngles (T : GGrammar) (S : AngleSets) : Bool :=
  (S.prv T.start).contains startTok && (S.aft T.start).contains endTok &&
  (List.range T.rules.size).all fun x => (T.rulesOf x).all (checkRuleAngles S x)

/-! ## Producer (unverified): least fixpoints of the four sets -/

def angleSets (T : GGrammar) : AngleSets := Id.run do
  let n := T.rules.size
  let usable := fun (x : Nat) => (T.rulesOf x).filter (!·.guard.isEmpty)
  let mut first : Array (List (Option Tok)) := Array.replicate n []
  let mut last : Array (List (Option Tok)) := Array.replicate n []
  let mut changed := true
  while changed do
    changed := false
    for x in List.range n do
      for r in usable x do
        for (tbl, seq, isFirst) in [(first, r.rhs, true), (last, r.rhs.reverse, false)] do
          let e := endseq (fun y => tbl.getD y []) seq
          let old := tbl.getD x []
          let new := (old ++ e).eraseDups
          if new.length != old.length then
            changed := true
            if isFirst then first := first.set! x new else last := last.set! x new
  let S0 : AngleSets := { first, last, prev := Array.replicate n [], after := Array.replicate n [],
                          interior := Array.replicate n false }
  let mut prev : Array (List Tok) := (Array.replicate n []).set! T.start [startTok]
  let mut after : Array (List Tok) := (Array.replicate n []).set! T.start [endTok]
  changed := true
  while changed do
    changed := false
    let S := { S0 with prev, after }
    for x in List.range n do
      for r in usable x do
        let mut P := S.prv x
        let mut rest := r.rhs
        while !rest.isEmpty do
          let s := rest.head!
          rest := rest.tail
          match s with
          | .n y =>
            let N := nextAt S rest (S.aft x)
            let np := (prev.getD y [] ++ P).eraseDups
            let na := (after.getD y [] ++ N).eraseDups
            if np.length != (prev.getD y []).length then prev := prev.set! y np; changed := true
            if na.length != (after.getD y []).length then after := after.set! y na; changed := true
          | _ => pure ()
          P := prevStep S P s
  -- interior: reachable from generic regions
  let mut inner : Array Bool := Array.replicate n false
  let mut stack : List Nat := []
  for x in List.range n do
    for r in usable x do
      match genericSplit r.rhs with
      | some (_, mid, _) =>
        for s in mid do
          match s with
          | .n y => if !inner[y]! then inner := inner.set! y true; stack := y :: stack
          | _ => pure ()
      | none => pure ()
  while !stack.isEmpty do
    let y := stack.head!
    stack := stack.tail
    for r in usable y do
      for s in r.rhs do
        match s with
        | .n z => if !inner[z]! then inner := inner.set! z true; stack := z :: stack
        | _ => pure ()
  return { first, last, prev, after, interior := inner }

end Ambiguity

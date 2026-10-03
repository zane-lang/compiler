import Ambiguity.Grammar
import Std.Data.HashMap

/-!
# The LR automaton and its accepted parse relation

`Automaton` is Menhir's exported automaton: productions, transitions on
terminals and nonterminals, the retained reductions with their lookahead
tokens, and the accepting state. `AccT` is the parse relation a GLR run over
this automaton computes: a tree of the automaton's grammar is accepted when its
left-to-right simulation from state `q` shifts and goes to existing states and
performs every reduction on a token the automaton retains for it.
-/

namespace Ambiguity

structure Automaton where
  /-- Productions: left-hand side and right-hand side symbols. -/
  prods : Array (String × List String)
  /-- Nonterminal names; every other symbol is a token. -/
  nts : Array String
  trans : Array (List (String × Nat))
  /-- Per state: retained reductions as (production, lookahead tokens). -/
  reds : Array (List (Nat × List Tok))
  /-- Per state: tokens on which the state accepts. -/
  accept : Array (List Tok)
  start : String
  deriving Inhabited

namespace Automaton
def isNt (A : Automaton) (s : String) : Bool := A.nts.contains s
def step (A : Automaton) (q : Nat) (s : String) : Option Nat := ((A.trans.getD q []).lookup s)
def look (A : Automaton) (r p : Nat) : List Tok := ((A.reds.getD r []).lookup p).getD []
def lhs (A : Automaton) (p : Nat) : String := (A.prods.getD p ("", [])).1
def rhs (A : Automaton) (p : Nat) : List String := (A.prods.getD p ("", [])).2
end Automaton

/-- Trees of the automaton's grammar: a production and the subtrees of its
nonterminal positions. -/
inductive ATree where
  | node (p : Nat) (kids : List ATree)
  deriving Repr, Inhabited

mutual
def ATree.yield (A : Automaton) : ATree → List Tok
  | .node p kids => ayields A (A.rhs p) kids
def ayields (A : Automaton) : List String → List ATree → List Tok
  | [], _ => []
  | s :: rest, kids =>
    if A.isNt s then
      match kids with
      | k :: ks => k.yield A ++ ayields A rest ks
      | [] => ayields A rest []
    else s :: ayields A rest kids
end

mutual
/-- `AccT A q fol t`: from state `q`, with `fol` the token after the yield,
the simulation of `t` uses only the automaton's transitions and retained
reductions. -/
inductive AccT (A : Automaton) : Nat → Tok → ATree → Prop
  | node {q fol p kids r} :
      ARun A q (A.rhs p) fol kids r →
      fol ∈ A.look r p →
      (A.step q (A.lhs p)).isSome →
      AccT A q fol (.node p kids)
/-- The simulation of a right-hand side from state `q` ends in state `r`. -/
inductive ARun (A : Automaton) : Nat → List String → Tok → List ATree → Nat → Prop
  | nil {q fol} : ARun A q [] fol [] q
  | term {q a q' rest fol kids r} :
      A.isNt a = false → A.step q a = some q' →
      ARun A q' rest fol kids r → ARun A q (a :: rest) fol kids r
  | nt {q x q' rest fol k kids r} :
      A.isNt x = true → A.step q x = some q' →
      AccT A q (firstOr (ayields A rest kids) fol) k →
      ARun A q' rest fol kids r → ARun A q (x :: rest) fol (k :: kids) r
end

/-- A whole sentence: a tree of the start symbol from the initial state,
followed by the end of input, whose goto accepts the end of input. -/
def Accepted (A : Automaton) (t : ATree) : Prop :=
  AccT A 0 endTok t ∧ (match t with | .node p _ => A.lhs p = A.start) ∧
    ∃ s, A.step 0 A.start = some s ∧ endTok ∈ A.accept.getD s []

def AUnambiguous (A : Automaton) : Prop :=
  ∀ t₁ t₂, Accepted A t₁ → Accepted A t₂ → t₁.yield A = t₂.yield A → t₁ = t₂

/-! ## The exact LR context grammar

Nonterminal `(q, X)` derives what `X` derives in a tree whose simulation
starts in state `q`. Its rules are indexed by the productions of `X`, so a
rule's index identifies its production; a production whose path from `q` is
missing, or whose end state does not reduce it, gets an unusable rule with an
empty guard. -/

namespace Automaton
def ntIndex (A : Automaton) (x : String) : Nat := A.nts.toList.idxOf x
def ctxId (A : Automaton) (q : Nat) (x : String) : Nat := q * A.nts.size + A.ntIndex x
/-- Productions of `x`, in order. -/
def prodsOf (A : Automaton) (x : String) : List Nat :=
  (List.range A.prods.size).filter fun p => A.lhs p == x

/-- The states along `rhs` from `q`. -/
def walk (A : Automaton) : Nat → List String → Option (List Nat)
  | q, [] => some [q]
  | q, s :: rest => do let q' ← A.step q s; let tl ← A.walk q' rest; pure (q :: tl)

def ctxRhs (A : Automaton) : List Nat → List String → List Sym
  | q :: route, s :: rest =>
    (if A.isNt s then Sym.n (A.ctxId q s) else Sym.t s) :: A.ctxRhs route rest
  | _, _ => []

def ctxRule (A : Automaton) (q p : Nat) : GRule :=
  match A.walk q (A.rhs p) with
  | some route =>
    if (A.step q (A.lhs p)).isSome then
      { rhs := A.ctxRhs route (A.rhs p), guard := A.look (route.getLastD q) p }
    else { rhs := [], guard := [] }
  | none => { rhs := [], guard := [] }

def ctxGrammar (A : Automaton) : GGrammar where
  rules := Id.run do
    let byLhs : Std.HashMap String (List Nat) :=
      (List.range A.prods.size).foldr (fun p m => m.insert (A.lhs p) (p :: m.getD (A.lhs p) [])) {}
    let mut out : Array (List GRule) := Array.replicate (A.trans.size * A.nts.size) []
    for q in List.range A.trans.size do
      for x in A.nts.toList do
        out := out.set! (A.ctxId q x) ((byLhs.getD x []).map fun p => A.ctxRule q p)
    return out
  start := A.ctxId 0 A.start
end Automaton

/-! ## Reading Menhir's `.automaton` dump (unverified) -/

def parseDump (text : String) (start : String) : Except String Automaton := Id.run do
  let mut trans : Array (List (String × Nat)) := #[]
  let mut reds : Array (List (Nat × List Tok)) := #[]
  let mut accept : Array (List Tok) := #[]
  let mut prodIds : Std.HashMap (String × List String) Nat := {}
  let mut prods : Array (String × List String) := #[]
  let mut look : List Tok := []
  for line in text.splitOn "\n" do
    if line.startsWith "State " && line.endsWith ":" then
      let n := (line.drop 6).dropEnd 1 |>.toString.toNat!
      if n != trans.size then return .error s!"state {n} out of order"
      trans := trans.push []; reds := reds.push []; accept := accept.push []
      look := []
    else if trans.size == 0 then
      continue
    else if line.startsWith "-- On " && (line.splitOn " shift to state ").length == 2 then
      let parts := (line.drop 6).toString.splitOn " shift to state "
      let sym := parts[0]!
      let tgt := parts[1]!.toNat!
      trans := trans.modify (trans.size - 1) fun l => l ++ [(sym, tgt)]
    else if line.startsWith "--   reduce production " then
      let body := (line.drop 23).toString
      let parts := body.splitOn " ->"
      if parts.length != 2 then return .error s!"unrecognized reduction: {line}"
      let lhs := parts[0]!
      let rhs := (parts[1]!.splitOn " ").filter (· ≠ "")
      let key := (lhs, rhs)
      let p ← match prodIds.get? key with
        | some p => pure p
        | none => do
          prodIds := prodIds.insert key prods.size
          prods := prods.push key
          pure (prods.size - 1)
      reds := reds.modify (reds.size - 1) fun l =>
        match l.lookup p with
        | some _ => l.map fun (p', ts) => if p' == p then (p', ts ++ look) else (p', ts)
        | none => l ++ [(p, look)]
    else if line.startsWith "--   accept" then
      accept := accept.modify (accept.size - 1) fun l => l ++ look
    else if line.startsWith "-- On " then
      look := ((line.drop 6).toString.splitOn " ").filter (· ≠ "")
  let nts := (prods.toList.map (·.1)).eraseDups.toArray
  return .ok { prods, nts, trans, reds, accept, start }

end Ambiguity

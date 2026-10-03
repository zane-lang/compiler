import Ambiguity.S

/-!
# Grammars, derivation trees, and unambiguity

Nonterminals are natural numbers. A rule of a *guarded* grammar carries the
set of tokens allowed to follow its yield (`"#"` is the end of input). A plain
grammar is a guarded grammar whose guards are never consulted.
-/

namespace Ambiguity


/-- The end-of-input marker that follows a whole sentence. -/
def endTok : Tok := "#"

inductive Sym where
  | t (a : Tok)
  | n (x : Nat)
  deriving DecidableEq, Hashable, Repr, Inhabited

structure GRule where
  rhs : List Sym
  guard : List Tok
  deriving DecidableEq, Hashable, Repr, Inhabited

structure GGrammar where
  rules : Array (List GRule)
  start : Nat
  deriving Inhabited

namespace GGrammar
def rulesOf (G : GGrammar) (x : Nat) : List GRule := G.rules.getD x []
end GGrammar

/-- A derivation tree: a rule (by its index among its nonterminal's rules)
and one subtree per nonterminal occurrence of that rule's right-hand side. -/
inductive Tree where
  | node (i : Nat) (kids : List Tree)
  deriving Repr, Inhabited

/-- Interleave the terminals of a right-hand side with the yields of the
subtrees at its nonterminal positions. -/
def rhsYield : List Sym → List (List Tok) → List Tok
  | [], _ => []
  | .t a :: rest, ys => a :: rhsYield rest ys
  | .n _ :: rest, y :: ys => y ++ rhsYield rest ys
  | .n _ :: rest, [] => rhsYield rest []

/-- The nonterminals of a right-hand side, in order. -/
def rhsNts : List Sym → List Nat
  | [] => []
  | .t _ :: rest => rhsNts rest
  | .n x :: rest => x :: rhsNts rest

mutual
def Tree.yield (G : GGrammar) (x : Nat) : Tree → List Tok
  | .node i kids =>
    match (G.rulesOf x)[i]? with
    | some r => rhsYield r.rhs (yields G (rhsNts r.rhs) kids)
    | none => []
def yields (G : GGrammar) : List Nat → List Tree → List (List Tok)
  | x :: xs, t :: ts => t.yield G x :: yields G xs ts
  | _, _ => []
end

/-- The first token of `w`, or `fol` when `w` is empty. -/
def firstOr (w : List Tok) (fol : Tok) : Tok := w.head?.getD fol

mutual
/-- Well-formed trees of a guarded grammar, for nonterminal `x` followed by
the token `fol`. The follow token of a subtree is the first token after its
yield inside the parent's yield, or the parent's own follow token. -/
inductive WF (G : GGrammar) : Nat → Tok → Tree → Prop
  | node {x fol i kids} (r : GRule) :
      (G.rulesOf x)[i]? = some r →
      fol ∈ r.guard →
      WFs G r.rhs fol kids →
      WF G x fol (.node i kids)

/-- `WFs G rhs fol kids`: the subtrees fill the nonterminal positions of
`rhs`, each with the follow token determined by what comes after it. -/
inductive WFs (G : GGrammar) : List Sym → Tok → List Tree → Prop
  | nil {fol} : WFs G [] fol []
  | term {a rest fol kids} : WFs G rest fol kids → WFs G (.t a :: rest) fol kids
  | nt {x rest fol t kids} :
      WF G x (firstOr (rhsYield rest (yields G (rhsNts rest) kids)) fol) t →
      WFs G rest fol kids →
      WFs G (.n x :: rest) fol (t :: kids)
end

/-- A guarded grammar is unambiguous when two well-formed trees of the start
symbol, followed by the end of input, with the same yield are equal. -/
def Unambiguous (G : GGrammar) : Prop :=
  ∀ t₁ t₂, WF G G.start endTok t₁ → WF G G.start endTok t₂ →
    t₁.yield G G.start = t₂.yield G G.start → t₁ = t₂

end Ambiguity

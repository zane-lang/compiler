import Ambiguity.Quotient

/-!
# Angle tagging, bracket tokens, and plain grammars

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

/-! ## Bracket tokens -/

def bracketPairs : List (Tok × Tok) :=
  [("LPAREN", "RPAREN"), ("LBRACKET", "RBRACKET"), ("LCURLY", "RCURLY"), ("GLESS", "GMORE")]

def closerOf (o : Tok) : Option Tok := bracketPairs.lookup o
def isOpen (a : Tok) : Bool := (closerOf a).isSome
def isClose (a : Tok) : Bool := bracketPairs.any (·.2 == a)

/-! ## Plain grammars -/

/-- A plain grammar: rules are right-hand sides only. -/
structure PGrammar where
  rules : Array (List (List Sym))
  start : Nat
  deriving Inhabited

namespace PGrammar
def rulesOf (G : PGrammar) (x : Nat) : List (List Sym) := G.rules.getD x []
end PGrammar

/-- Quotient of a plain grammar by rule signatures (as for guarded grammars). -/
def pquotient (G : PGrammar) : PGrammar × Array Nat :=
  let (Q, h) := quotient { rules := G.rules.map fun rs => rs.map fun r => { rhs := r, guard := [] },
                           start := G.start } (fun _ => 0)
  ({ rules := Q.rules.map fun rs => rs.map (·.rhs), start := Q.start }, h)

end Ambiguity

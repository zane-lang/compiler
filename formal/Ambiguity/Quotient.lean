import Ambiguity.Grammar
import Std.Data.HashMap

/-!
# Quotienting a guarded grammar

A map `h` on nonterminals is a *rule-index-preserving homomorphism* from `G` to
`Q` when every usable rule `i` of every `x` reappears as rule `i` of `h x`,
with its nonterminals renamed by `h` and a guard at least as large. Then every
tree of `G` is literally a tree of `Q` with the same yield, so `Q` unambiguous
implies `G` unambiguous. The partition refinement that proposes `h` is
unverified; `checkHom` is the verified part.
-/

namespace Ambiguity

def mapRhs (h : Nat → Nat) : List Sym → List Sym
  | [] => []
  | .t a :: rest => .t a :: mapRhs h rest
  | .n x :: rest => .n (h x) :: mapRhs h rest

/-- Rule `i` of `x` is matched by rule `i` of `h x`. -/
def ruleHom (h : Nat → Nat) (Q : GGrammar) (x i : Nat) (r : GRule) : Bool :=
  r.guard.isEmpty ||
    match (Q.rulesOf (h x))[i]? with
    | some r' => r'.rhs == mapRhs h r.rhs && r.guard.all (r'.guard.contains ·)
    | none => false

def checkHom (G Q : GGrammar) (h : Nat → Nat) : Bool :=
  h G.start == Q.start &&
  (List.range G.rules.size).all fun x =>
    ((G.rulesOf x).zipIdx).all fun (r, i) => ruleHom h Q x i r

/-! ## Producer: coarsest partition by rule signatures (unverified) -/

/-- Refine `init` colors until stable; return the color map and the
quotient grammar built from one representative per color. -/
def quotient (G : GGrammar) (init : Nat → Nat) : GGrammar × Array Nat := Id.run do
  let n := G.rules.size
  let mut colors : Array Nat := (Array.range n).map init
  let mut count := 0
  for _ in [0:n+1] do
    let mut intern : Std.HashMap (Nat × List (List Sym × List Tok)) Nat := {}
    let mut next : Array Nat := Array.replicate n 0
    for x in List.range n do
      let sig := (G.rulesOf x).map fun r =>
        (mapRhs (fun y => colors[y]!) r.rhs, r.guard)
      let key := (colors[x]!, sig)
      match intern.get? key with
      | some c => next := next.set! x c
      | none =>
        next := next.set! x intern.size
        intern := intern.insert key intern.size
    let stable := intern.size == count
    count := intern.size
    colors := next
    if stable then break
  -- representatives, start's class first
  let mut rep : Std.HashMap Nat Nat := {}
  let mut order : Array Nat := #[]
  for x in G.start :: List.range n do
    let c := colors[x]!
    if !rep.contains c then
      rep := rep.insert c order.size
      order := order.push x
  let h : Array Nat := colors.map fun c => rep.getD c 0
  let rules := order.map fun x => (G.rulesOf x).map fun r =>
    { r with rhs := mapRhs (fun y => h[y]!) r.rhs }
  return ({ rules, start := h[G.start]! }, h)

end Ambiguity

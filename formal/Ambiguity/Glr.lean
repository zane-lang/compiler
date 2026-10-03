import Ambiguity.GlrCorr

/-!
# The GLR parser's relation, read in the source grammar

The compiler parses with Menhir's `--GLR` backend, whose automaton `G` is built
for a rewritten grammar. `GlrSound text G` is the theorem for that parser:
`G`'s accepted trees are unambiguous, and `rho` reads each of them as a
derivation of the expanded source grammar of `text` with the same tokens,
injectively on yields.

The source grammar enters only through its productions, as the automaton
`sourceGrammarAut text` with no states.
-/

namespace Ambiguity

def sourceGrammarAut (text : String) : Except String Automaton := do
  let g ← Mly.sourceGrammar text
  let nts := (g.prods.foldl (fun (l : List String) p => if l.contains p.lhs then l else l ++ [p.lhs]) []).toArray
  return { prods := g.prods.map fun p => (p.lhs, p.rhs), nts, trans := #[], reds := #[], accept := #[],
           start := g.start }

def GlrSound (text : String) (G : Automaton) : Prop :=
  AUnambiguous G ∧
  ∃ S, sourceGrammarAut text = .ok S ∧ ∃ rho : ATree → ATree,
    (∀ t, Accepted G t → AWF S (rho t) ∧ (rho t).yield S = t.yield G ∧ S.lhs (rho t).prod = S.start) ∧
    (∀ t₁ t₂, Accepted G t₁ → Accepted G t₂ → (rho t₁).yield S = (rho t₂).yield S → rho t₁ = rho t₂) ∧
    (∀ t₁ t₂, Accepted G t₁ → Accepted G t₂ → rho t₁ = rho t₂ → t₁ = t₂)

/-- Everything the producer computes for the GLR check; none of it is trusted. -/
structure GlrEvidence where
  ev : Evidence
  corr : Array Corr
  base : Std.HashMap String String
  eps : Std.HashMap String ATree

def verifyGlr (text : String) (G : Automaton) (g : GlrEvidence) : Bool :=
  verify G g.ev &&
  match sourceGrammarAut text with
  | .ok S => checkCorr G S g.corr g.base g.eps
  | .error _ => false

theorem verify_wf {A : Automaton} {ev : Evidence} (h : verify A ev = true) : A.wf = true := by
  simp only [verify, Bool.and_eq_true] at h
  exact h.1.1.1.1.1.1.1.1.1.1.1.1.1.1

/-- **The GLR parser's theorem.** -/
theorem verifyGlr_sound (text : String) (G : Automaton) (g : GlrEvidence) (h : verifyGlr text G g = true) :
    GlrSound text G := by
  unfold verifyGlr at h
  simp only [Bool.and_eq_true] at h
  have hU := verify_sound G g.ev h.1
  have h2 := h.2
  cases hS : sourceGrammarAut text with
  | error e => rw [hS] at h2; cases h2
  | ok S =>
    rw [hS] at h2
    have hg := glr_source G S g.corr g.base g.eps h2 (verify_wf h.1) hU
    refine ⟨hU, S, hS, rho S g.corr g.eps, hg.1, hg.2, fun t₁ t₂ h₁ h₂ he => ?_⟩
    apply hU t₁ t₂ h₁ h₂
    rw [← (hg.1 t₁ h₁).2.1, ← (hg.1 t₂ h₂).2.1, he]

/-! ## Producer (unverified) -/

section
variable (G S : Automaton) (base : Std.HashMap String String) (eps : Std.HashMap String ATree)

/-- A keep/drop pattern aligning a source right-hand side with a rewritten one. -/
def findKeep : List String → List String → Option (List Bool)
  | [], [] => some []
  | [], _ :: _ => none
  | x :: xs, ys =>
    let kept := match ys with
      | y :: ys' =>
        if (if S.isNt x then G.isNt y && baseOf base y == x else !G.isNt y && y == x)
        then (findKeep xs ys').map (true :: ·) else none
      | [] => none
    match kept with
    | some k => some k
    | none => if S.isNt x && eps.contains x then (findKeep xs ys).map (false :: ·) else none
end

/-- Menhir spells instantiated symbols `f(a,b)`; the expansion spells them `f_a_b_`. -/
def mangle (x : String) : String :=
  String.map (fun ch => if ch == '(' || ch == ',' || ch == ')' then '_' else ch) x

def produceCorr (G S : Automaton) :
    Except String (Array Corr × Std.HashMap String String × Std.HashMap String ATree) := do
  -- the source symbol each rewritten nonterminal stands for
  let mut base : Std.HashMap String String := {}
  for y in G.nts do
    let m := mangle y
    if S.isNt m then base := base.insert y m
    else if m.startsWith "nonempty_" && S.isNt (m.drop 9).toString then base := base.insert y (m.drop 9).toString
    else throw s!"no source symbol for {y}"
  -- one empty derivation per nullable source symbol
  let mut eps : Std.HashMap String ATree := {}
  let mut changed := true
  while changed do
    changed := false
    for p in [0:S.prods.size] do
      let (l, r) := S.prods[p]!
      if !eps.contains l && r.all eps.contains then
        eps := eps.insert l (.node p (r.map fun x => (eps.get? x).getD default))
        changed := true
  -- each rewritten production against the source productions of its symbol
  let mut corr : Array Corr := #[]
  for p in [0:G.prods.size] do
    let l := baseOf base (G.lhs p)
    let mut found : Option Corr := none
    for s in [0:S.prods.size] do
      if found.isSome then break
      if S.lhs s != l then continue
      match findKeep G S base eps (S.rhs s) (G.rhs p) with
      | some k => found := some (.align s k)
      | none => pure ()
    match found with
    | some c => corr := corr.push c
    | none =>
      match G.rhs p with
      | [y] => if G.isNt y && baseOf base y == l then corr := corr.push .unit
               else throw s!"production {p} of {G.lhs p} matches no source production"
      | _ => throw s!"production {p} of {G.lhs p} matches no source production"
  return (corr, base, eps)

end Ambiguity

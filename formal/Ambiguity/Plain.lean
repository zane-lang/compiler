import Ambiguity.Product
import Ambiguity.QuotientSound

/-! # Plain grammars: trees, unambiguity, and the quotient check -/

namespace Ambiguity

mutual
def Tree.pyield (G : PGrammar) (x : Nat) : Tree → List Tok
  | .node i kids =>
    match (G.rulesOf x)[i]? with
    | some r => rhsYield r (pyields G (rhsNts r) kids)
    | none => []
def pyields (G : PGrammar) : List Nat → List Tree → List (List Tok)
  | x :: xs, t :: ts => t.pyield G x :: pyields G xs ts
  | _, _ => []
end

mutual
inductive PWF (G : PGrammar) : Nat → Tree → Prop
  | node {x i kids} (r : List Sym) : (G.rulesOf x)[i]? = some r → PWFs G r kids → PWF G x (.node i kids)
inductive PWFs (G : PGrammar) : List Sym → List Tree → Prop
  | nil : PWFs G [] []
  | term {a rest kids} : PWFs G rest kids → PWFs G (.t a :: rest) kids
  | nt {x rest t kids} : PWF G x t → PWFs G rest kids → PWFs G (.n x :: rest) (t :: kids)
end

def PUnambiguous (G : PGrammar) : Prop :=
  ∀ t₁ t₂, PWF G G.start t₁ → PWF G G.start t₂ → t₁.pyield G G.start = t₂.pyield G G.start → t₁ = t₂

def pcheckHom (G Q : PGrammar) (h : Nat → Nat) : Bool :=
  h G.start == Q.start &&
  (List.range G.rules.size).all fun x =>
    ((G.rulesOf x).zipIdx).all fun (r, i) => (Q.rulesOf (h x))[i]? == some (mapRhs h r)

section
variable {G Q : PGrammar} {h : Nat → Nat} (hc : pcheckHom G Q h = true)
include hc

theorem phom_rule {x i : Nat} {r : List Sym} (hr : (G.rulesOf x)[i]? = some r) :
    (Q.rulesOf (h x))[i]? = some (mapRhs h r) := by
  unfold pcheckHom at hc
  simp only [Bool.and_eq_true, List.all_eq_true] at hc
  have hx : x < G.rules.size := by
    refine Classical.byContradiction fun hx => ?_
    simp [PGrammar.rulesOf, Array.getD, hx] at hr
  have hmem : (r, i) ∈ (G.rulesOf x).zipIdx := by
    rw [List.mem_zipIdx_iff_getElem?]; simpa using hr
  simpa using hc.2 x (List.mem_range.mpr hx) _ hmem

mutual
theorem phom_wf {x : Nat} {t : Tree} (hw : PWF G x t) :
    PWF Q (h x) t ∧ t.pyield Q (h x) = t.pyield G x := by
  match hw with
  | @PWF.node _ _ i kids r hr hs =>
    have hr' := phom_rule hc hr
    obtain ⟨hs', hy⟩ := phom_wfs hs
    refine ⟨PWF.node _ hr' hs', ?_⟩
    simp only [Tree.pyield, hr, hr']
    exact hy

theorem phom_wfs {rhs : List Sym} {kids : List Tree} (hw : PWFs G rhs kids) :
    PWFs Q (mapRhs h rhs) kids ∧
      rhsYield (mapRhs h rhs) (pyields Q (rhsNts (mapRhs h rhs)) kids) =
        rhsYield rhs (pyields G (rhsNts rhs) kids) := by
  match hw with
  | .nil => exact ⟨PWFs.nil, rfl⟩
  | @PWFs.term _ a rest _ hs =>
    obtain ⟨hs', hy⟩ := phom_wfs hs
    exact ⟨PWFs.term hs', by simp only [mapRhs, rhsNts, rhsYield]; rw [hy]⟩
  | @PWFs.nt _ y rest k ks hk hs =>
    obtain ⟨hs', hy⟩ := phom_wfs hs
    obtain ⟨hk', hyk⟩ := phom_wf hk
    exact ⟨PWFs.nt hk' hs', by simp only [mapRhs, rhsNts, pyields, rhsYield]; rw [hyk, hy]⟩
end

theorem phom_sound (hq : PUnambiguous Q) : PUnambiguous G := by
  intro t₁ t₂ w₁ w₂ hy
  have hs : h G.start = Q.start := by
    unfold pcheckHom at hc; simp only [Bool.and_eq_true, beq_iff_eq] at hc; exact hc.1
  obtain ⟨w₁', y₁⟩ := phom_wf hc w₁
  obtain ⟨w₂', y₂⟩ := phom_wf hc w₂
  rw [hs] at w₁' w₂' y₁ y₂
  exact hq _ _ w₁' w₂' (by rw [y₁, y₂, hy])

end

end Ambiguity

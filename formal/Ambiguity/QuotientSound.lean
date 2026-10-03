import Ambiguity.Quotient

/-! # Soundness of the quotient check -/

namespace Ambiguity

theorem rhsNts_mapRhs (h : Nat → Nat) : ∀ rhs, rhsNts (mapRhs h rhs) = (rhsNts rhs).map h
  | [] => rfl
  | .t _ :: rest => by simp [mapRhs, rhsNts, rhsNts_mapRhs h rest]
  | .n _ :: rest => by simp [mapRhs, rhsNts, rhsNts_mapRhs h rest]

section
variable {G Q : GGrammar} {h : Nat → Nat} (hc : checkHom G Q h = true)
include hc

theorem hom_rule {x i : Nat} {r : GRule} (hr : (G.rulesOf x)[i]? = some r) (hne : r.guard ≠ []) :
    ∃ r', (Q.rulesOf (h x))[i]? = some r' ∧ r'.rhs = mapRhs h r.rhs ∧ ∀ a ∈ r.guard, a ∈ r'.guard := by
  unfold checkHom at hc
  simp only [Bool.and_eq_true, List.all_eq_true] at hc
  have hx : x < G.rules.size := by
    refine Classical.byContradiction fun hx => ?_
    simp [GGrammar.rulesOf, Array.getD, hx] at hr
  have hmem : (r, i) ∈ (G.rulesOf x).zipIdx := by
    rw [List.mem_zipIdx_iff_getElem?]; simpa using hr
  have := hc.2 x (List.mem_range.mpr hx) _ hmem
  unfold ruleHom at this
  simp only [Bool.or_eq_true, List.isEmpty_iff] at this
  rcases this with he | this
  · exact absurd he hne
  · split at this
    · rename_i r' hr'
      simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true, List.contains_iff_mem] at this
      exact ⟨r', hr', this.1, this.2⟩
    · simp at this

mutual
theorem hom_wf {x : Nat} {fol : Tok} {t : Tree} (hw : WF G x fol t) :
    WF Q (h x) fol t ∧ t.yield Q (h x) = t.yield G x := by
  match hw with
  | @WF.node _ _ _ i kids r hr hfol hs =>
    obtain ⟨r', hr', hrhs, hg⟩ := hom_rule hc hr (List.ne_nil_of_mem hfol)
    obtain ⟨hs', hy⟩ := hom_wfs hs
    refine ⟨WF.node r' hr' (hg _ hfol) (hrhs ▸ hs'), ?_⟩
    simp only [Tree.yield, hr, hr', hrhs]
    exact hy

theorem hom_wfs {rhs : List Sym} {fol : Tok} {kids : List Tree} (hw : WFs G rhs fol kids) :
    WFs Q (mapRhs h rhs) fol kids ∧
      rhsYield (mapRhs h rhs) (yields Q (rhsNts (mapRhs h rhs)) kids) =
        rhsYield rhs (yields G (rhsNts rhs) kids) := by
  match hw with
  | .nil => exact ⟨WFs.nil, rfl⟩
  | @WFs.term _ a rest _ _ hs =>
    obtain ⟨hs', hy⟩ := hom_wfs hs
    exact ⟨WFs.term hs', by simp only [mapRhs, rhsNts, rhsYield]; rw [hy]⟩
  | @WFs.nt _ y rest _ k ks hk hs =>
    obtain ⟨hs', hy⟩ := hom_wfs hs
    obtain ⟨hk', hyk⟩ := hom_wf hk
    refine ⟨WFs.nt ?_ hs', ?_⟩
    · rw [hy]; exact hk'
    · simp only [mapRhs, rhsNts, yields, rhsYield]; rw [hyk, hy]
end

/-- A grammar is unambiguous when a homomorphic image of it is. -/
theorem hom_sound (hq : Unambiguous Q) : Unambiguous G := by
  intro t₁ t₂ w₁ w₂ hy
  have hs : h G.start = Q.start := by
    unfold checkHom at hc; simp only [Bool.and_eq_true, beq_iff_eq] at hc; exact hc.1
  obtain ⟨w₁', y₁⟩ := hom_wf hc w₁
  obtain ⟨w₂', y₂⟩ := hom_wf hc w₂
  rw [hs] at w₁' w₂' y₁ y₂
  exact hq _ _ w₁' w₂' (by rw [y₁, y₂, hy])

end

end Ambiguity

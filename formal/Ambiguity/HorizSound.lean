import Ambiguity.Wsup
import Ambiguity.UniverseCheck
import Ambiguity.Count

/-!
# Soundness of the horizontal compilation

From the universe checks: every grammar derivation is counted by the model.
-/

namespace Ambiguity

section
variable (H : HFacts) (E : PGrammar) (keys : Array UKey) (fI : Array (Option Nat)) (M : Model)

theorem edgesOk_sum {spec : List SEdge} {es : List Edge} (h : edgesOk keys fI spec es = true)
    (g : SEdge → S) (f : Edge → S) (hg : ∀ s e, edgeOk keys fI s e = true → g s ≤ f e) :
    sumL spec g ≤ sumL es f := by
  unfold edgesOk at h
  simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at h
  obtain ⟨hl, hz⟩ := h
  induction spec generalizing es with
  | nil => exact S.zero_le _
  | cons s spec ih =>
    cases es with
    | nil => simp at hl
    | cons e es =>
      simp only [sumL_cons]
      exact S.add_le_add (hg s e (hz (s, e) (by simp)))
        (ih (by simpa using hl) (fun p hp => hz p (by simp [hp])))

variable (hU : checkUniverse H E keys fI M = true)
include hU

theorem universe_parts : keys.size = M.size ∧
    (∀ j < keys.size, edgesOk keys fI (specEdges H E (keys[j]?.getD (.fin 0))) (M.out j) = true) ∧
    M.frags.size = fI.size ∧ fI[0]? = some (some E.start) ∧ fI.toList.Nodup ∧
    (∀ f < M.frags.size, keys[M.fin f]? = some (.fin f) ∧
      tgtOk keys (headTgt H (fI.getD f none) (M.fin f)) (M.entry f) = true) := by
  unfold checkUniverse at hU
  simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true, List.mem_range, decide_eq_true_eq] at hU
  obtain ⟨⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩, h6⟩ := hU
  exact ⟨h1, fun j hj => by simpa using h2 j hj, h3, h4, h5, fun f hf => by simpa using h6 f hf⟩

theorem edges_of_key {j : Nat} {k : UKey} (hj : keys[j]? = some k) :
    edgesOk keys fI (specEdges H E k) (M.out j) = true := by
  have hjs : j < keys.size := by
    rcases Nat.lt_or_ge j keys.size with h | h; exact h
    simp [Array.getElem?_eq_none h] at hj
  have := (universe_parts H E keys fI M hU).2.1 j hjs
  rwa [hj] at this

end


theorem sumL_map {α β} (l : List α) (g : α → β) (f : β → S) :
    sumL (l.map g) f = sumL l (fun a => f (g a)) := by
  induction l with
  | nil => rfl
  | cons a l ih => simp [ih]

/-! ## Weights of horizontal DFAs over structured words -/

/-- Count of the fragment whose interior is `inner`. -/
noncomputable def fragW (M : Model) (fI : Array (Option Nat)) (inner : Option Nat) (v : List Item) : S :=
  match (List.range fI.size).find? (fun f => fI[f]? == some inner) with
  | some f => Wsup M (M.entry f) v (M.fin f)
  | none => 0

theorem fragW_eq (M : Model) (fI : Array (Option Nat)) (hnd : fI.toList.Nodup) {f : Nat} {inner : Option Nat}
    (hf : fI[f]? = some inner) (v : List Item) : fragW M fI inner v = Wsup M (M.entry f) v (M.fin f) := by
  unfold fragW
  have hfs : f < fI.size := by
    rcases Nat.lt_or_ge f fI.size with h | h; exact h
    simp [Array.getElem?_eq_none h] at hf
  cases hfind : (List.range fI.size).find? (fun f => fI[f]? == some inner) with
  | none =>
    have := List.find?_eq_none.mp hfind f (List.mem_range.mpr hfs)
    simp [hf] at this
  | some g =>
    have hg := List.find?_some hfind
    have hgm := List.mem_of_find?_eq_some hfind
    simp only [beq_iff_eq] at hg
    have hgs : g < fI.size := List.mem_range.mp hgm
    have : g = f := by
      have e1 : fI.toList[g]? = some inner := by simpa using hg
      have e2 : fI.toList[f]? = some inner := by simpa using hf
      exact (List.Nodup.getElem?_inj (by simpa using hgs) hnd).mp (e1.trans e2.symm)
    subst this; rfl

/-- The weight of matching one atom against one item. -/
noncomputable def wtM (M : Model) (fI : Array (Option Nat)) : Atom → Item → S
  | .t a, .tok b => if a = b then 1 else 0
  | .call o inner c, .grp o' v c' => if o = o' ∧ c = c' then fragW M fI inner v else 0
  | _, _ => 0

/-- Weighted acceptance of a DFA from state `d` on a structured word. -/
def DW (D : DFA) (wt : Atom → Item → S) : Nat → List Item → S
  | d, [] => D.accAt d
  | d, x :: u => sumL (D.transAt d) fun p => wt p.1 x * DW D wt p.2 u

section
variable (H : HFacts) (E : PGrammar) (keys : Array UKey) (fI : Array (Option Nat)) (M : Model)
variable (hU : checkUniverse H E keys fI M = true)
include hU

/-- **(d)** A copy of a horizontal DFA in the model counts what the DFA
counts, followed by whatever its continuation counts. -/
theorem comp_lower : ∀ (u : List Item) (lid d tail j : Nat), keys[j]? = some (.comp lid d tail) →
    ∀ u₂ z, DW (H.dfa lid) (wtM M fI) d u * Wsup M tail u₂ z ≤ Wsup M j (u ++ u₂) z := by
  have hnd := (universe_parts H E keys fI M hU).2.2.2.2.1
  intro u
  induction u with
  | nil =>
    intro lid d tail j hj u₂ z
    have he := edges_of_key H E keys fI M hU hj
    refine S.le_trans ?_ (S.le_trans (S.le_add_left _ _) (Wsup_fwd M j ([] ++ u₂) z))
    simp only [DW]
    let g : SEdge → S := fun s => match s with
      | .eps (.id t) w => if t = tail then w * Wsup M tail u₂ z else 0
      | _ => 0
    refine S.le_trans ?_ (edgesOk_sum keys fI he g _ ?_)
    · simp only [specEdges]
      by_cases ha : (H.dfa lid).accAt d = 0
      · simp [ha]
      · simp only [ha, ite_false, sumL_append, sumL_cons, sumL_nil, S.add_zero]
        refine S.le_trans ?_ (S.le_add_right _ _)
        simp [g]
    · intro s e hse
      cases s with
      | eps t w =>
        cases t with
        | id t =>
          cases e with
          | eps t' w' =>
            simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hse
            obtain ⟨rfl, rfl⟩ := hse
            simp only [g, fe, List.nil_append]
            split <;> simp_all
          | _ => simp [edgeOk] at hse
        | _ => exact S.zero_le _
      | _ => exact S.zero_le _
  | cons x u ih =>
    intro lid d tail j hj u₂ z
    have he := edges_of_key H E keys fI M hU hj
    refine S.le_trans ?_ (S.le_trans (S.le_add_left _ _) (Wsup_fwd M j ((x :: u) ++ u₂) z))
    simp only [DW]
    let g : SEdge → S := fun s => match s with
      | .int a (.key (.comp lid' d' tail')) =>
        wtM M fI (.t a) x * DW (H.dfa lid') (wtM M fI) d' u * Wsup M tail' u₂ z
      | .call o inner (.key (.comp lid' d' tail')) c =>
        wtM M fI (.call o inner c) x * DW (H.dfa lid') (wtM M fI) d' u * Wsup M tail' u₂ z
      | _ => 0
    refine S.le_trans ?_ (edgesOk_sum keys fI he g _ ?_)
    · simp only [specEdges, sumL_append, sumL_mul]
      refine S.le_trans ?_ (S.le_add_left _ _)
      simp only [sumL_map]
      apply sumL_le_sumL
      intro p _
      obtain ⟨a, d'⟩ := p
      cases a <;> simp [g, S.mul_assoc]
    · intro s e hse
      cases s with
      | int a t =>
        cases t with
        | key k =>
          cases k with
          | comp lid' d' tail' =>
            cases e with
            | int a' t' =>
              simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hse
              obtain ⟨rfl, ht⟩ := hse
              simp only [g, fe, List.cons_append]
              cases x with
              | grp _ _ _ => simp [wtM]
              | tok b =>
                simp only [wtM]
                split
                · rw [S.one_mul]; exact ih lid' d' tail' t' ht u₂ z
                · simp
            | _ => simp [edgeOk] at hse
          | _ => exact S.zero_le _
        | _ => exact S.zero_le _
      | call o inner t c =>
        cases t with
        | key k =>
          cases k with
          | comp lid' d' tail' =>
            cases e with
            | call o' f t' c' =>
              simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hse
              obtain ⟨⟨⟨rfl, rfl⟩, hf⟩, ht⟩ := hse
              simp only [g, fe, List.cons_append]
              cases x with
              | tok _ => simp [wtM]
              | grp o'' v c'' =>
                simp only [wtM]
                split
                · rw [fragW_eq M fI hnd hf v, S.mul_assoc]
                  exact S.mul_le_mul (S.le_refl _) (ih lid' d' tail' t' ht u₂ z)
                · simp
            | _ => simp [edgeOk] at hse
          | _ => exact S.zero_le _
        | _ => exact S.zero_le _
      | _ => exact S.zero_le _

end

end Ambiguity

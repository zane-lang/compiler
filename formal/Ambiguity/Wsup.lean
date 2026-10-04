import Ambiguity.WLemmas

/-!
# Path counts without fuel

`Wsup` is the eventual value of `W n` (it is monotone in `n` and takes three
values). Both unfoldings hold for it without fuel bookkeeping.
-/

namespace Ambiguity

section
variable (M : Model)

open Classical in
noncomputable def Wsup (q : Nat) (v : List Item) (r : Nat) : S :=
  if ∃ n, W M n q v r = 2 then 2 else if ∃ n, W M n q v r = 1 then 1 else 0

theorem W_le_Wsup (n q : Nat) (v : List Item) (r : Nat) : W M n q v r ≤ Wsup M q v r := by
  unfold Wsup
  split
  · exact S.le_two _
  · rename_i h2
    split
    · rename_i h1
      have : W M n q v r ≠ 2 := fun e => h2 ⟨n, e⟩
      revert this; cases W M n q v r <;> decide
    · rename_i h1
      have a : W M n q v r ≠ 2 := fun e => h2 ⟨n, e⟩
      have b : W M n q v r ≠ 1 := fun e => h1 ⟨n, e⟩
      revert a b; cases W M n q v r <;> decide

theorem Wsup_attained (q : Nat) (v : List Item) (r : Nat) : ∃ N, ∀ m, N ≤ m → W M m q v r = Wsup M q v r := by
  unfold Wsup
  split
  · rename_i h2
    obtain ⟨N, hN⟩ := h2
    refine ⟨N, fun m hm => ?_⟩
    have := W_mono M hm q v r
    rw [hN] at this
    exact S.le_antisymm (S.le_two _) this
  · rename_i h2
    split
    · rename_i h1
      obtain ⟨N, hN⟩ := h1
      refine ⟨N, fun m hm => ?_⟩
      have := W_mono M hm q v r
      rw [hN] at this
      have : W M m q v r ≠ 2 := fun e => h2 ⟨m, e⟩
      revert this ‹1 ≤ W M m q v r›; cases W M m q v r <;> decide
    · rename_i h1
      refine ⟨0, fun m _ => ?_⟩
      have a : W M m q v r ≠ 2 := fun e => h2 ⟨m, e⟩
      have b : W M m q v r ≠ 1 := fun e => h1 ⟨m, e⟩
      revert a b; cases W M m q v r <;> decide

abbrev Arg := Nat × List Item × Nat

theorem attained_list : ∀ (l : List Arg), ∃ N, ∀ m, N ≤ m → ∀ a ∈ l, W M m a.1 a.2.1 a.2.2 = Wsup M a.1 a.2.1 a.2.2
  | [] => ⟨0, fun _ _ _ h => by cases h⟩
  | a :: l => by
    obtain ⟨N₁, h₁⟩ := Wsup_attained M a.1 a.2.1 a.2.2
    obtain ⟨N₂, h₂⟩ := attained_list l
    refine ⟨max N₁ N₂, fun m hm b hb => ?_⟩
    cases hb with
    | head => exact h₁ m (by omega)
    | tail _ hb => exact h₂ m (by omega) b hb

theorem Wsup_ge_base (q : Nat) (v : List Item) (r : Nat) : base q v r ≤ Wsup M q v r :=
  S.le_trans (W_base_le M 0 q v r) (W_le_Wsup M 0 q v r)

def feArgs (u : List Item) (z : Nat) : Edge → List Arg
  | .eps t _ => [(t, u, z)]
  | .int _ t => match u with | _ :: u' => [(t, u', z)] | [] => []
  | .call _ f t _ => match u with | .grp _ v _ :: u' => [(M.entry f, v, M.fin f), (t, u', z)] | _ => []

theorem fe_sup_le (N : Nat) (u : List Item) (z : Nat) (e : Edge)
    (h : ∀ a ∈ feArgs M u z e, W M N a.1 a.2.1 a.2.2 = Wsup M a.1 a.2.1 a.2.2) :
    fe M (Wsup M) (Wsup M) u z e ≤ fe M (W M N) (W M N) u z e := by
  cases e with
  | eps t w =>
    have e1 : W M N t u z = Wsup M t u z := h (t, u, z) (by simp [feArgs])
    simp only [fe]; rw [e1]; exact S.le_refl _
  | int a t =>
    cases u with
    | nil => simp [fe]
    | cons x u' =>
      cases x with
      | grp _ _ _ => simp [fe]
      | tok b =>
        have e1 : W M N t u' z = Wsup M t u' z := h (t, u', z) (by simp [feArgs])
        simp only [fe]; rw [e1]; exact S.le_refl _
  | call o f t c =>
    cases u with
    | nil => simp [fe]
    | cons x u' =>
      cases x with
      | tok _ => simp [fe]
      | grp o' v c' =>
        have e1 : W M N (M.entry f) v (M.fin f) = Wsup M (M.entry f) v (M.fin f) :=
          h (M.entry f, v, M.fin f) (by simp [feArgs])
        have e2 : W M N t u' z = Wsup M t u' z := h (t, u', z) (by simp [feArgs])
        simp only [fe]; rw [e1, e2]; exact S.le_refl _

/-- Forward unfolding without fuel. -/
theorem Wsup_fwd (q : Nat) (u : List Item) (z : Nat) :
    base q u z + sumL (M.out q) (fe M (Wsup M) (Wsup M) u z) ≤ Wsup M q u z := by
  obtain ⟨N, hN⟩ := attained_list M ((M.out q).flatMap (feArgs M u z))
  have h1 : sumL (M.out q) (fe M (Wsup M) (Wsup M) u z) ≤ sumL (M.out q) (fe M (W M N) (W M N) u z) :=
    sumL_le_sumL _ fun e he => fe_sup_le M N u z e fun a ha =>
      hN N (Nat.le_refl _) a (List.mem_flatMap.mpr ⟨e, he, ha⟩)
  exact S.le_trans (S.add_le_add (S.le_refl _) h1)
    (S.le_trans (fwd M N N q u z) (W_le_Wsup M _ q u z))

def stepArgs (q : Nat) (u : List Item) (p : Nat) : Edge → List Arg
  | .eps .. => [(q, u, p)]
  | .int .. => [(q, u.dropLast, p)]
  | .call _ f _ _ =>
    match u.getLast? with
    | some (.grp _ v _) => [(q, u.dropLast, p), (M.entry f, v, M.fin f)]
    | _ => [(q, u.dropLast, p)]

theorem stepC_sup_le (N q : Nat) (u : List Item) (z p : Nat) (e : Edge)
    (h : ∀ a ∈ stepArgs M q u p e, W M N a.1 a.2.1 a.2.2 = Wsup M a.1 a.2.1 a.2.2) :
    stepC M (Wsup M) q u z p e ≤ stepC M (W M N) q u z p e := by
  cases e with
  | eps t w =>
    have e1 : W M N q u p = Wsup M q u p := h (q, u, p) (by simp [stepArgs])
    simp only [stepC]; rw [e1]; exact S.le_refl _
  | int a t =>
    have e1 : W M N q u.dropLast p = Wsup M q u.dropLast p := h (q, u.dropLast, p) (by simp [stepArgs])
    simp only [stepC]; rw [e1]; exact S.le_refl _
  | call o f t c =>
    simp only [stepC]
    split
    · cases hl : u.getLast? with
      | none => simp
      | some x =>
        cases x with
        | tok _ => simp
        | grp o' v c' =>
          have e1 : W M N q u.dropLast p = Wsup M q u.dropLast p := h (q, u.dropLast, p) (by simp [stepArgs, hl])
          have e2 : W M N (M.entry f) v (M.fin f) = Wsup M (M.entry f) v (M.fin f) :=
            h (M.entry f, v, M.fin f) (by simp [stepArgs, hl])
          simp only; rw [e1, e2]; exact S.le_refl _
    · simp

/-- Backward unfolding without fuel. -/
theorem Wsup_bwd (q : Nat) (u : List Item) (z : Nat) :
    base q u z + sumL (List.range M.size) (fun p => sumL (M.out p) (stepC M (Wsup M) q u z p)) ≤
      Wsup M q u z := by
  obtain ⟨N, hN⟩ := attained_list M ((List.range M.size).flatMap fun p => (M.out p).flatMap (stepArgs M q u p))
  have h1 : sumL (List.range M.size) (fun p => sumL (M.out p) (stepC M (Wsup M) q u z p)) ≤
      sumL (List.range M.size) (fun p => sumL (M.out p) (stepC M (W M N) q u z p)) :=
    sumL_le_sumL _ fun p hp => sumL_le_sumL _ fun e he => stepC_sup_le M N q u z p e fun a ha =>
      hN N (Nat.le_refl _) a (List.mem_flatMap.mpr ⟨p, hp, List.mem_flatMap.mpr ⟨e, he, ha⟩⟩)
  refine S.le_trans (S.add_le_add (S.le_refl _) h1) ?_
  rw [← W_succ]
  exact W_le_Wsup M _ q u z

theorem Wsup_root (hu : RootUnambiguous M) (v : List Item) : Wsup M (M.entry 0) v (M.fin 0) ≤ 1 := by
  obtain ⟨N, hN⟩ := Wsup_attained M (M.entry 0) v (M.fin 0)
  rw [← hN N (Nat.le_refl _)]
  exact hu v N

end

end Ambiguity

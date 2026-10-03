import Ambiguity.HorizSound

/-!
# Determinization and minimization of a component

The witness of a component lists DFA states as closed vectors over the
component's NFA nodes. Every NFA path count is bounded by the DFA's weighted
acceptance, and minimization (a map to the library DFA, with dead states)
does not decrease it.
-/

namespace Ambiguity

/-! ## Sums over permutations and sublists -/

theorem sumL_perm {α} {l₁ l₂ : List α} (h : l₁.Perm l₂) (f : α → S) : sumL l₁ f = sumL l₂ f := by
  induction h with
  | nil => rfl
  | cons x _ ih => simp [ih]
  | swap x y l => simp only [sumL_cons]; rw [← S.add_assoc, S.add_comm (f y), S.add_assoc]
  | trans _ _ ih₁ ih₂ => rw [ih₁, ih₂]

theorem sumL_nodup_sub {α} [DecidableEq α] : ∀ {l₁ l₂ : List α}, l₁.Nodup → (∀ x ∈ l₁, x ∈ l₂) →
    ∀ (g : α → S), sumL l₁ g ≤ sumL l₂ g
  | [], _, _, _, _ => S.zero_le _
  | x :: l₁, l₂, hn, hs, g => by
    have hx : x ∈ l₂ := hs x (by simp)
    rw [sumL_perm (List.perm_cons_erase hx) g, sumL_cons, sumL_cons]
    refine S.add_le_add (S.le_refl _) (sumL_nodup_sub (List.nodup_cons.mp hn).2 ?_ g)
    intro y hy
    have hy₂ := hs y (by simp [hy])
    have hne : y ≠ x := fun e => (List.nodup_cons.mp hn).1 (e ▸ hy)
    exact (List.mem_erase_of_ne hne).mpr hy₂

theorem sumL_single {α} [DecidableEq α] {l : List α} (hn : l.Nodup) {a : α} (ha : a ∈ l) (y : S) :
    sumL l (fun b => if b = a then y else 0) = y := by
  induction l with
  | nil => cases ha
  | cons b l ih =>
    simp only [sumL_cons]
    by_cases hb : b = a
    · subst hb
      have : sumL l (fun c => if c = b then y else 0) = 0 :=
        sumL_zero _ fun c hc => by simp [show c ≠ b from fun e => (List.nodup_cons.mp hn).1 (e ▸ hc)]
      simp [this]
    · simp only [hb, ite_false, S.zero_add]
      exact ih (List.nodup_cons.mp hn).2 (by cases ha with | head => exact absurd rfl hb | tail _ h => exact h)

/-! ## Post-fixpoints as functions -/

theorem post_bound_fun (M : Model) (C R : Nat → S) (X : Nat → Nat → S)
    (hR : ∀ q, C q + sumL (List.range M.size) (fun p => R p * epsW M p q) ≤ R q)
    (h0 : ∀ q, X 0 q ≤ C q)
    (hs : ∀ n q, X (n + 1) q ≤ C q + sumL (List.range M.size) (fun p => X n p * epsW M p q)) :
    ∀ n q, X n q ≤ R q := by
  intro n
  induction n with
  | zero => intro q; exact S.le_trans (h0 q) (S.le_trans (S.le_add_right _ _) (hR q))
  | succ n ih =>
    intro q
    refine S.le_trans (hs n q) (S.le_trans ?_ (hR q))
    exact S.add_le_add (S.le_refl _) (sumL_le_sumL _ fun p _ => S.mul_le_mul (ih p) (S.le_refl _))

theorem isPost_fun (M : Model) (c R : Vec) (hp : isPost M c R = true) (f q : Nat) :
    getV c f q + sumL (List.range M.size) (fun p => getV R f p * epsW M p q) ≤ getV R f q := by
  rw [← epsIn_eq]
  by_cases hk : (f, q) ∈ postKeys M c R
  · unfold isPost at hp
    have := List.all_eq_true.mp hp _ hk
    simpa using this
  · obtain ⟨h1, h2⟩ := notKey_zero M c R f q hk
    rw [h1, h2]; exact S.zero_le _

/-- A combination of post-fixpoints with nonnegative weights is a
post-fixpoint of the combined initial vector. -/
theorem post_comb (M : Model) {ι} (I : List ι) (κ : ι → S) (c R : ι → Vec)
    (hp : ∀ i ∈ I, isPost M (c i) (R i) = true) (q : Nat) :
    sumL I (fun i => κ i * getV (c i) 0 q) +
      sumL (List.range M.size) (fun p => sumL I (fun i => κ i * getV (R i) 0 p) * epsW M p q) ≤
      sumL I (fun i => κ i * getV (R i) 0 q) := by
  simp only [sumL_mul, S.mul_assoc]
  rw [sumL_comm (List.range M.size) I, ← sumL_add]
  apply sumL_le_sumL; intro i hi
  rw [← mul_sumL, ← S.mul_add]
  exact S.mul_le_mul (S.le_refl _) (isPost_fun M (c i) (R i) (hp i hi) 0 q)

end Ambiguity

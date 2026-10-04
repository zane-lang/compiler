import Ambiguity.VpaSound

/-!
# Path counts: monotonicity, concatenation, and forward unfolding

`W` is defined by the last edge of a path. Building paths from the front
needs `fwd`: the empty path plus every path that starts with a given first
edge are counted.
-/

namespace Ambiguity

section
variable (M : Model)

theorem stepC_mono {W₁ W₂ : Nat → List Item → Nat → S} (h : ∀ q v r, W₁ q v r ≤ W₂ q v r)
    (q : Nat) (v : List Item) (r p : Nat) (e : Edge) : stepC M W₁ q v r p e ≤ stepC M W₂ q v r p e := by
  cases e with
  | eps t w =>
    simp only [stepC]; split
    · exact S.mul_le_mul (h _ _ _) (S.le_refl _)
    · exact S.le_refl _
  | int a t =>
    simp only [stepC]; split
    · cases v.getLast? with
      | none => exact S.le_refl _
      | some x =>
        cases x with
        | tok b => simp only; split; exact h _ _ _; exact S.le_refl _
        | grp _ _ _ => exact S.le_refl _
    · exact S.le_refl _
  | call o f t c =>
    simp only [stepC]; split
    · cases v.getLast? with
      | none => exact S.le_refl _
      | some x =>
        cases x with
        | tok b => exact S.le_refl _
        | grp o' inner c' =>
          simp only; split
          · exact S.mul_le_mul (h _ _ _) (h _ _ _)
          · exact S.le_refl _
    · exact S.le_refl _

theorem W_succ_le (n : Nat) : ∀ q v r, W M n q v r ≤ W M (n + 1) q v r := by
  induction n with
  | zero => intro q v r; rw [W_zero, W_succ]; exact S.le_add_right _ _
  | succ n ih =>
    intro q v r
    rw [W_succ M n, W_succ M (n + 1)]
    exact S.add_le_add (S.le_refl _) (sumL_le_sumL _ fun p _ => sumL_le_sumL _ fun e _ =>
      stepC_mono M ih q v r p e)

theorem W_mono {a b : Nat} (h : a ≤ b) (q : Nat) (v : List Item) (r : Nat) : W M a q v r ≤ W M b q v r := by
  induction b with
  | zero => have : a = 0 := by omega
            subst this; exact S.le_refl _
  | succ b ih =>
    rcases Nat.lt_or_ge a (b + 1) with h' | h'
    · exact S.le_trans (ih (by omega)) (W_succ_le M b q v r)
    · have : a = b + 1 := by omega
      subst this; exact S.le_refl _

theorem W_base_le (n q : Nat) (v : List Item) (r : Nat) : base q v r ≤ W M n q v r := by
  cases n with
  | zero => exact S.le_refl _
  | succ n => rw [W_succ]; exact S.le_add_right _ _

theorem W_nil_self (n q : Nat) : 1 ≤ W M n q [] q := by
  have := W_base_le M n q [] q
  simpa [base] using this

/-! ## Forward unfolding -/

/-- What a first edge `e` contributes to paths reading `u` into `z`, with
`Wc` counting call interiors and `Wt` the rest of the path. -/
def fe (Wc Wt : Nat → List Item → Nat → S) (u : List Item) (z : Nat) : Edge → S
  | .eps t w => w * Wt t u z
  | .int a t =>
    match u with
    | .tok b :: u' => if a = b then Wt t u' z else 0
    | _ => 0
  | .call o f t c =>
    match u with
    | .grp o' v c' :: u' => if o = o' ∧ c = c' then Wc (M.entry f) v (M.fin f) * Wt t u' z else 0
    | _ => 0

/-- The word read before the last edge `e'`, and that edge's factor. -/
def preOf (u : List Item) : Edge → List Item
  | .eps .. => u
  | _ => u.dropLast

def lam (Wc : Nat → List Item → Nat → S) (u : List Item) (z : Nat) : Edge → S
  | .eps t w => if t = z then w else 0
  | .int a t =>
    if t = z then (match u.getLast? with | some (.tok b) => if a = b then 1 else 0 | _ => 0) else 0
  | .call o f t c =>
    if t = z then
      (match u.getLast? with
       | some (.grp o' v c') => if o = o' ∧ c = c' then Wc (M.entry f) v (M.fin f) else 0
       | _ => 0)
    else 0

theorem stepC_eq (Wn : Nat → List Item → Nat → S) (q : Nat) (u : List Item) (z p : Nat) (e : Edge) :
    stepC M Wn q u z p e = Wn q (preOf u e) p * lam M Wn u z e := by
  cases e with
  | eps t w => simp only [stepC, preOf, lam]; split <;> simp
  | int a t =>
    simp only [stepC, preOf, lam]; split
    · cases u.getLast? with
      | none => simp
      | some x => cases x with
        | tok b => simp only; split <;> simp
        | grp _ _ _ => simp
    · simp
  | call o f t c =>
    simp only [stepC, preOf, lam]; split
    · cases u.getLast? with
      | none => simp
      | some x => cases x with
        | tok b => simp
        | grp o' v c' => simp only; split <;> simp
    · simp

theorem fe_add (Wc A B : Nat → List Item → Nat → S) (u : List Item) (z : Nat) (e : Edge) :
    fe M Wc (fun t r z => A t r z + B t r z) u z e = fe M Wc A u z e + fe M Wc B u z e := by
  cases e with
  | eps t w => simp [fe, S.mul_add]
  | int a t =>
    simp only [fe]; split
    · split <;> simp
    · simp
  | call o f t c =>
    simp only [fe]; split
    · split <;> simp [S.mul_add]
    · simp

theorem fe_sum {α : Type} (Wc : Nat → List Item → Nat → S) (l : List α) (F : α → Nat → List Item → Nat → S)
    (u : List Item) (z : Nat) (e : Edge) :
    fe M Wc (fun t r z => sumL l fun i => F i t r z) u z e = sumL l fun i => fe M Wc (F i) u z e := by
  induction l with
  | nil =>
    cases e with
    | eps t w => simp [fe]
    | int a t => simp only [fe, sumL_nil]; split; (split <;> rfl); rfl
    | call o f t c => simp only [fe, sumL_nil]; split; (split <;> simp); rfl
  | cons i l ih =>
    simp only [sumL_cons]
    rw [fe_add M Wc (F i) (fun t r z => sumL l fun i => F i t r z), ih]

theorem fe_mono {Wc Wc' A B : Nat → List Item → Nat → S} (hc : ∀ q v r, Wc q v r ≤ Wc' q v r)
    (h : ∀ q v r, A q v r ≤ B q v r) (u : List Item) (z : Nat) (e : Edge) :
    fe M Wc A u z e ≤ fe M Wc' B u z e := by
  cases e with
  | eps t w => exact S.mul_le_mul (S.le_refl _) (h _ _ _)
  | int a t =>
    simp only [fe]; split
    · split; exact h _ _ _; exact S.le_refl _
    · exact S.le_refl _
  | call o f t c =>
    simp only [fe]; split
    · split; exact S.mul_le_mul (hc _ _ _) (h _ _ _); exact S.le_refl _
    · exact S.le_refl _

theorem lam_mono {Wc Wc' : Nat → List Item → Nat → S} (hc : ∀ q v r, Wc q v r ≤ Wc' q v r)
    (u : List Item) (z : Nat) (e : Edge) : lam M Wc u z e ≤ lam M Wc' u z e := by
  cases e with
  | eps t w => exact S.le_refl _
  | int a t => exact S.le_refl _
  | call o f t c =>
    simp only [lam]; split
    · cases u.getLast? with
      | none => exact S.le_refl _
      | some x => cases x with
        | tok b => exact S.le_refl _
        | grp o' v c' => simp only; split; exact hc _ _ _; exact S.le_refl _
    · exact S.le_refl _

/-- A first edge alone: its contribution with an empty rest. -/
theorem fe_base_le {Wc Wc' : Nat → List Item → Nat → S} (hc : ∀ q v r, Wc q v r ≤ Wc' q v r)
    (q : Nat) (u : List Item) (z : Nat) (e : Edge) :
    fe M Wc base u z e ≤ lam M Wc' u z e * base q (preOf u e) q := by
  cases e with
  | eps t w =>
    simp only [fe, lam, preOf, base]
    by_cases ht : t = z
    · subst ht; by_cases hu : u.isEmpty <;> simp [hu]
    · simp [ht]
  | int a t =>
    simp only [fe, lam, preOf]
    cases u with
    | nil => simp
    | cons x u' =>
      cases x with
      | grp _ _ _ => simp
      | tok b =>
        simp only
        by_cases hab : a = b
        · subst hab
          cases u' with
          | nil => by_cases ht : t = z <;> simp [base, ht]
          | cons y u'' => simp [base]
        · simp [hab]
  | call o f t c =>
    simp only [fe, lam, preOf]
    cases u with
    | nil => simp
    | cons x u' =>
      cases x with
      | tok b => simp
      | grp o' v c' =>
        simp only
        by_cases hoc : o = o' ∧ c = c'
        · cases u' with
          | nil =>
            by_cases ht : t = z
            · simp [base, ht, hoc, hc]
            · simp [base, ht]
          | cons y u'' => simp [base]
        · simp [hoc]

theorem lam_nil_of_noneps (Wc : Nat → List Item → Nat → S) (z : Nat) {e : Edge} (h : e.isEps = false) :
    lam M Wc [] z e = 0 := by
  cases e with
  | eps t w => simp [Edge.isEps] at h
  | int a t => simp [lam]
  | call o f t c => simp [lam]

theorem cons_shift (Wc : Nat → List Item → Nat → S) (x : Item) (u' : List Item) (z : Nat) (e : Edge)
    (h : e.isEps = true ∨ u' ≠ []) :
    preOf (x :: u') e = x :: preOf u' e ∧ lam M Wc (x :: u') z e = lam M Wc u' z e := by
  cases e with
  | eps t w => simp [preOf, lam]
  | int a t =>
    simp [Edge.isEps] at h
    simp only [preOf, lam, List.dropLast_cons_of_ne_nil h, List.getLast?_cons, true_and]
    cases hl : u'.getLast? with
    | none => exact absurd (List.getLast?_eq_none_iff.mp hl) h
    | some y => simp
  | call o f t c =>
    simp [Edge.isEps] at h
    simp only [preOf, lam, List.dropLast_cons_of_ne_nil h, List.getLast?_cons, true_and]
    cases hl : u'.getLast? with
    | none => exact absurd (List.getLast?_eq_none_iff.mp hl) h
    | some y => simp

theorem fe_step_le (Wc Wn : Nat → List Item → Nat → S) (u : List Item) (z p : Nat) (e' e : Edge) :
    fe M Wc (fun t r z => stepC M Wn t r z p e') u z e ≤
      lam M Wn u z e' * fe M Wc (fun t r _ => Wn t r p) (preOf u e') p e := by
  simp only [stepC_eq]
  cases e with
  | eps t w =>
    simp only [fe]
    rw [S.mul_comm (Wn _ _ _) _, ← S.mul_assoc, S.mul_comm w, S.mul_assoc]; exact S.le_refl _
  | int a t =>
    cases u with
    | nil => simp [fe]
    | cons x u' =>
      by_cases hk : e'.isEps = true ∨ u' ≠ []
      · obtain ⟨hp, hl⟩ := cons_shift M Wn x u' z e' hk
        rw [hp, hl]
        cases x with
        | grp _ _ _ => simp [fe]
        | tok b =>
          simp only [fe]
          split
          · rw [S.mul_comm]; exact S.le_refl _
          · simp
      · simp only [not_or, Bool.not_eq_true, ne_eq, Decidable.not_not] at hk
        obtain ⟨hk1, hk2⟩ := hk
        subst hk2
        cases x with
        | grp _ _ _ => simp [fe]
        | tok b => simp only [fe]; split <;> simp [lam_nil_of_noneps M Wn z hk1]
  | call o f t c =>
    cases u with
    | nil => simp [fe]
    | cons x u' =>
      by_cases hk : e'.isEps = true ∨ u' ≠ []
      · obtain ⟨hp, hl⟩ := cons_shift M Wn x u' z e' hk
        rw [hp, hl]
        cases x with
        | tok _ => simp [fe]
        | grp o' v c' =>
          simp only [fe]
          split
          · rw [S.mul_comm (lam M Wn u' z e'), S.mul_assoc, S.mul_comm (Wn t _ p)]; exact S.le_refl _
          · simp
      · simp only [not_or, Bool.not_eq_true, ne_eq, Decidable.not_not] at hk
        obtain ⟨hk1, hk2⟩ := hk
        subst hk2
        cases x with
        | tok _ => simp [fe]
        | grp o' v c' => simp only [fe]; split <;> simp [lam_nil_of_noneps M Wn z hk1]

theorem sum_at_q_le (q : Nat) (g : Nat → Edge → S) (hg : ∀ p e, p ≠ q → g p e = 0) :
    sumL (M.out q) (g q) ≤ sumL (List.range M.size) fun p => sumL (M.out p) (g p) := by
  by_cases hq : q < M.size
  · exact le_sumL (List.mem_range.mpr hq) (fun p => sumL (M.out p) (g p))
  · rw [out_of_size M q (by omega)]; exact S.zero_le _

/-- **Forward unfolding.** The empty path and the paths through each first
edge are all counted by a larger fuel. -/
theorem fwd (c : Nat) : ∀ b q u z,
    base q u z + sumL (M.out q) (fe M (W M c) (W M b) u z) ≤ W M (b + c + 1) q u z := by
  intro b
  induction b with
  | zero =>
    intro q u z
    rw [Nat.zero_add, W_succ]
    refine S.add_le_add (S.le_refl _) ?_
    have h1 : sumL (M.out q) (fe M (W M c) (W M 0) u z) ≤
        sumL (M.out q) fun e => stepC M (W M c) q u z q e := by
      apply sumL_le_sumL; intro e _
      rw [stepC_eq, S.mul_comm]
      refine S.le_trans (fe_base_le M (fun _ _ _ => S.le_refl _) q u z e) ?_
      exact S.mul_le_mul (S.le_refl _) (W_base_le M c q _ q)
    refine S.le_trans h1 ?_
    have h2 := sum_at_q_le M q (fun p e => if p = q then stepC M (W M c) q u z p e else 0)
      (by intro p e hp; simp [hp])
    simp only [ite_true] at h2
    refine S.le_trans h2 ?_
    exact sumL_le_sumL _ fun p _ => sumL_le_sumL _ fun e _ => by split <;> simp
  | succ b ih =>
    intro q u z
    rw [show b + 1 + c + 1 = (b + c + 1) + 1 by omega, W_succ M (b + c + 1)]
    refine S.add_le_add (S.le_refl _) ?_
    -- split each first edge's rest into its empty part and its last edges
    have hsplit : ∀ e, fe M (W M c) (W M (b + 1)) u z e =
        fe M (W M c) base u z e +
          sumL (List.range M.size) fun p => sumL (M.out p) fun e' =>
            fe M (W M c) (fun t r z => stepC M (W M b) t r z p e') u z e := by
      intro e
      have : W M (b + 1) = fun t r z => base t r z +
          sumL (List.range M.size) fun p => sumL (M.out p) fun e' => stepC M (W M b) t r z p e' := by
        funext t r z; rw [W_succ]
      rw [this, fe_add, fe_sum]
      congr 1
      apply sumL_congr; intro p _
      rw [fe_sum]
    rw [sumL_congr _ (fun e _ => hsplit e), sumL_add]
    rw [sumL_comm (M.out q) (List.range M.size)]
    simp only [sumL_comm (M.out q) (M.out _)]
    -- the empty rests sit at `p = q`
    have hA : sumL (M.out q) (fe M (W M c) base u z) ≤
        sumL (List.range M.size) fun p => sumL (M.out p) fun e' =>
          lam M (W M (b + c + 1)) u z e' * base q (preOf u e') p := by
      refine S.le_trans ?_ (sum_at_q_le M q _ ?_)
      · exact sumL_le_sumL _ fun e _ =>
          fe_base_le M (fun q v r => W_mono M (by omega) q v r) q u z e
      · intro p e hp; simp [base, Ne.symm hp]
    refine S.le_trans (S.add_le_add hA (S.le_refl _)) ?_
    rw [← sumL_add]
    apply sumL_le_sumL; intro p _
    rw [← sumL_add]
    apply sumL_le_sumL; intro e' _
    rw [stepC_eq]
    have hB : (sumL (M.out q) fun e => fe M (W M c) (fun t r z => stepC M (W M b) t r z p e') u z e) ≤
        lam M (W M (b + c + 1)) u z e' * sumL (M.out q) (fe M (W M c) (W M b) (preOf u e') p) := by
      rw [mul_sumL]
      apply sumL_le_sumL; intro e _
      refine S.le_trans (fe_step_le M (W M c) (W M b) u z p e' e) ?_
      exact S.mul_le_mul (lam_mono M (fun q v r => W_mono M (by omega) q v r) u z e') (S.le_refl _)
    refine S.le_trans (S.add_le_add (S.le_refl _) hB) ?_
    rw [← S.mul_add, S.mul_comm]
    exact S.mul_le_mul (ih q (preOf u e') p) (S.le_refl _)

end

end Ambiguity

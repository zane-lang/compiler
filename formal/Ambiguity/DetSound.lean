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


/-! ## Weighted runs of a DFA -/

def DWp (D : DFA) (wt : Atom → Item → S) : Nat → List Item → Nat → S
  | d, [], d' => if d = d' then 1 else 0
  | d, x :: u, d' => sumL (D.transAt d) fun p => wt p.1 x * DWp D wt p.2 u d'

section
variable (D : DFA) (wt : Atom → Item → S) (N : Nat)
  (hT : ∀ d < N, ∀ p ∈ D.transAt d, p.2 < N)

include hT in
theorem DWp_snoc (x : Item) : ∀ (u : List Item) (d₀ d' : Nat), d₀ < N →
    DWp D wt d₀ (u ++ [x]) d' =
      sumL (List.range N) fun d => DWp D wt d₀ u d *
        sumL (D.transAt d) fun p => if p.2 = d' then wt p.1 x else 0
  | [], d₀, d', h₀ => by
    simp only [List.nil_append, DWp]
    have : (sumL (List.range N) fun d => (if d₀ = d then (1 : S) else 0) *
        sumL (D.transAt d) fun p => if p.2 = d' then wt p.1 x else 0) =
        sumL (List.range N) fun d => if d = d₀ then
          (sumL (D.transAt d₀) fun p => if p.2 = d' then wt p.1 x else 0) else 0 := by
      apply sumL_congr; intro d _
      by_cases h : d = d₀
      · subst h; simp
      · simp [h, Ne.symm h]
    rw [this, sumL_range_ite, if_pos h₀]
    apply sumL_congr; intro p _
    by_cases hp : p.2 = d'
    · simp [hp]
    · simp [hp]
  | y :: u, d₀, d', h₀ => by
    simp only [List.cons_append, DWp]
    have ih : ∀ p ∈ D.transAt d₀, DWp D wt p.2 (u ++ [x]) d' =
        sumL (List.range N) fun d => DWp D wt p.2 u d *
          sumL (D.transAt d) fun q => if q.2 = d' then wt q.1 x else 0 :=
      fun p hp => DWp_snoc x u p.2 d' (hT d₀ h₀ p hp)
    rw [sumL_congr _ fun p hp => by rw [ih p hp, mul_sumL]]
    rw [sumL_comm (D.transAt d₀) (List.range N)]
    apply sumL_congr; intro d _
    rw [sumL_mul]
    apply sumL_congr; intro p _
    rw [S.mul_assoc]

include hT in
theorem DWp_acc : ∀ (u : List Item) (d₀ : Nat), d₀ < N →
    sumL (List.range N) (fun d => DWp D wt d₀ u d * D.accAt d) ≤ DW D wt d₀ u
  | [], d₀, h₀ => by
    simp only [DWp, DW]
    have : (sumL (List.range N) fun d => (if d₀ = d then (1 : S) else 0) * D.accAt d) =
        sumL (List.range N) fun d => if d = d₀ then D.accAt d₀ else 0 := by
      apply sumL_congr; intro d _
      by_cases h : d = d₀
      · subst h; simp
      · simp [h, Ne.symm h]
    rw [this, sumL_range_ite, if_pos h₀]; exact S.le_refl _
  | x :: u, d₀, h₀ => by
    simp only [DWp, DW, sumL_mul]
    rw [sumL_comm]
    apply sumL_le_sumL; intro p hp
    simp only [S.mul_assoc]
    rw [← mul_sumL]
    exact S.mul_le_mul (S.le_refl _) (DWp_acc u p.2 (hT d₀ h₀ p hp))

end


/-! ## The determinization invariant -/

theorem getV_filtH (M : Model) (finals : List Nat) (V : Vec) (f q : Nat) (hq : keptH M finals q = true) :
    getV (filtH M finals V) f q = getV V f q := by
  induction V with
  | nil => rfl
  | cons e V ih =>
    unfold filtH at *
    rw [List.filter_cons, getV_cons]
    by_cases hk : keptH M finals e.2.1 = true
    · simp only [hk, ite_true, getV_cons, ih]
    · simp only [hk]
      have : ¬ (e.1 = f ∧ e.2.1 = q) := fun ⟨_, h2⟩ => hk (h2 ▸ hq)
      simp [this, ih]

def Edge.target : Edge → Nat
  | .eps t _ => t
  | .int _ t => t
  | .call _ _ t _ => t

/-- What a reading edge `e` contributes for item `x` into `q`. -/
noncomputable def ewt (M : Model) (fI : Array (Option Nat)) (x : Item) (q : Nat) (e : Edge) : S :=
  match atomOfEdge fI e with
  | some α => if e.target = q then wtM M fI α x else 0
  | none => 0

section
variable (M : Model) (fI : Array (Option Nat)) (hnd : fI.toList.Nodup)
  (hcall : ∀ p, ∀ e ∈ M.out p, ∀ o f t c, e = .call o f t c → f < fI.size)

include hnd hcall in
theorem nonEps_snoc_le (n s : Nat) (u : List Item) (x : Item) (q p : Nat) (e : Edge) (he : e ∈ M.out p) :
    nonEps M (W M n) s (u ++ [x]) q p e ≤ ewt M fI x q e * Wsup M s u p := by
  cases e with
  | eps t w => simp [nonEps, Edge.isEps]
  | int a t =>
    simp only [nonEps, Edge.isEps, Bool.false_eq_true, ite_false, stepC, List.getLast?_concat,
      List.dropLast_concat, ewt, atomOfEdge, Edge.target]
    split
    · cases x with
      | tok b => simp only [wtM]; split <;> simp [W_le_Wsup]
      | grp _ _ _ => simp
    · simp
  | call o f t c =>
    simp only [nonEps, Edge.isEps, Bool.false_eq_true, ite_false, stepC, List.getLast?_concat,
      List.dropLast_concat, ewt, atomOfEdge, Edge.target]
    split
    · cases x with
      | tok _ => simp
      | grp o' v c' =>
        simp only [wtM]
        split
        · have hf := hcall p _ he o f t c rfl
          have hfi : fI[f]? = some (fI.getD f none) := by simp [Array.getD, hf]
          rw [fragW_eq M fI hnd hfi v, S.mul_comm (Wsup M _ v _)]
          exact S.mul_le_mul (W_le_Wsup M n _ _ _) (W_le_Wsup M n _ _ _)
        · simp
    · simp

theorem ewt_le_atoms {V : Vec} {p : Nat} {w : S} {g : Nat} (hp : (g, p, w) ∈ V) (x : Item) (q : Nat) :
    sumL (M.out p) (ewt M fI x q) ≤
      sumL (atomsOf M fI V) fun a => wtM M fI a x * hsum M (atomH fI a) p q := by
  unfold hsum
  simp only [mul_sumL]
  rw [sumL_comm]
  apply sumL_le_sumL; intro e he
  unfold ewt
  cases hα : atomOfEdge fI e with
  | none => exact S.zero_le _
  | some α =>
    have hmem : α ∈ atomsOf M fI V := by
      unfold atomsOf
      rw [mem_dedupL]
      exact List.mem_flatMap.mpr ⟨_, hp, List.mem_filterMap.mpr ⟨e, he, hα⟩⟩
    have hval : ∀ a, wtM M fI a x * hval (atomH fI a) q e =
        if a = α then (if e.target = q then wtM M fI α x else 0) else 0 := by
      intro a
      cases e with
      | eps _ _ => simp [atomOfEdge] at hα
      | int b t =>
        simp only [atomOfEdge, Option.some.injEq] at hα; subst hα
        by_cases ha : a = .t b
        · subst ha; by_cases ht : t = q <;> simp [hval, atomH, Edge.target, ht]
        · simp only [hval, atomH, Edge.target]
          rw [if_neg (Ne.symm ha), if_neg ha]; simp
      | call o f t c =>
        simp only [atomOfEdge, Option.some.injEq] at hα; subst hα
        by_cases ha : a = .call o (fI.getD f none) c
        · subst ha; by_cases ht : t = q <;> simp [hval, atomH, Edge.target, ht]
        · simp only [hval, atomH, Edge.target]
          rw [if_neg (Ne.symm ha), if_neg ha]; simp
    rw [sumL_congr _ fun a _ => hval a]
    rw [show atomsOf M fI V = dedupL _ from rfl, sumL_single (nodup_dedupL _) hmem]
    exact S.le_refl _

end


section
variable (M : Model) (fI : Array (Option Nat)) (finals : List Nat) (N : Nat) (st : Nat → Vec) (D : DFA)

theorem lookup_mem' {α β} [BEq α] [LawfulBEq α] : ∀ {l : List (α × β)} {a : α} {b : β},
    l.lookup a = some b → (a, b) ∈ l
  | [], _, _, h => by simp at h
  | (k, v) :: l, a, b, h => by
    simp only [List.lookup] at h
    split at h
    · rename_i hk; simp at hk h; subst hk; subst h; simp
    · exact List.mem_cons_of_mem _ (lookup_mem' h)

def nxt (d : Nat) (a : Atom) : Nat := ((D.transAt d).lookup a).getD 0

theorem start_vec (s s₀ : Nat) (hpost : isPost M [(0, s, 1)] (closure M [(0, s, 1)]) = true)
    (hfilt : filtH M finals (closure M [(0, s, 1)]) = st s₀) (q : Nat) (hq : keptH M finals q = true) :
    Wsup M s [] q ≤ getV (st s₀) 0 q := by
  rw [← hfilt, getV_filtH M finals _ 0 q hq]
  obtain ⟨n, hn⟩ := Wsup_attained M s [] q
  rw [← hn n (Nat.le_refl _)]
  refine post_bound M [(0, s, 1)] _ hpost 0 (fun n q => W M n s [] q) ?_ ?_ n q
  · intro q
    by_cases h : s = q
    · subst h; simp [W_zero, base, getV]
    · simp [W_zero, base, h]
  · intro n q
    rw [W_succ_split]
    have hz : sumL (List.range M.size) (fun p => sumL (M.out p) (nonEps M (W M n) s [] q p)) = 0 := by
      apply sumL_zero; intro p _; apply sumL_zero; intro e _
      cases e <;> simp [nonEps, stepC, Edge.isEps]
    rw [hz, S.add_zero]
    refine S.add_le_add ?_ (S.le_refl _)
    by_cases h : s = q
    · subst h; simp [base, getV]
    · simp [base, h]


variable (hnd : fI.toList.Nodup)
  (hcall : ∀ p, ∀ e ∈ M.out p, ∀ o f t c, e = .call o f t c → f < fI.size)
  (hT : ∀ d < N, ∀ p ∈ D.transAt d, p.2 < N)
  (hND : ∀ d < N, ((D.transAt d).map (·.1)).Nodup)
  (hS : ∀ d < N, ∀ a ∈ atomsOf M fI (st d), ∃ d', (D.transAt d).lookup a = some d' ∧
    isPost M (edgeCounts M (st d) (atomH fI a)) (closure M (edgeCounts M (st d) (atomH fI a))) = true ∧
    filtH M finals (closure M (edgeCounts M (st d) (atomH fI a))) = st d')

theorem rhs_swap {α β} (A : List α) (B : List β) (c : S) (w : α → S) (g : α → β → S) :
    sumL A (fun a => c * (w a * sumL B (g a))) = sumL B (fun b => sumL A (fun a => (c * w a) * g a b)) := by
  rw [← sumL_comm]
  apply sumL_congr; intro a _
  rw [← S.mul_assoc, mul_sumL]

def stepIdx : List (Nat × Atom) := (List.range N).flatMap fun d => (atomsOf M fI (st d)).map fun a => (d, a)

theorem sumL_stepIdx (g : Nat × Atom → S) :
    sumL (stepIdx M fI N st) g = sumL (List.range N) fun d => sumL (atomsOf M fI (st d)) fun a => g (d, a) := by
  unfold stepIdx; rw [sumL_flatMap]; apply sumL_congr; intro d _; rw [sumL_map]

include hnd hcall in
theorem nonEps_part_le (s s₀ : Nat) (u : List Item) (x : Item)
    (IH : ∀ p, keptH M finals p = true → Wsup M s u p ≤
      sumL (List.range N) fun d => DWp D (wtM M fI) s₀ u d * getV (st d) 0 p) (n q : Nat) :
    sumL (List.range M.size) (fun p => sumL (M.out p) (nonEps M (W M n) s (u ++ [x]) q p)) ≤
      sumL (List.range N) fun d => sumL (atomsOf M fI (st d)) fun a =>
        (DWp D (wtM M fI) s₀ u d * wtM M fI a x) * getV (edgeCounts M (st d) (atomH fI a)) 0 q := by
  -- each last edge reads `x` from a node the vectors bound
  have h1 : sumL (List.range M.size) (fun p => sumL (M.out p) (nonEps M (W M n) s (u ++ [x]) q p)) ≤
      sumL (List.range M.size) fun p =>
        (sumL (List.range N) fun d => DWp D (wtM M fI) s₀ u d * getV (st d) 0 p) *
          sumL (M.out p) (ewt M fI x q) := by
    apply sumL_le_sumL; intro p _
    refine S.le_trans (sumL_le_sumL _ fun e he => nonEps_snoc_le M fI hnd hcall n s u x q p e he) ?_
    rw [← sumL_mul, S.mul_comm]
    by_cases hk : keptH M finals p = true
    · exact S.mul_le_mul (IH p hk) (S.le_refl _)
    · have : sumL (M.out p) (ewt M fI x q) = 0 := by
        apply sumL_zero; intro e he
        cases e with
        | eps _ _ => rfl
        | int a t =>
          exfalso; apply hk; unfold keptH
          simp only [Bool.or_eq_true, List.any_eq_true]
          exact Or.inr ⟨_, he, rfl⟩
        | call o f t c =>
          exfalso; apply hk; unfold keptH
          simp only [Bool.or_eq_true, List.any_eq_true]
          exact Or.inr ⟨_, he, rfl⟩
      rw [this]; simp
  refine S.le_trans h1 ?_
  simp only [sumL_mul]
  rw [sumL_comm (List.range M.size) (List.range N)]
  apply sumL_le_sumL; intro d _
  simp only [S.mul_assoc]
  rw [← mul_sumL]
  -- the sum over model nodes is a sum over the vector's entries
  rw [sumL_range_getV M (st d) 0 (fun p => sumL (M.out p) (ewt M fI x q))
    (fun p hp => by rw [out_of_size M p hp]; rfl)]
  rw [mul_sumL]
  simp only [getV_edgeCounts]
  rw [rhs_swap]
  apply sumL_le_sumL; intro e he
  by_cases h0 : e.1 = 0
  · simp only [h0, ite_true]
    have := ewt_le_atoms M fI (V := st d) (p := e.2.1) (w := e.2.2) (g := e.1) (by simpa using he) x q
    refine S.le_trans (S.mul_le_mul (S.le_refl _) (S.mul_le_mul (S.le_refl _) this)) ?_
    rw [mul_sumL, mul_sumL]
    apply sumL_le_sumL; intro a _
    have e4 : ∀ a b c d : S, a * (b * (c * d)) = a * c * (b * d) := by
      intro a b c d; cases a <;> cases b <;> cases c <;> cases d <;> rfl
    rw [e4]; exact S.le_refl _
  · simp [h0]

include hnd hcall hT hND hS in
theorem step_vec (s s₀ : Nat) (hs₀ : s₀ < N) (u : List Item) (x : Item)
    (IH : ∀ p, keptH M finals p = true → Wsup M s u p ≤
      sumL (List.range N) fun d => DWp D (wtM M fI) s₀ u d * getV (st d) 0 p)
    (q : Nat) (hq : keptH M finals q = true) :
    Wsup M s (u ++ [x]) q ≤ sumL (List.range N) fun d => DWp D (wtM M fI) s₀ (u ++ [x]) d * getV (st d) 0 q := by
  let I := stepIdx M fI N st
  let κ : Nat × Atom → S := fun i => DWp D (wtM M fI) s₀ u i.1 * wtM M fI i.2 x
  let c : Nat × Atom → Vec := fun i => edgeCounts M (st i.1) (atomH fI i.2)
  let R : Nat × Atom → Vec := fun i => closure M (c i)
  have hmemI : ∀ i ∈ I, i.1 < N ∧ i.2 ∈ atomsOf M fI (st i.1) := by
    intro i hi
    obtain ⟨d, hd, hi⟩ := List.mem_flatMap.mp hi
    obtain ⟨a, ha, rfl⟩ := List.mem_map.mp hi
    exact ⟨List.mem_range.mp hd, ha⟩
  have hp : ∀ i ∈ I, isPost M (c i) (R i) = true := by
    intro i hi
    obtain ⟨h1, h2⟩ := hmemI i hi
    obtain ⟨d', _, hpost, _⟩ := hS i.1 h1 i.2 h2
    exact hpost
  have hbound := post_bound_fun M (fun q => sumL I fun i => κ i * getV (c i) 0 q)
    (fun q => sumL I fun i => κ i * getV (R i) 0 q) (fun n q => W M n s (u ++ [x]) q)
    (post_comb M I κ c R hp)
    (by intro q; simp [W_zero, base])
    (by
      intro n q
      rw [W_succ_split]
      have hb : base s (u ++ [x]) q = 0 := by simp [base]
      rw [hb, S.zero_add, S.add_comm]
      refine S.add_le_add ?_ (S.le_refl _)
      refine S.le_trans (nonEps_part_le M fI finals N st D hnd hcall s s₀ u x IH n q) ?_
      show _ ≤ sumL I fun i => κ i * getV (c i) 0 q
      rw [sumL_stepIdx M fI N st (fun i => κ i * getV (c i) 0 q)]
      exact S.le_refl _)
  obtain ⟨n, hn⟩ := Wsup_attained M s (u ++ [x]) q
  rw [← hn n (Nat.le_refl _)]
  refine S.le_trans (hbound n q) ?_
  show sumL I (fun i => κ i * getV (R i) 0 q) ≤ _
  rw [sumL_stepIdx M fI N st (fun i => κ i * getV (R i) 0 q)]
  -- successors are recorded states
  have hR : ∀ d, d < N → ∀ a ∈ atomsOf M fI (st d),
      getV (R (d, a)) 0 q = getV (st (nxt D d a)) 0 q := by
    intro d hd a ha
    obtain ⟨d', hl, _, hf⟩ := hS d hd a ha
    have : nxt D d a = d' := by simp [nxt, hl]
    rw [this, ← hf, getV_filtH M finals _ 0 q hq]
  -- the right-hand side, regrouped by source state
  have hrhs : (sumL (List.range N) fun d' => DWp D (wtM M fI) s₀ (u ++ [x]) d' * getV (st d') 0 q) =
      sumL (List.range N) fun d => DWp D (wtM M fI) s₀ u d *
        sumL (D.transAt d) fun p => wtM M fI p.1 x * getV (st p.2) 0 q := by
    rw [sumL_congr _ fun d' _ => by rw [DWp_snoc D (wtM M fI) N hT x u s₀ d' hs₀, sumL_mul]]
    rw [sumL_comm]
    apply sumL_congr; intro d hd
    simp only [S.mul_assoc]
    rw [← mul_sumL]
    congr 1
    simp only [sumL_mul]
    rw [sumL_comm]
    apply sumL_congr; intro p hp
    have : (sumL (List.range N) fun d' => (if p.2 = d' then wtM M fI p.1 x else 0) * getV (st d') 0 q) =
        sumL (List.range N) fun d' => if d' = p.2 then wtM M fI p.1 x * getV (st p.2) 0 q else 0 := by
      apply sumL_congr; intro d' _
      by_cases h : d' = p.2
      · subst h; simp
      · simp [h, Ne.symm h]
    rw [this, sumL_range_ite, if_pos (hT d (List.mem_range.mp hd) p hp)]
  rw [hrhs]
  apply sumL_le_sumL; intro d hd
  have hdN := List.mem_range.mp hd
  have e : (sumL (atomsOf M fI (st d)) fun a => κ (d, a) * getV (R (d, a)) 0 q) =
      DWp D (wtM M fI) s₀ u d * sumL (atomsOf M fI (st d)) fun a => wtM M fI a x * getV (st (nxt D d a)) 0 q := by
    rw [mul_sumL]; apply sumL_congr; intro a ha; rw [hR d hdN a ha]; simp only [κ, S.mul_assoc]
  show (sumL (atomsOf M fI (st d)) fun a => κ (d, a) * getV (R (d, a)) 0 q) ≤ _
  rw [e]
  refine S.mul_le_mul (S.le_refl _) ?_
  have hsub := sumL_nodup_sub (l₁ := (atomsOf M fI (st d)).map fun a => (a, nxt D d a))
    (l₂ := D.transAt d) ?_ ?_ (fun p => wtM M fI p.1 x * getV (st p.2) 0 q)
  · rw [sumL_map] at hsub; exact hsub
  · exact List.Pairwise.map _ (fun a b hab e => hab (Prod.mk.inj e).1) (nodup_dedupL _)
  · intro p hp
    obtain ⟨a, ha, rfl⟩ := List.mem_map.mp hp
    obtain ⟨d', hl, _, _⟩ := hS d hdN a ha
    have : nxt D d a = d' := by simp [nxt, hl]
    rw [this]
    exact lookup_mem' hl

include hnd hcall hT hND hS in
/-- **(b)** The NFA's path counts from a member's start are bounded by the
DFA-weighted state vectors. -/
theorem det_inv (s s₀ : Nat) (hs₀ : s₀ < N)
    (hpost : isPost M [(0, s, 1)] (closure M [(0, s, 1)]) = true)
    (hfilt : filtH M finals (closure M [(0, s, 1)]) = st s₀) (u : List Item) :
    ∀ q, keptH M finals q = true → Wsup M s u q ≤
      sumL (List.range N) fun d => DWp D (wtM M fI) s₀ u d * getV (st d) 0 q := by
  suffices H : ∀ k (u : List Item), u.length ≤ k → ∀ q, keptH M finals q = true → Wsup M s u q ≤
      sumL (List.range N) fun d => DWp D (wtM M fI) s₀ u d * getV (st d) 0 q from H _ u (Nat.le_refl _)
  intro k
  induction k with
  | zero =>
    intro u hu q hq
    have : u = [] := List.eq_nil_of_length_eq_zero (by omega)
    subst this
    refine S.le_trans (start_vec M finals st s s₀ hpost hfilt q hq) ?_
    have : (sumL (List.range N) fun d => DWp D (wtM M fI) s₀ [] d * getV (st d) 0 q) =
        sumL (List.range N) fun d => if d = s₀ then getV (st s₀) 0 q else 0 := by
      apply sumL_congr; intro d _
      by_cases h : d = s₀
      · subst h; simp [DWp]
      · simp [DWp, h, Ne.symm h]
    rw [this, sumL_range_ite, if_pos hs₀]; exact S.le_refl _
  | succ k ih =>
    intro u hu
    rcases List.eq_nil_or_concat u with h | ⟨u', x, rfl⟩
    · subst h; exact ih [] (by simp)
    · rw [List.concat_eq_append]
      exact step_vec M fI finals N st D hnd hcall hT hND hS s s₀ hs₀ u' x
        (ih u' (by simp at hu; omega))

end

end Ambiguity

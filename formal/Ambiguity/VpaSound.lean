import Ambiguity.Vpa

/-!
# Soundness of the visibly pushdown certificate checker

`check_sound`: if `check` accepts a model and certificate, no word has two
accepting paths in the model's root fragment (`RootUnambiguous`).
-/

namespace Ambiguity

/-! ## Sums over lists -/

theorem sumL_flatMap {α β} (l : List α) (g : α → List β) (f : β → S) :
    sumL (l.flatMap g) f = sumL l (fun a => sumL (g a) f) := by
  induction l with
  | nil => rfl
  | cons a l ih => simp [List.flatMap_cons, sumL_append, ih]

theorem sumL_filterMap {α β} (l : List α) (g : α → Option β) (f : β → S) :
    sumL (l.filterMap g) f = sumL l (fun a => match g a with | some b => f b | none => 0) := by
  induction l with
  | nil => rfl
  | cons a l ih =>
    rw [List.filterMap_cons]
    cases h : g a <;> simp [ih, h]

theorem sumL_range_ite (n p0 : Nat) (x : S) :
    sumL (List.range n) (fun p => if p = p0 then x else 0) = if p0 < n then x else 0 := by
  induction n with
  | zero => simp
  | succ n ih =>
    rw [List.range_succ, sumL_append, ih]
    by_cases h : p0 = n
    · subst h; simp
    · have : ¬ n = p0 := fun e => h e.symm
      by_cases hl : p0 < n
      · simp [hl, this, show p0 < n + 1 by omega]
      · simp [hl, this, show ¬ p0 < n + 1 by omega]

/-! ## Vectors -/

theorem getV_nil (f q : Nat) : getV [] f q = 0 := rfl

theorem getV_cons (e : Nat × Nat × S) (V : Vec) (f q : Nat) :
    getV (e :: V) f q = (if e.1 = f ∧ e.2.1 = q then e.2.2 else 0) + getV V f q := rfl

theorem getV_filt (M : Model) (V : Vec) (f q : Nat) (hq : M.kept q = true) :
    getV (filt M V) f q = getV V f q := by
  induction V with
  | nil => rfl
  | cons e V ih =>
    unfold filt at *
    rw [List.filter_cons, getV_cons]
    by_cases hk : M.kept e.2.1 = true
    · simp only [hk, ite_true, getV_cons, ih]
    · simp only [hk]
      have : ¬ (e.1 = f ∧ e.2.1 = q) := fun ⟨_, h2⟩ => hk (h2 ▸ hq)
      simp [this, ih]

theorem getV_ne_zero {V : Vec} {f q : Nat} (h : getV V f q ≠ 0) : ∃ w, (f, q, w) ∈ V := by
  induction V with
  | nil => exact absurd rfl h
  | cons e V ih =>
    rw [getV_cons] at h
    by_cases he : e.1 = f ∧ e.2.1 = q
    · obtain ⟨e1, e2, w⟩ := e
      simp at he; obtain ⟨rfl, rfl⟩ := he
      exact ⟨w, by simp⟩
    · simp only [he, ite_false, S.zero_add] at h
      obtain ⟨w, hw⟩ := ih h
      exact ⟨w, List.mem_cons_of_mem _ hw⟩

/-- Summing a vector against a function of its node, over all model nodes,
equals summing it over its entries. -/
theorem sumL_range_getV (M : Model) (V : Vec) (f : Nat) (g : Nat → S)
    (hg : ∀ p, M.size ≤ p → g p = 0) :
    sumL (List.range M.size) (fun p => getV V f p * g p) =
      sumL V (fun e => if e.1 = f then e.2.2 * g e.2.1 else 0) := by
  unfold getV
  simp only [sumL_mul]
  rw [sumL_comm]
  apply sumL_congr
  intro e _
  have : ∀ p, (if e.1 = f ∧ e.2.1 = p then e.2.2 else 0) * g p =
      if p = e.2.1 then (if e.1 = f then e.2.2 * g e.2.1 else 0) else 0 := by
    intro p
    by_cases h1 : p = e.2.1
    · subst h1; by_cases h2 : e.1 = f <;> simp [h2]
    · have : ¬ e.2.1 = p := fun x => h1 x.symm
      simp [h1, this]
  simp only [this, sumL_range_ite]
  by_cases hl : e.2.1 < M.size
  · simp [hl]
  · simp only [hl, ite_false]
    by_cases h2 : e.1 = f
    · simp only [h2, ite_true, hg e.2.1 (by omega), S.mul_zero]
    · simp [h2]

/-! ## Model facts -/

theorem out_of_size (M : Model) (p : Nat) (h : M.size ≤ p) : M.out p = [] := by
  unfold Model.out Model.size at *
  simp [Array.getD, h, Nat.not_lt.mpr h]

theorem epsW_of_size (M : Model) (p t : Nat) (h : M.size ≤ p) : epsW M p t = 0 := by
  unfold epsW; rw [out_of_size M p h]; rfl

theorem kept_of_nonEps (M : Model) {p : Nat} {e : Edge} (he : e ∈ M.out p)
    (hn : e.isEps = false) : M.kept p = true := by
  unfold Model.kept
  simp only [Bool.or_eq_true, List.any_eq_true]
  exact Or.inr ⟨e, he, by simp [hn]⟩

theorem kept_fin (M : Model) (f : Nat) (hf : f < M.frags.size) : M.kept (M.fin f) = true := by
  unfold Model.kept Model.isEnd Model.fin
  simp only [Bool.or_eq_true, List.any_eq_true, beq_iff_eq]
  left
  refine ⟨M.frags[f], ?_, ?_⟩
  · simp
  · simp [Array.getD, hf]

/-! ## The post-fixpoint bound -/

theorem epsIn_eq (M : Model) (R : Vec) (f t : Nat) :
    epsIn M R f t = sumL (List.range M.size) (fun p => getV R f p * epsW M p t) := by
  rw [sumL_range_getV M R f (fun p => epsW M p t) (fun p h => epsW_of_size M p t h)]
  rfl

theorem notKey_zero (M : Model) (c R : Vec) (f t : Nat) (hk : (f, t) ∉ postKeys M c R) :
    getV c f t = 0 ∧ epsIn M R f t = 0 := by
  constructor
  · apply sumL_zero
    intro e he
    by_cases h : e.1 = f ∧ e.2.1 = t
    · exfalso; apply hk; unfold postKeys
      apply List.mem_append_left
      exact List.mem_map.mpr ⟨e, he, by rw [h.1, h.2]⟩
    · simp [h]
  · apply sumL_zero
    intro e he
    by_cases h1 : e.1 = f
    · simp only [h1, ite_true]
      have : epsW M e.2.1 t = 0 := by
        unfold epsW
        apply sumL_zero
        intro ed hed
        cases ed with
        | eps t' w =>
          by_cases h2 : t' = t
          · exfalso; apply hk; unfold postKeys
            apply List.mem_append_right
            exact List.mem_flatMap.mpr ⟨e, he, List.mem_filterMap.mpr ⟨_, hed, by simp [h1, h2]⟩⟩
          · simp [h2]
        | _ => rfl
      rw [this, S.mul_zero]
    · simp [h1]

/-- Any family bounded by the closure recurrence from `c` is bounded by a
post-fixpoint `R` of that recurrence. -/
theorem post_bound (M : Model) (c R : Vec) (hp : isPost M c R = true) (f : Nat)
    (X : Nat → Nat → S)
    (h0 : ∀ q, X 0 q ≤ getV c f q)
    (hs : ∀ n q, X (n + 1) q ≤ getV c f q + sumL (List.range M.size) (fun p => X n p * epsW M p q)) :
    ∀ n q, X n q ≤ getV R f q := by
  have key : ∀ q, getV c f q + epsIn M R f q ≤ getV R f q := by
    intro q
    by_cases hk : (f, q) ∈ postKeys M c R
    · unfold isPost at hp
      have := List.all_eq_true.mp hp _ hk
      simpa using this
    · obtain ⟨h1, h2⟩ := notKey_zero M c R f q hk
      rw [h1, h2]; exact S.zero_le _
  intro n
  induction n with
  | zero => intro q; exact S.le_trans (h0 q) (S.le_trans (S.le_add_right _ _) (key q))
  | succ n ih =>
    intro q
    refine S.le_trans (hs n q) (S.le_trans ?_ (key q))
    apply S.add_le_add (S.le_refl _)
    rw [epsIn_eq]
    exact sumL_le_sumL _ fun p _ => S.mul_le_mul (ih p) (S.le_refl _)


/-! ## Splitting a path at its last edge -/

theorem W_zero (M : Model) (q : Nat) (v : List Item) (r : Nat) : W M 0 q v r = base q v r := rfl

theorem W_succ (M : Model) (n q : Nat) (v : List Item) (r : Nat) :
    W M (n + 1) q v r = base q v r +
      sumL (List.range M.size) (fun p => sumL (M.out p) (stepC M (W M n) q v r p)) := rfl

def nonEps (M : Model) (Wn : Nat → List Item → Nat → S) (q : Nat) (v : List Item)
    (r p : Nat) (e : Edge) : S :=
  if e.isEps then 0 else stepC M Wn q v r p e

def epsWL (l : List Edge) (t : Nat) : S :=
  sumL l fun
    | .eps t' w => if t' = t then w else 0
    | _ => 0

theorem epsW_eq (M : Model) (p t : Nat) : epsW M p t = epsWL (M.out p) t := rfl

theorem sumL_stepC (M : Model) (Wn : Nat → List Item → Nat → S) (q : Nat) (v : List Item)
    (r p : Nat) (l : List Edge) :
    sumL l (stepC M Wn q v r p) = Wn q v p * epsWL l r + sumL l (nonEps M Wn q v r p) := by
  induction l with
  | nil => simp [epsWL]
  | cons e l ih =>
    simp only [sumL_cons, epsWL] at *
    rw [ih, S.mul_add]
    cases e with
    | eps t w =>
      simp only [stepC, nonEps, Edge.isEps, ite_true, S.zero_add]
      by_cases h : t = r
      · simp only [h, ite_true]; ac_rfl
      · simp only [h, ite_false, S.mul_zero, S.zero_add]
    | int a t =>
      simp only [nonEps, Edge.isEps, Bool.false_eq_true, ite_false, S.mul_zero, S.zero_add]
      ac_rfl
    | call o f t c =>
      simp only [nonEps, Edge.isEps, Bool.false_eq_true, ite_false, S.mul_zero, S.zero_add]
      ac_rfl

/-- `W (n+1)` is the base term, plus epsilon steps from `W n`, plus the
non-epsilon last edges. -/
theorem W_succ_split (M : Model) (n q : Nat) (v : List Item) (r : Nat) :
    W M (n + 1) q v r = base q v r +
      (sumL (List.range M.size) (fun p => W M n q v p * epsW M p r) +
       sumL (List.range M.size) (fun p => sumL (M.out p) (nonEps M (W M n) q v r p))) := by
  rw [W_succ]
  congr 1
  rw [← sumL_add]
  apply sumL_congr
  intro p _
  rw [sumL_stepC, epsW_eq]

/-! ## Successor vectors along selected edges -/

def hval (h : Edge → Option (Nat × S)) (r : Nat) (e : Edge) : S :=
  match h e with
  | some tm => if tm.1 = r then tm.2 else 0
  | none => 0

def hsum (M : Model) (h : Edge → Option (Nat × S)) (p r : Nat) : S :=
  sumL (M.out p) (hval h r)

theorem getV_edgeCounts (M : Model) (N : Vec) (h : Edge → Option (Nat × S)) (f r : Nat) :
    getV (edgeCounts M N h) f r =
      sumL N (fun e => if e.1 = f then e.2.2 * hsum M h e.2.1 r else 0) := by
  unfold getV edgeCounts
  rw [sumL_flatMap]
  apply sumL_congr
  intro e _
  rw [sumL_filterMap]
  by_cases hf : e.1 = f
  · simp only [hf, ite_true, hsum, mul_sumL]
    apply sumL_congr
    intro ed _
    unfold hval
    cases h ed with
    | none => simp
    | some tm =>
      by_cases hr : tm.1 = r
      · simp [hf, hr]
      · simp [hr]
  · simp only [hf, ite_false]
    apply sumL_zero
    intro ed _
    cases h ed with
    | none => rfl
    | some tm => simp [hf]

theorem hsum_of_size (M : Model) (h : Edge → Option (Nat × S)) (p r : Nat) (hp : M.size ≤ p) :
    hsum M h p r = 0 := by
  unfold hsum; rw [out_of_size M p hp]; rfl

/-- The non-epsilon last edges are bounded by the successor vector of `N`
along `h`, when each edge is. -/
theorem nonEps_bound (M : Model) (N : Vec) (h : Edge → Option (Nat × S)) (f r : Nat)
    (Wn : Nat → List Item → Nat → S) (q : Nat) (v : List Item)
    (hyp : ∀ p e, e ∈ M.out p → nonEps M Wn q v r p e ≤ getV N f p * hval h r e) :
    sumL (List.range M.size) (fun p => sumL (M.out p) (nonEps M Wn q v r p)) ≤
      getV (edgeCounts M N h) f r := by
  rw [getV_edgeCounts, ← sumL_range_getV M N f (fun p => hsum M h p r)
    (fun p hp => hsum_of_size M h p r hp)]
  apply sumL_le_sumL
  intro p _
  unfold hsum
  rw [mul_sumL]
  exact sumL_le_sumL _ fun e he => hyp p e he


/-! ## One step of a frame -/

theorem isPost_nil (M : Model) : isPost M [] [] = true := rfl

theorem mem_of_hashSet {l : List Vec} {x : Vec} (h : (Std.HashSet.ofList l).contains x = true) :
    x ∈ l := by
  rw [Std.HashSet.contains_ofList] at h
  exact List.contains_iff_mem.mp h

/-- A family satisfying the closure recurrence from `c` is bounded by a node
of the frame, when the frame's successor check accepts `c`. -/
theorem frame_succ (M : Model) (K : Frame) (c : Vec)
    (hsucc : succOk M (Std.HashSet.ofList K.nodes) c = true) (hne : K.nodes ≠ [])
    (X : Nat → Nat → Nat → S)
    (h0 : ∀ f ∈ K.fs, ∀ q, X f 0 q ≤ getV c f q)
    (hs : ∀ f ∈ K.fs, ∀ n q, X f (n + 1) q ≤
      getV c f q + sumL (List.range M.size) (fun p => X f n p * epsW M p q)) :
    ∃ N ∈ K.nodes, ∀ f ∈ K.fs, ∀ n q, M.kept q = true → X f n q ≤ getV N f q := by
  unfold succOk at hsucc
  by_cases hc : c = []
  · subst hc
    obtain ⟨N, hN⟩ := List.exists_mem_of_ne_nil _ hne
    refine ⟨N, hN, fun f hf n q _ => ?_⟩
    have := post_bound M [] [] (isPost_nil M) f (X f) (h0 f hf) (hs f hf) n q
    exact S.le_trans this (S.zero_le _)
  · have hc' : c.isEmpty = false := by cases c <;> simp_all
    simp only [hc', Bool.false_or, Bool.and_eq_true] at hsucc
    obtain ⟨hp, hm⟩ := hsucc
    refine ⟨filt M (closure M c), mem_of_hashSet hm, fun f hf n q hq => ?_⟩
    rw [getV_filt M _ f q hq]
    exact post_bound M c _ hp f (X f) (h0 f hf) (hs f hf) n q

/-- The selected-edge step: if every last non-epsilon edge is bounded through
`h` by the node `N` reached on `v`, the word `v ++ [x]` is bounded by a node. -/
theorem frame_step (M : Model) (K : Frame) (N : Vec) (h : Edge → Option (Nat × S))
    (v : List Item) (x : Item)
    (hsucc : succOk M (Std.HashSet.ofList K.nodes) (edgeCounts M N h) = true)
    (hne : K.nodes ≠ [])
    (hyp : ∀ f ∈ K.fs, ∀ n q p e, e ∈ M.out p →
      nonEps M (W M n) (M.entry f) (v ++ [x]) q p e ≤ getV N f p * hval h q e) :
    ∃ N' ∈ K.nodes, ∀ f ∈ K.fs, ∀ n q, M.kept q = true →
      W M n (M.entry f) (v ++ [x]) q ≤ getV N' f q := by
  apply frame_succ M K _ hsucc hne (fun f n q => W M n (M.entry f) (v ++ [x]) q)
  · intro f _ q
    simp [W_zero, base, S.zero_le]
  · intro f hf n q
    rw [W_succ_split]
    have he : base (M.entry f) (v ++ [x]) q = 0 := by simp [base]
    rw [he, S.zero_add, S.add_comm (getV _ _ _)]
    exact S.add_le_add (S.le_refl _) (nonEps_bound M N h f q _ _ _ (hyp f hf n q))

/-- The empty word: the frame's entry vector. -/
theorem frame_nil (M : Model) (K : Frame)
    (hsucc : succOk M (Std.HashSet.ofList K.nodes) (K.fs.map fun f => (f, M.entry f, 1)) = true)
    (hne : K.nodes ≠ []) :
    ∃ N ∈ K.nodes, ∀ f ∈ K.fs, ∀ n q, M.kept q = true → W M n (M.entry f) [] q ≤ getV N f q := by
  have hb : ∀ f ∈ K.fs, ∀ q, base (M.entry f) [] q ≤
      getV (K.fs.map fun f => (f, M.entry f, 1)) f q := by
    intro f hf q
    unfold base
    by_cases hq : M.entry f = q
    · subst hq
      simp only [List.isEmpty_nil, and_self, ite_true]
      unfold getV
      have hm : (f, M.entry f, (1 : S)) ∈ K.fs.map fun f => (f, M.entry f, 1) :=
        List.mem_map.mpr ⟨f, hf, rfl⟩
      have := le_sumL hm (fun e => if e.1 = f ∧ e.2.1 = M.entry f then e.2.2 else 0)
      simpa using this
    · simp [hq, S.zero_le]
  apply frame_succ M K _ hsucc hne (fun f n q => W M n (M.entry f) [] q)
  · intro f hf q; exact hb f hf q
  · intro f hf n q
    rw [W_succ_split]
    have hz : sumL (List.range M.size) (fun p => sumL (M.out p)
        (nonEps M (W M n) (M.entry f) [] q p)) = 0 := by
      apply sumL_zero; intro p _; apply sumL_zero; intro e _
      cases e <;> simp [nonEps, stepC, Edge.isEps]
    rw [hz, S.add_zero]
    exact S.add_le_add (hb f hf q) (S.le_refl _)


/-! ## Facts about the selectors -/

theorem nonEps_tok (M : Model) (Wn : Nat → List Item → Nat → S) (q : Nat) (v : List Item)
    (a : Tok) (r p : Nat) (e : Edge) :
    nonEps M Wn q (v ++ [.tok a]) r p e =
      match e with
      | .int b t => if t = r then (if b = a then Wn q v p else 0) else 0
      | _ => 0 := by
  cases e <;> simp [nonEps, stepC, Edge.isEps]

theorem nonEps_grp (M : Model) (Wn : Nat → List Item → Nat → S) (q : Nat) (v : List Item)
    (o : Tok) (inner : List Item) (c : Tok) (r p : Nat) (e : Edge) :
    nonEps M Wn q (v ++ [.grp o inner c]) r p e =
      match e with
      | .call o' cf t c' =>
        if t = r then (if o' = o ∧ c' = c then Wn q v p * Wn (M.entry cf) inner (M.fin cf) else 0)
        else 0
      | _ => 0 := by
  cases e <;> simp [nonEps, stepC, Edge.isEps]

theorem mem_tokensOf (M : Model) {N : Vec} {f p : Nat} {w : S} {b : Tok} {t : Nat}
    (hN : (f, p, w) ∈ N) (he : Edge.int b t ∈ M.out p) : b ∈ tokensOf M N :=
  List.mem_flatMap.mpr ⟨_, hN, List.mem_filterMap.mpr ⟨_, he, rfl⟩⟩

theorem mem_openersOf (M : Model) {N : Vec} {f p : Nat} {w : S} {o : Tok} {cf t : Nat} {c : Tok}
    (hN : (f, p, w) ∈ N) (he : Edge.call o cf t c ∈ M.out p) : o ∈ openersOf M N :=
  List.mem_flatMap.mpr ⟨_, hN, List.mem_filterMap.mpr ⟨_, he, rfl⟩⟩

theorem mem_childrenOf (M : Model) {N : Vec} {f p : Nat} {w : S} {o : Tok} {cf t : Nat} {c : Tok}
    (hN : (f, p, w) ∈ N) (he : Edge.call o cf t c ∈ M.out p) : cf ∈ childrenOf M N o :=
  List.mem_flatMap.mpr ⟨_, hN, List.mem_filterMap.mpr ⟨_, he, by simp⟩⟩

theorem strictSorted_nodup : ∀ {l : List Nat}, strictSorted l = true → ∀ x ∈ l, ∀ y ∈ l, x < y ∨ x = y ∨ y < x
  | _, _, x, _, y, _ => by omega

theorem strictSorted_head : ∀ {a : Nat} {l : List Nat}, strictSorted (a :: l) = true → ∀ y ∈ l, a < y
  | a, [], _, y, hy => by cases hy
  | a, b :: l, h, y, hy => by
    simp only [strictSorted, Bool.and_eq_true, decide_eq_true_eq] at h
    cases hy with
    | head => exact h.1
    | tail _ hy => exact Nat.lt_trans h.1 (strictSorted_head h.2 y hy)

theorem strictSorted_tail : ∀ {a : Nat} {l : List Nat}, strictSorted (a :: l) = true → strictSorted l = true
  | _, [], _ => rfl
  | _, _ :: _, h => by simp only [strictSorted, Bool.and_eq_true] at h; exact h.2

theorem exGet_cons (e : Nat × S) (ex : List (Nat × S)) (f : Nat) :
    exGet (e :: ex) f = (if e.1 = f then e.2 else 0) + exGet ex f := rfl

theorem exGet_accOf (M : Model) (N : Vec) : ∀ (fs : List Nat), strictSorted fs = true →
    ∀ f ∈ fs, exGet (accOf M fs N) f = getV N f (M.fin f)
  | [], _, f, hf => by cases hf
  | a :: fs, hs, f, hf => by
    have ih := exGet_accOf M N fs (strictSorted_tail hs)
    have hlt := strictSorted_head hs
    have hz : ∀ y, (∀ x ∈ fs, y < x) → exGet (accOf M fs N) y = 0 := by
      intro y hy
      unfold exGet accOf; rw [sumL_filterMap]; apply sumL_zero; intro x hx
      have : x ≠ y := Nat.ne_of_gt (hy x hx)
      by_cases h0 : getV N x (M.fin x) = 0 <;> simp [h0, this]
    have hcons : accOf M (a :: fs) N =
        if getV N a (M.fin a) = 0 then accOf M fs N
        else (a, getV N a (M.fin a)) :: accOf M fs N := by
      unfold accOf; rw [List.filterMap_cons]; by_cases h : getV N a (M.fin a) = 0 <;> simp [h]
    rw [hcons]
    cases hf with
    | head =>
      by_cases h0 : getV N a (M.fin a) = 0
      · simp only [h0, ite_true]; exact hz a hlt
      · simp only [h0, ite_false, exGet_cons, ite_true]; rw [hz a hlt, S.add_zero]
    | tail _ hf =>
      have hne : a ≠ f := Nat.ne_of_lt (hlt f hf)
      by_cases h0 : getV N a (M.fin a) = 0
      · simp only [h0, ite_true]; exact ih f hf
      · simp only [h0, ite_false, exGet_cons, hne, S.zero_add]; exact ih f hf

theorem accOf_nil_zero (M : Model) (N : Vec) (fs : List Nat) (h : accOf M fs N = []) :
    ∀ f ∈ fs, getV N f (M.fin f) = 0 := by
  intro f hf
  by_cases h0 : getV N f (M.fin f) = 0
  · exact h0
  · exfalso
    have : (f, getV N f (M.fin f)) ∈ accOf M fs N :=
      List.mem_filterMap.mpr ⟨f, hf, by simp [h0]⟩
    rw [h] at this; cases this

theorem itemsSz_concat (v : List Item) (x : Item) : itemsSz (v ++ [x]) = itemsSz v + x.sz := by
  induction v with
  | nil => simp [itemsSz]
  | cons y v ih => simp [itemsSz, ih]; omega

theorem Item.sz_pos (x : Item) : 1 ≤ x.sz := by
  cases x <;> simp [Item.sz] <;> omega

theorem W_le_zero_of (M : Model) {n q : Nat} {v : List Item} {p : Nat} {N : Vec} {f : Nat}
    (hb : W M n q v p ≤ getV N f p) (h0 : getV N f p = 0) : W M n q v p = 0 :=
  S.le_zero (h0 ▸ hb)

/-! ## The frame invariant -/

section Main
variable (br : Tok → Option Tok) (M : Model) (C : Cert)

theorem frame_inv (hc : check br M C = true) : ∀ k (v : List Item), itemsSz v ≤ k →
    ∀ K ∈ C.frames, ∃ N ∈ K.nodes, ∀ f ∈ K.fs, ∀ n q, M.kept q = true →
      W M n (M.entry f) v q ≤ getV N f q := by
  unfold check at hc
  simp only [Bool.and_eq_true] at hc
  obtain ⟨⟨hmodel, _⟩, hframes⟩ := hc
  have hmodel' := hmodel
  unfold checkModel at hmodel'
  simp only [Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq] at hmodel'
  obtain ⟨_, hedges⟩ := hmodel'
  have callOk : ∀ p o cf t c, Edge.call o cf t c ∈ M.out p → br o = some c ∧ cf < M.frags.size := by
    intro p o cf t c he
    have hp : p < M.size := by
      refine Classical.byContradiction fun hp => ?_
      rw [out_of_size M p (by omega)] at he; cases he
    have := hedges p (List.mem_range.mpr hp) _ he
    simpa using this
  intro k
  induction k with
  | zero =>
    intro v hv K hK
    have hv0 : v = [] := by
      cases v with
      | nil => rfl
      | cons x v => have := Item.sz_pos x; simp [itemsSz] at hv; omega
    subst hv0
    have hF := List.all_eq_true.mp hframes K hK
    unfold checkFrame at hF
    simp only [Bool.and_eq_true, Bool.not_eq_true', List.isEmpty_eq_false_iff] at hF
    exact frame_nil M K hF.1.2 hF.1.1.2
  | succ k ih =>
    intro v hv K hK
    have hF := List.all_eq_true.mp hframes K hK
    unfold checkFrame at hF
    simp only [Bool.and_eq_true, Bool.not_eq_true', List.isEmpty_eq_false_iff] at hF
    obtain ⟨⟨⟨_, hne⟩, hentry⟩, hnodes⟩ := hF
    rcases List.eq_nil_or_concat v with h | ⟨v', x, rfl⟩
    · subst h; exact frame_nil M K hentry hne
    · rw [List.concat_eq_append] at hv ⊢
      rw [itemsSz_concat] at hv
      have hx := Item.sz_pos x
      obtain ⟨N, hN, hbound⟩ := ih v' (by omega) K hK
      have hchk := List.all_eq_true.mp hnodes N hN
      unfold checkNode at hchk
      simp only [Bool.and_eq_true, List.all_eq_true] at hchk
      obtain ⟨⟨⟨⟨_, _⟩, _⟩, htoks⟩, hopens⟩ := hchk
      -- a term from `p` is zero unless `N` has an entry `(f, p, _)`
      have zeroCase : ∀ f ∈ K.fs, ∀ n p, M.kept p = true → getV N f p = 0 →
          W M n (M.entry f) v' p = 0 :=
        fun f hf n p hp h0 => W_le_zero_of M (hbound f hf n p hp) h0
      cases x with
      | tok a =>
        by_cases ha : a ∈ tokensOf M N
        · apply frame_step M K N (intH a) v' (.tok a) (htoks a ha) hne
          intro f hf n q p e he
          rw [nonEps_tok]
          cases e with
          | int b t =>
            simp only [hval, intH]
            by_cases hb : b = a
            · subst hb
              by_cases ht : t = q
              · simp only [ht, ite_true, S.mul_one]
                exact hbound f hf n p (kept_of_nonEps M he rfl)
              · simp [ht, S.zero_le]
            · simp [hb, S.zero_le]
          | _ => exact S.zero_le _
        · apply frame_step M K N (fun _ => none) v' (.tok a) (by simp [succOk, edgeCounts]) hne
          intro f hf n q p e he
          rw [nonEps_tok]
          cases e with
          | int b t =>
            simp only [hval, S.mul_zero]
            by_cases ht : t = q
            · by_cases hb : b = a
              · subst hb
                simp only [ht, ite_true]
                by_cases h0 : getV N f p = 0
                · rw [zeroCase f hf n p (kept_of_nonEps M he rfl) h0]; exact S.le_refl _
                · obtain ⟨w, hw⟩ := getV_ne_zero h0
                  exact absurd (mem_tokensOf M hw he) ha
              · simp [hb]
            · simp [ht]
          | _ => exact S.zero_le _
      | grp o inner c =>
        have hin : itemsSz inner ≤ k := by simp [Item.sz] at hv; omega
        -- the selector used when no claimed exit applies
        have viaNone : (∀ f ∈ K.fs, ∀ n p (cf t : Nat) c', Edge.call o cf t c' ∈ M.out p →
            c' = c → W M n (M.entry f) v' p * W M n (M.entry cf) inner (M.fin cf) = 0) →
            ∃ N' ∈ K.nodes, ∀ f ∈ K.fs, ∀ n q, M.kept q = true →
              W M n (M.entry f) (v' ++ [.grp o inner c]) q ≤ getV N' f q := by
          intro hz
          apply frame_step M K N (fun _ => none) v' _ (by simp [succOk, edgeCounts]) hne
          intro f hf n q p e he
          rw [nonEps_grp]
          cases e with
          | call o' cf t c' =>
            simp only [hval, S.mul_zero]
            by_cases ht : t = q
            · by_cases hoc : o' = o ∧ c' = c
              · obtain ⟨rfl, rfl⟩ := hoc
                simp only [ht, and_self, ite_true]
                rw [hz f hf n p cf t c' he rfl]; exact S.le_refl _
              · simp [hoc]
            · simp [ht]
          | _ => exact S.zero_le _
        by_cases ho : o ∈ openersOf M N
        · have hop := hopens o ho
          cases hbr : br o with
          | none => simp [hbr] at hop
          | some cl =>
            simp only [hbr] at hop
            cases hfind : findFrame C (dedupSorted (childrenOf M N o)) (some cl) with
            | none => simp [hfind] at hop
            | some K' =>
              simp only [hfind, Bool.and_eq_true, List.all_eq_true] at hop
              obtain ⟨hcfs, hexits⟩ := hop
              have hK' : K' ∈ C.frames := List.mem_of_find?_eq_some hfind
              obtain ⟨Nc, hNc, hcb⟩ := ih inner hin K' hK'
              have hF' := List.all_eq_true.mp hframes K' hK'
              unfold checkFrame at hF'
              simp only [Bool.and_eq_true, List.all_eq_true] at hF'
              have hsorted' := hF'.1.1.1
              have hck' := hF'.2 Nc hNc
              unfold checkNode at hck'
              simp only [Bool.and_eq_true, Bool.or_eq_true, List.isEmpty_iff] at hck'
              have hacc := hck'.1.1.1.2
              -- the child's acceptance bounds the interior of a matched call
              have childBound : ∀ f ∈ K.fs, ∀ n p cf t c', getV N f p ≠ 0 →
                  Edge.call o cf t c' ∈ M.out p →
                  W M n (M.entry cf) inner (M.fin cf) ≤ getV Nc cf (M.fin cf) ∧ cf ∈ K'.fs := by
                intro f _ n p cf t c' h0 he
                obtain ⟨w, hw⟩ := getV_ne_zero h0
                have hm : cf ∈ K'.fs := by
                  have := hcfs cf (mem_childrenOf M hw he)
                  exact List.contains_iff_mem.mp this
                exact ⟨hcb cf hm n _ (kept_fin M cf (callOk p o cf t c' he).2), hm⟩
              rcases hacc with hnil | hmem
              · apply viaNone
                intro f hf n p cf t c' he _
                by_cases h0 : getV N f p = 0
                · rw [zeroCase f hf n p (kept_of_nonEps M he rfl) h0, S.zero_mul]
                · obtain ⟨hb, hm⟩ := childBound f hf n p cf t c' h0 he
                  rw [accOf_nil_zero M Nc K'.fs hnil cf hm] at hb
                  rw [S.le_zero hb, S.mul_zero]
              · have hmem' : accOf M K'.fs Nc ∈ K'.exits := List.contains_iff_mem.mp hmem
                apply frame_step M K N (retH o (accOf M K'.fs Nc)) v' _
                  (hexits _ hmem') hne
                intro f hf n q p e he
                rw [nonEps_grp]
                cases e with
                | call o' cf t c' =>
                  simp only [hval, retH]
                  by_cases hoo : o' = o
                  · subst hoo
                    by_cases ht : t = q
                    · simp only [ht, ite_true]
                      by_cases hc' : c' = c
                      · subst hc'
                        simp only [and_self, ite_true]
                        by_cases h0 : getV N f p = 0
                        · rw [zeroCase f hf n p (kept_of_nonEps M he rfl) h0, S.zero_mul]
                          exact S.zero_le _
                        · obtain ⟨hb, hm⟩ := childBound f hf n p cf t c' h0 he
                          rw [exGet_accOf M Nc K'.fs hsorted' cf hm]
                          exact S.mul_le_mul (hbound f hf n p (kept_of_nonEps M he rfl)) hb
                      · simp [hc', S.zero_le]
                    · simp [ht, S.zero_le]
                  · simp [hoo, S.zero_le]
                | _ => exact S.zero_le _
        · apply viaNone
          intro f hf n p cf t c' he _
          by_cases h0 : getV N f p = 0
          · rw [zeroCase f hf n p (kept_of_nonEps M he rfl) h0, S.zero_mul]
          · obtain ⟨w, hw⟩ := getV_ne_zero h0
            exact absurd (mem_openersOf M hw he) ho

/-- **Soundness of the checker.** -/
theorem check_sound (hc : check br M C = true) : RootUnambiguous M := by
  intro v n
  have hc' := hc
  unfold check at hc'
  simp only [Bool.and_eq_true] at hc'
  obtain ⟨⟨hmodel, hroot⟩, hframes⟩ := hc'
  cases hfind : findFrame C [0] none with
  | none => simp [hfind] at hroot
  | some K =>
    have hK : K ∈ C.frames := List.mem_of_find?_eq_some hfind
    have hkey := List.find?_some hfind
    simp only [Bool.and_eq_true, beq_iff_eq] at hkey
    have hpos : 0 < M.frags.size := by
      unfold checkModel at hmodel; simp only [Bool.and_eq_true, decide_eq_true_eq] at hmodel
      exact hmodel.1
    obtain ⟨N, hN, hb⟩ := frame_inv br M C hc (itemsSz v) v (Nat.le_refl _) K hK
    have h := hb 0 (by rw [hkey.1]; simp) n (M.fin 0) (kept_fin M 0 hpos)
    have hF := List.all_eq_true.mp hframes K hK
    unfold checkFrame at hF
    simp only [Bool.and_eq_true, List.all_eq_true] at hF
    have hck := hF.2 N hN
    unfold checkNode at hck
    simp only [hkey.1, hkey.2, beq_self_eq_true, Bool.and_self, Bool.not_true,
      Bool.false_or, Bool.and_eq_true, decide_eq_true_eq] at hck
    exact S.le_trans h hck.1.1.2

end Main

end Ambiguity

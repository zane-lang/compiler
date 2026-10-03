import Ambiguity.ChainSound
import Ambiguity.MinSound

/-!
# Backward lower bounds: left-linear chains

A left-linear rule's private chain is entered only through its first node,
and each later node only through its predecessor; a DFA copy on the chain
is entered only through its start. Reading the last edge into a node
(`Wsup_bwd`) therefore bounds the count of a prefix followed by the chain.
-/

namespace Ambiguity

theorem conv_snoc : ∀ (u : List Item) (f g : List Item → S) (x : Item),
    conv f g (u ++ [x]) = conv f (fun v => g (v ++ [x])) u + f (u ++ [x]) * g []
  | [], f, g, x => by
    simp only [List.nil_append, conv_cons, conv_nil]
  | y :: u, f, g, x => by
    rw [List.cons_append, conv_cons, conv_snoc u, conv_cons, S.add_assoc]
    rfl

theorem conv_at_nil_right (f g : List Item → S) (hg : ∀ v, v ≠ [] → g v = 0) :
    ∀ u, conv f g u = f u * g []
  | [] => conv_nil f g
  | x :: u => by
    rw [conv_cons, conv_at_nil_right (fun v => f (x :: v)) g hg u, hg _ (by simp), S.mul_zero, S.zero_add]

theorem conv_smul_right (a : S) (f g : List Item → S) (u : List Item) :
    conv f (fun v => a * g v) u = a * conv f g u := by
  unfold conv; rw [mul_sumL]; apply sumL_congr; intro p _
  rw [← S.mul_assoc, S.mul_comm (f p.1) a, S.mul_assoc]

theorem conv_sum_right {α} (l : List α) (f : List Item → S) (g : α → List Item → S) (b : α → S) (u : List Item) :
    conv f (fun v => sumL l fun p => g p v * b p) u = sumL l fun p => conv f (g p) u * b p := by
  unfold conv
  simp only [mul_sumL, sumL_mul]
  rw [sumL_comm]
  apply sumL_congr; intro p _; apply sumL_congr; intro a _; rw [S.mul_assoc]

theorem Wsup_last (M : Model) {p : Nat} {e : Edge} (he : e ∈ M.out p) (q : Nat) (u : List Item) (z : Nat) :
    stepC M (Wsup M) q u z p e ≤ Wsup M q u z := by
  have hp : p < M.size := by
    rcases Nat.lt_or_ge p M.size with h | h; exact h
    rw [out_of_size M p h] at he; cases he
  refine S.le_trans (le_sumL he _) ?_
  refine S.le_trans (le_sumL (List.mem_range.mpr hp) (fun p => sumL (M.out p) (stepC M (Wsup M) q u z p))) ?_
  exact S.le_trans (S.le_add_left _ _) (Wsup_bwd M q u z)

/-- Distinct source nodes contribute separately. -/
theorem bwd_nodes (M : Model) (P : List Nat) (hP : P.Nodup) (q : Nat) (u : List Item) (z : Nat) (h : Nat → S)
    (hh : ∀ p ∈ P, h p ≤ sumL (M.out p) (stepC M (Wsup M) q u z p)) :
    sumL P h ≤ Wsup M q u z := by
  let g := fun p => sumL (M.out p) (stepC M (Wsup M) q u z p)
  refine S.le_trans (sumL_le_sumL _ hh) ?_
  have hz : sumL P g = sumL (P.filter (· < M.size)) g := by
    clear hP hh
    induction P with
    | nil => rfl
    | cons p P ih =>
      rw [List.filter_cons]
      by_cases hp : p < M.size
      · simp [hp, ih]
      · have : g p = 0 := by simp [g, out_of_size M p (Nat.le_of_not_lt hp)]
        simp [hp, ih, this]
  rw [hz]
  refine S.le_trans (sumL_nodup_sub (hP.filter _) (fun p hp => by
    simp only [List.mem_filter, decide_eq_true_eq] at hp
    exact List.mem_range.mpr hp.2) g) ?_
  exact S.le_trans (S.le_add_left _ _) (Wsup_bwd M q u z)

section
variable (D : DFA) (wt : Atom → Item → S) (N : Nat) (hT : ∀ d < N, ∀ p ∈ D.transAt d, p.2 < N)
include hT

theorem DW_eq : ∀ (u : List Item) (d₀ : Nat), d₀ < N →
    DW D wt d₀ u = sumL (List.range N) (fun d => DWp D wt d₀ u d * D.accAt d)
  | [], d₀, h₀ => by
    simp only [DWp, DW]
    have : (sumL (List.range N) fun d => (if d₀ = d then (1 : S) else 0) * D.accAt d) =
        sumL (List.range N) fun d => if d = d₀ then D.accAt d₀ else 0 := by
      apply sumL_congr; intro d _
      by_cases h : d = d₀
      · subst h; simp
      · simp [h, Ne.symm h]
    rw [this, sumL_range_ite, if_pos h₀]
  | x :: u, d₀, h₀ => by
    simp only [DWp, DW, sumL_mul]
    rw [sumL_comm]
    apply sumL_congr; intro p hp
    simp only [S.mul_assoc]
    rw [← mul_sumL, DW_eq u p.2 (hT d₀ h₀ p hp)]

end

theorem sumL_ne_zero {α} {l : List α} {f : α → S} (h : sumL l f ≠ 0) : ∃ a ∈ l, f a ≠ 0 := by
  induction l with
  | nil => exact absurd rfl h
  | cons a l ih =>
    by_cases ha : f a = 0
    · rw [sumL_cons, ha, S.zero_add] at h
      obtain ⟨b, hb, hfb⟩ := ih h
      exact ⟨b, List.mem_cons_of_mem _ hb, hfb⟩
    · exact ⟨a, List.mem_cons_self .., ha⟩

theorem mul_ne_zero_right {a b : S} (h : a * b ≠ 0) : b ≠ 0 := by
  intro hb; rw [hb, S.mul_zero] at h; exact h rfl

theorem bwd_idx (M : Model) {ι} (I : List ι) (ν : ι → Nat) (hI : (I.map ν).Nodup) (q : Nat) (u : List Item)
    (z : Nat) (h : ι → S) (hh : ∀ i ∈ I, h i ≤ sumL (M.out (ν i)) (stepC M (Wsup M) q u z (ν i))) :
    sumL I h ≤ Wsup M q u z := by
  refine S.le_trans (sumL_le_sumL _ hh) ?_
  rw [← sumL_map I ν (fun p => sumL (M.out p) (stepC M (Wsup M) q u z p))]
  exact bwd_nodes M _ hI q u z _ fun p _ => S.le_refl _

/-! ## Unique keys -/

theorem keys_idx {keys : Array UKey} {idx : Std.HashMap UKey Nat} (hK : checkKeys keys idx = true)
    {j : Nat} {k : UKey} (hj : keys[j]? = some k) : idx.get? k = some j := by
  unfold checkKeys at hK
  have hjs : j < keys.size := by
    rcases Nat.lt_or_ge j keys.size with h | h; exact h
    simp [Array.getElem?_eq_none h] at hj
  have := List.all_eq_true.mp hK j (List.mem_range.mpr hjs)
  rw [hj] at this
  simpa using this

theorem keys_inj {keys : Array UKey} {idx : Std.HashMap UKey Nat} (hK : checkKeys keys idx = true)
    {j j' : Nat} {k : UKey} (hj : keys[j]? = some k) (hj' : keys[j']? = some k) : j = j' := by
  have a := keys_idx hK hj
  have b := keys_idx hK hj'
  rw [a] at b; exact Option.some.inj b

theorem lookupId_spec {keys : Array UKey} {idx : Std.HashMap UKey Nat} {k : UKey} {j : Nat}
    (h : lookupId keys idx k = some j) : keys[j]? = some k := by
  unfold lookupId at h
  split at h
  · split at h
    · rename_i hk; simp only [Option.some.injEq] at h; subst h; simpa using hk
    · cases h
  · cases h

theorem lookupId_of_key {keys : Array UKey} {idx : Std.HashMap UKey Nat} (hK : checkKeys keys idx = true)
    {k : UKey} {j : Nat} (hj : keys[j]? = some k) : lookupId keys idx k = some j := by
  unfold lookupId
  rw [keys_idx hK hj]
  simp [hj]

theorem key_lt {keys : Array UKey} {j : Nat} {k : UKey} (hj : keys[j]? = some k) : j < keys.size := by
  rcases Nat.lt_or_ge j keys.size with h | h; exact h
  simp [Array.getElem?_eq_none h] at hj

theorem lib_parts {H : HFacts} (hL : checkLib H = true) (lid : Nat) (hlid : lid < H.lib.size) :
    0 < (H.dfa lid).trans.size ∧
      ∀ d < (H.dfa lid).trans.size, ∀ p ∈ (H.dfa lid).transAt d, p.2 < (H.dfa lid).trans.size := by
  unfold checkLib at hL
  have := List.all_eq_true.mp hL lid (List.mem_range.mpr hlid)
  simp only [Bool.and_eq_true, decide_eq_true_eq, List.all_eq_true, List.mem_range] at this
  exact ⟨this.1, fun d hd p hp => this.2 d hd p hp⟩

theorem lib_trans_lt {H : HFacts} (hL : checkLib H = true) (lid : Nat) :
    ∀ d, ∀ p ∈ (H.dfa lid).transAt d, p.2 < (H.dfa lid).trans.size := by
  intro d p hp
  by_cases hlid : lid < H.lib.size
  · have hd : d < (H.dfa lid).trans.size := by
      rcases Nat.lt_or_ge d (H.dfa lid).trans.size with h | h; exact h
      simp [DFA.transAt, Array.getD, Nat.not_lt.mpr h] at hp
    exact (lib_parts hL lid hlid).2 d hd p hp
  · have : H.dfa lid = default := by simp [HFacts.dfa, Array.getD, hlid]
    rw [this] at hp ⊢
    simp only [DFA.transAt, Array.getD] at hp
    split at hp
    · rename_i h; exact absurd h (Nat.not_lt_zero d)
    · cases hp

section
variable (H : HFacts) (E : PGrammar) (keys : Array UKey) (fI : Array (Option Nat)) (M : Model)
variable (hU : checkUniverse H E keys fI M = true)
include hU

/-- States reached in a DFA copy have nodes. -/
theorem comp_reach (lid tail : Nat) (wt : Atom → Item → S) :
    ∀ (v : List Item) (d₀ j₀ d : Nat), keys[j₀]? = some (.comp lid d₀ tail) →
      DWp (H.dfa lid) wt d₀ v d ≠ 0 → ∃ j : Nat, keys[j]? = some (UKey.comp lid d tail)
  | [], d₀, j₀, d, hj, hne => by
    simp only [DWp] at hne
    split at hne
    · rename_i h; subst h; exact ⟨j₀, hj⟩
    · exact absurd rfl hne
  | x :: v, d₀, j₀, d, hj, hne => by
    simp only [DWp] at hne
    obtain ⟨p, hp, hpz⟩ := sumL_ne_zero hne
    have hes := edges_of_key H E keys fI M hU hj
    obtain ⟨a, d'⟩ := p
    have hj' : ∃ t : Nat, keys[t]? = some (UKey.comp lid d' tail) := by
      cases a with
      | t b =>
        have hmem : SEdge.int b (.key (.comp lid d' tail)) ∈ specEdges H E (.comp lid d₀ tail) := by
          simp only [specEdges, List.mem_append, List.mem_map]
          exact Or.inr ⟨(.t b, d'), hp, rfl⟩
        obtain ⟨e, _, hok⟩ := edgesOk_mem hes hmem
        cases e with
        | int b' t => simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok; exact ⟨t, hok.2⟩
        | _ => simp [edgeOk] at hok
      | call o inner c =>
        have hmem : SEdge.call o inner (.key (.comp lid d' tail)) c ∈ specEdges H E (.comp lid d₀ tail) := by
          simp only [specEdges, List.mem_append, List.mem_map]
          exact Or.inr ⟨(.call o inner c, d'), hp, rfl⟩
        obtain ⟨e, _, hok⟩ := edgesOk_mem hes hmem
        cases e with
        | call o' f t c' =>
          simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok; exact ⟨t, hok.2⟩
        | _ => simp [edgeOk] at hok
    obtain ⟨t, ht⟩ := hj'
    exact comp_reach lid tail wt v d' t d ht (mul_ne_zero_right hpz)

end

end Ambiguity

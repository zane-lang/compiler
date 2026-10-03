import Ambiguity.DetSound

/-!
# Minimization of a component

A witness DFA maps into the library DFA of a member's language by a partial
state map; unmapped states reached from mapped ones are dead (never accept).
Weighted acceptance can only grow along the map.
-/

namespace Ambiguity

section
variable (D L : DFA) (wt : Atom → Item → S) (N : Nat) (h : Nat → Option Nat) (dead : Nat → Bool)
  (hT : ∀ d < N, ∀ p ∈ D.transAt d, p.2 < N)
  (hdead : ∀ d < N, dead d = true → D.accAt d = 0 ∧ ∀ p ∈ D.transAt d, dead p.2 = true)

include hT hdead in
theorem dead_zero : ∀ (u : List Item) (d : Nat), d < N → dead d = true → DW D wt d u = 0
  | [], d, hd, hk => (hdead d hd hk).1
  | x :: u, d, hd, hk => by
    simp only [DW]
    apply sumL_zero; intro p hp
    rw [dead_zero u p.2 (hT d hd p hp) ((hdead d hd hk).2 p hp), S.mul_zero]

theorem nodup_filterMap_fst {β} : ∀ (l : List (Atom × Nat)) (φ : Nat → Option β),
    (l.map (·.1)).Nodup → (l.filterMap fun p => (φ p.2).map fun b => (p.1, b)).Nodup
  | [], _, _ => List.nodup_nil
  | p :: l, φ, hn => by
    rw [List.map_cons, List.nodup_cons] at hn
    rw [List.filterMap_cons]
    cases hφ : φ p.2 with
    | none => exact nodup_filterMap_fst l φ hn.2
    | some b =>
      simp only [Option.map_some]
      refine List.nodup_cons.mpr ⟨?_, nodup_filterMap_fst l φ hn.2⟩
      intro hm
      obtain ⟨q, hq, hqe⟩ := List.mem_filterMap.mp hm
      cases hq2 : φ q.2 with
      | none => simp [hq2] at hqe
      | some b' =>
        simp only [hq2, Option.map_some, Option.some.injEq, Prod.mk.injEq] at hqe
        exact hn.1 (List.mem_map.mpr ⟨q, hq, hqe.1⟩)

include hT hdead in
/-- **(c)** A mapped state accepts no more than its library image. -/
theorem min_le (hND : ∀ d < N, ((D.transAt d).map (·.1)).Nodup)
    (hmin : ∀ d < N, ∀ e, h d = some e → D.accAt d ≤ L.accAt e ∧ ∀ p ∈ D.transAt d,
      (match h p.2 with
       | some e' => (L.transAt e).lookup p.1 = some e'
       | none => dead p.2 = true)) :
    ∀ (u : List Item) (d e : Nat), d < N → h d = some e → DW D wt d u ≤ DW L wt e u
  | [], d, e, hd, he => (hmin d hd e he).1
  | x :: u, d, e, hd, he => by
    simp only [DW]
    let φ : Atom × Nat → Option (Atom × Nat) := fun p => (h p.2).map fun b => (p.1, b)
    have h1 : sumL (D.transAt d) (fun p => wt p.1 x * DW D wt p.2 u) ≤
        sumL ((D.transAt d).filterMap φ) (fun q => wt q.1 x * DW L wt q.2 u) := by
      rw [sumL_filterMap]
      apply sumL_le_sumL; intro p hp
      have hm := (hmin d hd e he).2 p hp
      have hp2 := hT d hd p hp
      cases hh : h p.2 with
      | none =>
        rw [hh] at hm
        rw [show φ p = none by simp [φ, hh]]
        rw [dead_zero D wt N dead hT hdead u p.2 hp2 hm, S.mul_zero]
        exact S.zero_le _
      | some e' =>
        rw [show φ p = some (p.1, e') by simp [φ, hh]]
        exact S.mul_le_mul (S.le_refl _) (min_le hND hmin u p.2 e' hp2 hh)
    refine S.le_trans h1 ?_
    apply sumL_nodup_sub (nodup_filterMap_fst _ h (hND d hd))
    intro q hq
    obtain ⟨p, hp, hpq⟩ := List.mem_filterMap.mp hq
    have hm := (hmin d hd e he).2 p hp
    cases hh : h p.2 with
    | none => simp [φ, hh] at hpq
    | some e' =>
      simp only [φ, hh, Option.map_some, Option.some.injEq] at hpq
      subst hpq
      rw [hh] at hm
      exact lookup_mem' hm

end

/-! ## A member's NFA counts are bounded by its library DFA -/

def witDFA (w : CompWit) (fnode : Nat) : DFA :=
  { trans := w.trans, acc := w.states.map fun V => getV V 0 fnode }

theorem witDFA_acc (w : CompWit) (fnode d : Nat) (hd : d < w.states.size) :
    (witDFA w fnode).accAt d = getV (w.states.getD d []) 0 fnode := by
  simp [witDFA, DFA.accAt, Array.getD, hd]

theorem beq_some_iff {α} [DecidableEq α] (a b : Option α) : (a == b) = true ↔ a = b := by simp

theorem wit_member (H : HFacts) (keys : Array UKey) (idx : Std.HashMap UKey Nat)
    (fI : Array (Option Nat)) (M : Model) (w : CompWit)
    (hw : checkWit H keys idx fI M w = true) (hnd : fI.toList.Nodup)
    (hcall : ∀ p, ∀ e ∈ M.out p, ∀ o f t c, e = .call o f t c → f < fI.size)
    {m : Nat} (hm : m ∈ H.mems w.c) {s fnode : Nat}
    (hs : lookupId keys idx (startNode H w.c m) = some s)
    (hf : lookupId keys idx (finalNode H w.c m) = some fnode) (u : List Item) :
    Wsup M s u fnode ≤ DW (H.dfa (H.langOf m)) (wtM M fI) 0 u := by
  unfold checkWit at hw
  simp only [Bool.and_eq_true, List.all_eq_true, List.mem_range, decide_eq_true_eq] at hw
  obtain ⟨⟨h1, h2⟩, h3⟩ := hw
  have h3m := h3 m hm
  rw [hs, hf] at h3m
  split at h3m
  rotate_left
  · simp at h3m
  rename_i s' fnode' s0 hh dd e1 e2 e3 e4 e5
  simp only [Option.some.injEq] at e1 e2
  subst e1; subst e2
  simp only [Bool.and_eq_true, List.all_eq_true, List.mem_range, decide_eq_true_eq] at h3m
  obtain ⟨⟨⟨⟨hs0, hpost⟩, hfilt⟩, hh0⟩, hall⟩ := h3m
  let N := w.states.size
  let st := fun d => w.states.getD d []
  let finals := (H.mems w.c).filterMap fun m => lookupId keys idx (finalNode H w.c m)
  let D := witDFA w fnode
  have hT : ∀ d < N, ∀ p ∈ D.transAt d, p.2 < N := fun d hd p hp => by
    have := (h1 d hd).1 p hp; simpa [D, witDFA, DFA.transAt] using this
  have hND : ∀ d < N, ((D.transAt d).map (·.1)).Nodup := fun d hd => by
    have := (h1 d hd).2; simpa [D, witDFA, DFA.transAt] using this
  have hS : ∀ d < N, ∀ a ∈ atomsOf M fI (st d), ∃ d', (D.transAt d).lookup a = some d' ∧
      isPost M (edgeCounts M (st d) (atomH fI a)) (closure M (edgeCounts M (st d) (atomH fI a))) = true ∧
      filtH M finals (closure M (edgeCounts M (st d) (atomH fI a))) = st d' := by
    intro d hd a ha
    have := h2 d hd a ha
    split at this
    · simp at this
    · rename_i d' hl
      simp only [Bool.and_eq_true, beq_iff_eq] at this
      exact ⟨d', hl, this.1, this.2⟩
  have hkept : keptH M finals fnode = true := by
    unfold keptH
    simp only [Bool.or_eq_true, List.contains_iff_mem]
    exact Or.inl (List.mem_filterMap.mpr ⟨m, hm, hf⟩)
  have hdet := det_inv M fI finals N st D hnd hcall hT hND hS s s0 hs0 hpost
    (by simpa [finals, st] using hfilt) u fnode hkept
  refine S.le_trans hdet ?_
  have hacc : (sumL (List.range N) fun d => DWp D (wtM M fI) s0 u d * getV (st d) 0 fnode) =
      sumL (List.range N) fun d => DWp D (wtM M fI) s0 u d * D.accAt d := by
    apply sumL_congr; intro d hd
    rw [witDFA_acc w fnode d (List.mem_range.mp hd)]
  rw [hacc]
  refine S.le_trans (DWp_acc D (wtM M fI) N hT u s0 hs0) ?_
  have hh0' : hh.getD s0 none = some 0 := by simpa using hh0
  refine min_le D (H.dfa (H.langOf m)) (wtM M fI) N (fun d => hh.getD d none) (fun d => dd.getD d false)
    hT ?_ hND ?_ u s0 0 hs0 hh0'
  · intro d hd hk
    have := (hall d hd).2
    simp only [Bool.or_eq_true, Bool.not_eq_true', Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at this
    rcases this with h | ⟨ha, ht⟩
    · rw [hk] at h; cases h
    · refine ⟨by rw [witDFA_acc w fnode d hd]; exact ha, fun p hp => ?_⟩
      exact ht p hp
  · intro d hd e he
    have := (hall d hd).1
    rw [he] at this
    simp only [Bool.and_eq_true, decide_eq_true_eq, List.all_eq_true] at this
    refine ⟨by rw [witDFA_acc w fnode d hd]; exact this.1, fun p hp => ?_⟩
    have hp' := this.2 p hp
    split
    · rename_i e' he'
      rw [he'] at hp'
      simpa using hp'
    · rename_i he'
      rw [he'] at hp'
      simpa using hp'

end Ambiguity

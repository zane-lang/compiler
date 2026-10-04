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

theorem sum_reduce {β} (l : List Nat) (f : Nat → S) (φ : Nat → Option β)
    (h : ∀ d ∈ l, f d ≠ 0 → (φ d).isSome) :
    sumL l f = sumL (l.filterMap fun d => (φ d).map (d, ·)) (fun p => f p.1) := by
  induction l with
  | nil => rfl
  | cons d l ih =>
    rw [List.filterMap_cons, sumL_cons, ih (fun d' hd' => h d' (List.mem_cons_of_mem _ hd'))]
    cases hφ : φ d with
    | none =>
      have : f d = 0 := by
        rcases Classical.em (f d = 0) with h0 | h0
        · exact h0
        · have := h d (List.mem_cons_self ..) h0; rw [hφ] at this; cases this
      simp [this, hφ]
    | some b => simp

theorem nodup_pairs {β} : ∀ (l : List Nat) (φ : Nat → Option β), l.Nodup →
    (∀ d d' b, φ d = some b → φ d' = some b → d = d') →
    ((l.filterMap fun d => (φ d).map (d, ·)).map Prod.snd).Nodup
  | [], _, _, _ => List.nodup_nil
  | d :: l, φ, hn, hinj => by
    rw [List.nodup_cons] at hn
    rw [List.filterMap_cons]
    cases hφ : φ d with
    | none => exact nodup_pairs l φ hn.2 hinj
    | some b =>
      simp only [Option.map_some, List.map_cons]
      refine List.nodup_cons.mpr ⟨?_, nodup_pairs l φ hn.2 hinj⟩
      intro hm
      obtain ⟨pr, hp, hpe⟩ := List.mem_map.mp hm
      obtain ⟨d'', hd'', he⟩ := List.mem_filterMap.mp hp
      cases h'' : φ d'' with
      | none => simp [h''] at he
      | some b'' =>
        simp only [h'', Option.map_some, Option.some.injEq] at he
        have hb : b'' = b := by rw [← hpe, ← he]
        subst hb
        exact hn.1 ((hinj d d'' b'' hφ h'') ▸ hd'')

section
variable (H : HFacts) (E : PGrammar) (keys : Array UKey) (fI : Array (Option Nat)) (M : Model)
variable (hU : checkUniverse H E keys fI M = true)
variable (idx : Std.HashMap UKey Nat) (hK : checkKeys keys idx = true) (hL : checkLib H = true)
include hU hK hL

theorem comp_nodes_nodup (lid tail N : Nat) :
    (((List.range N).filterMap fun d => (lookupId keys idx (.comp lid d tail)).map (d, ·)).map Prod.snd).Nodup :=
  nodup_pairs _ _ List.nodup_range fun d d' b h1 h2 => by
    have := (lookupId_spec h1).symm.trans (lookupId_spec h2)
    simp only [Option.some.injEq, UKey.comp.injEq] at this
    exact this.2.1

theorem comp_nonzero (lid tail : Nat) {j₀ : Nat} (hj₀ : keys[j₀]? = some (.comp lid 0 tail))
    (L : List Item → S) (u : List Item) (d : Nat)
    (hne : conv L (fun v => DWp (H.dfa lid) (wtM M fI) 0 v d) u ≠ 0) :
    (lookupId keys idx (.comp lid d tail)).isSome := by
  unfold conv at hne
  obtain ⟨p, _, hp⟩ := sumL_ne_zero hne
  obtain ⟨j, hj⟩ := comp_reach H E keys fI M hU lid tail (wtM M fI) p.2 0 j₀ d hj₀ (mul_ne_zero_right hp)
  rw [lookupId_of_key hK hj]; rfl

/-- **Backward DFA copy.** A copy entered from `src` by its start edge,
read to state `d`. -/
theorem comp_bwd (lid tail q src c0 : Nat) (hc0 : keys[c0]? = some (.comp lid 0 tail))
    (hsrc : Edge.eps c0 1 ∈ M.out src) (hsk : ∀ d, keys[src]? ≠ some (.comp lid d tail))
    (L : List Item → S) (hL' : ∀ v, L v ≤ Wsup M q v src) :
    ∀ (k : Nat) (u : List Item), u.length ≤ k → ∀ d j, keys[j]? = some (.comp lid d tail) →
      conv L (fun v => DWp (H.dfa lid) (wtM M fI) 0 v d) u ≤ Wsup M q u j := by
  have hnd := (universe_parts H E keys fI M hU).2.2.2.2.1
  let D := H.dfa lid
  let N := D.trans.size + 1
  have hT : ∀ d < N, ∀ p ∈ D.transAt d, p.2 < N := fun d _ p hp =>
    Nat.lt_succ_of_lt (lib_trans_lt hL lid d p hp)
  have base : ∀ u, u = [] → ∀ d j, keys[j]? = some (.comp lid d tail) →
      conv L (fun v => DWp D (wtM M fI) 0 v d) u ≤ Wsup M q u j := by
    intro u hu d j hj; subst hu
    rw [conv_nil]
    simp only [DWp]
    by_cases hd : 0 = d
    · subst hd
      have := keys_inj hK hj hc0; subst this
      simp only [ite_true, S.mul_one]
      refine S.le_trans (hL' []) ?_
      have := Wsup_last M hsrc q [] j
      simpa [stepC] using this
    · simp [hd]
  intro k
  induction k with
  | zero => intro u hu; exact base u (List.eq_nil_of_length_eq_zero (by omega))
  | succ k ih =>
    intro u hu d j hj
    rcases List.eq_nil_or_concat u with h | ⟨u', x, rfl⟩
    · exact base u h d j hj
    rw [List.concat_eq_append] at hu ⊢
    have hu' : u'.length ≤ k := by simp at hu; omega
    rw [conv_snoc]
    let B : Nat → S := fun d' => sumL (D.transAt d') fun p => if p.2 = d then wtM M fI p.1 x else 0
    have e1 : ∀ v, DWp D (wtM M fI) 0 (v ++ [x]) d = sumL (List.range N) fun d' => DWp D (wtM M fI) 0 v d' * B d' :=
      fun v => DWp_snoc D (wtM M fI) N hT x v 0 d (Nat.succ_pos _)
    rw [conv_congr (fun _ => rfl) e1, conv_sum_right]
    let φ : Nat → Option Nat := fun d' => lookupId keys idx (.comp lid d' tail)
    rw [sum_reduce _ _ φ (fun d' _ hne => comp_nonzero H E keys fI M hU idx hK hL lid tail hc0 L u' d'
      (fun h0 => hne (by rw [h0, S.zero_mul])))]
    -- the start edge and the DFA's own edges are distinct last edges
    let I : List (Option (Nat × Nat)) := (if d = 0 then [none] else []) ++
      ((List.range N).filterMap fun d' => (φ d').map (d', ·)).map some
    let ν : Option (Nat × Nat) → Nat := fun i => match i with | none => src | some p => p.2
    let h : Option (Nat × Nat) → S := fun i => match i with
      | none => L (u' ++ [x])
      | some p => conv L (fun v => DWp D (wtM M fI) 0 v p.1) u' * B p.1
    have hsum : sumL I h = (sumL ((List.range N).filterMap fun d' => (φ d').map (d', ·))
        fun p => conv L (fun v => DWp D (wtM M fI) 0 v p.1) u' * B p.1) +
        L (u' ++ [x]) * DWp D (wtM M fI) 0 [] d := by
      simp only [I, sumL_append, sumL_map, DWp]
      by_cases hd : d = 0
      · subst hd; simp [h, S.add_comm]
      · simp [h, hd, Ne.symm hd]
    rw [← hsum]
    refine bwd_idx M I ν ?_ q (u' ++ [x]) j h ?_
    · simp only [I, List.map_append, List.map_map]
      have hn := comp_nodes_nodup H E keys fI M hU idx hK hL lid tail N
      rw [List.nodup_append]
      refine ⟨?_, ?_, ?_⟩
      · split <;> simp
      · exact hn
      · intro a ha b hb hab
        split at ha
        · simp only [List.map_cons, List.map_nil, List.mem_singleton] at ha
          subst ha; subst hab
          obtain ⟨pr, hp, hpe⟩ := List.mem_map.mp hb
          obtain ⟨d'', _, he⟩ := List.mem_filterMap.mp hp
          cases h'' : φ d'' with
          | none => simp [h''] at he
          | some b'' =>
            simp only [h'', Option.map_some, Option.some.injEq] at he
            subst he
            simp only [Function.comp, ν] at hpe
            exact hsk d'' (hpe ▸ lookupId_spec h'')
        · cases ha
    · intro i hi
      cases i with
      | none =>
        have hd : d = 0 := by
          simp only [I, List.mem_append, List.mem_map] at hi
          rcases hi with hi | ⟨_, _, hi⟩
          · split at hi
            · assumption
            · cases hi
          · cases hi
        subst hd
        have := keys_inj hK hj hc0; subst this
        refine S.le_trans (hL' _) ?_
        refine S.le_trans ?_ (le_sumL hsrc _)
        simp [stepC, ν]
      | some p =>
        obtain ⟨d', j'⟩ := p
        have hφ : φ d' = some j' := by
          simp only [I, List.mem_append, List.mem_map] at hi
          rcases hi with hi | ⟨a, ha, he⟩
          · split at hi <;> simp at hi
          · simp only [Option.some.injEq] at he; subst he
            obtain ⟨d'', _, he⟩ := List.mem_filterMap.mp ha
            cases h'' : φ d'' with
            | none => simp [h''] at he
            | some b'' =>
              simp only [h'', Option.map_some, Option.some.injEq, Prod.mk.injEq] at he
              obtain ⟨rfl, rfl⟩ := he; exact h''
        have hj' := lookupId_spec hφ
        simp only [h, ν]
        refine S.le_trans (S.mul_le_mul (ih u' hu' d' j' hj') (S.le_refl _)) ?_
        have hes := edges_of_key H E keys fI M hU hj'
        let g : SEdge → S := fun s => match s with
          | .int a (.key (.comp lid'' d'' tail'')) =>
            if lid'' = lid ∧ d'' = d ∧ tail'' = tail then wtM M fI (.t a) x * Wsup M q u' j' else 0
          | .call o inner (.key (.comp lid'' d'' tail'')) c =>
            if lid'' = lid ∧ d'' = d ∧ tail'' = tail then wtM M fI (.call o inner c) x * Wsup M q u' j' else 0
          | _ => 0
        refine S.le_trans ?_ (edgesOk_sum keys fI hes g _ ?_)
        · simp only [specEdges, sumL_append, sumL_map, B, sumL_mul]
          refine S.le_trans ?_ (S.le_add_left _ _)
          rw [mul_sumL]
          apply sumL_le_sumL; intro p _
          obtain ⟨a, d''⟩ := p
          by_cases hd : d'' = d
          · subst hd; cases a <;> simp [g, S.mul_comm]
          · cases a <;> simp [g, hd]
        · intro s e hse
          cases s with
          | int a t =>
            cases t with
            | key kk =>
              cases kk with
              | comp lid'' d'' tail'' =>
                cases e with
                | int a' t' =>
                  simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hse
                  obtain ⟨rfl, ht⟩ := hse
                  simp only [g]
                  split
                  · rename_i hc
                    obtain ⟨rfl, rfl, rfl⟩ := hc
                    have := keys_inj hK ht hj; subst this
                    simp only [stepC, ite_true, List.getLast?_concat, List.dropLast_concat]
                    cases x with
                    | grp _ _ _ => simp [wtM]
                    | tok b => simp only [wtM]; split <;> simp_all
                  · exact S.zero_le _
                | _ => simp [edgeOk] at hse
              | _ => exact S.zero_le _
            | _ => exact S.zero_le _
          | call o inner t c =>
            cases t with
            | key kk =>
              cases kk with
              | comp lid'' d'' tail'' =>
                cases e with
                | call o' f t' c' =>
                  simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hse
                  obtain ⟨⟨⟨rfl, rfl⟩, hf⟩, ht⟩ := hse
                  simp only [g]
                  split
                  · rename_i hc
                    obtain ⟨rfl, rfl, rfl⟩ := hc
                    have := keys_inj hK ht hj; subst this
                    simp only [stepC, ite_true, List.getLast?_concat, List.dropLast_concat]
                    cases x with
                    | tok _ => simp [wtM]
                    | grp o'' v c'' =>
                      simp only [wtM]
                      split
                      · rw [fragW_eq M fI hnd hf v, S.mul_comm]; exact S.le_refl _
                      · simp
                  · exact S.zero_le _
                | _ => simp [edgeOk] at hse
              | _ => exact S.zero_le _
            | _ => exact S.zero_le _
          | _ => exact S.zero_le _

end

theorem mem_pairs {β} {l : List Nat} {φ : Nat → Option β} {d : Nat} {b : β}
    (h : (d, b) ∈ l.filterMap fun d => (φ d).map (d, ·)) : φ d = some b := by
  obtain ⟨d', _, he⟩ := List.mem_filterMap.mp h
  cases h' : φ d' with
  | none => rw [h'] at he; cases he
  | some b' =>
    rw [h'] at he
    simp only [Option.map_some, Option.some.injEq, Prod.mk.injEq] at he
    obtain ⟨rfl, rfl⟩ := he; exact h'

theorem conv_one_snoc (f g : List Item → S) (hg : ∀ v, v.length ≠ 1 → g v = 0) (u : List Item) (x : Item) :
    conv f g (u ++ [x]) = f u * g [x] := by
  rw [conv_snoc, hg [] (by simp), S.mul_zero, S.add_zero]
  rw [conv_at_nil_right f (fun v => g (v ++ [x])) (fun v hv => hg _ (by
    cases v with
    | nil => exact absurd rfl hv
    | cons _ _ => simp))]
  rfl

theorem conv_one_nil (f g : List Item → S) (hg : ∀ v, v.length ≠ 1 → g v = 0) : conv f g [] = 0 := by
  rw [conv_nil, hg [] (by simp), S.mul_zero]

theorem bodyCnt_snoc (H : HFacts) (M : Model) (fI : Array (Option Nat)) (s : CSym) :
    ∀ (β : List CSym) (u : List Item),
      bodyCnt H M fI (β ++ [s]) u = conv (bodyCnt H M fI β) (symCnt H M fI s) u
  | [], u => by
    simp only [List.nil_append, bodyCnt]
    rw [conv_delta_right, conv_delta_left]
  | b :: β, u => by
    simp only [List.cons_append, bodyCnt]
    rw [conv_congr (fun _ => rfl) (bodyCnt_snoc H M fI s β), conv_assoc]

section
variable (H : HFacts) (E : PGrammar) (keys : Array UKey) (fI : Array (Option Nat)) (M : Model)
variable (hU : checkUniverse H E keys fI M = true)
variable (idx : Std.HashMap UKey Nat) (hK : checkKeys keys idx = true) (hL : checkLib H = true)
include hU hK hL

/-- Leaving a DFA copy through its accepting edges. -/
theorem comp_exit (lid tail q src c0 : Nat) (hc0 : keys[c0]? = some (.comp lid 0 tail))
    (hsrc : Edge.eps c0 1 ∈ M.out src) (hsk : ∀ d, keys[src]? ≠ some (.comp lid d tail))
    (L : List Item → S) (hL' : ∀ v, L v ≤ Wsup M q v src) (u : List Item) :
    conv L (DW (H.dfa lid) (wtM M fI) 0) u ≤ Wsup M q u tail := by
  let D := H.dfa lid
  let N := D.trans.size + 1
  have hT : ∀ d < N, ∀ p ∈ D.transAt d, p.2 < N := fun d _ p hp =>
    Nat.lt_succ_of_lt (lib_trans_lt hL lid d p hp)
  rw [conv_congr (fun _ => rfl) (fun v => DW_eq D (wtM M fI) N hT v 0 (Nat.succ_pos _)), conv_sum_right]
  let φ : Nat → Option Nat := fun d => lookupId keys idx (.comp lid d tail)
  rw [sum_reduce _ _ φ (fun d _ hne => comp_nonzero H E keys fI M hU idx hK hL lid tail hc0 L u d
    (fun h0 => hne (by rw [h0, S.zero_mul])))]
  refine bwd_idx M _ Prod.snd (comp_nodes_nodup H E keys fI M hU idx hK hL lid tail N) q u tail _ ?_
  intro p hp
  obtain ⟨d, j⟩ := p
  have hj := lookupId_spec (mem_pairs hp)
  refine S.le_trans (S.mul_le_mul (comp_bwd H E keys fI M hU idx hK hL lid tail q src c0 hc0 hsrc hsk L hL'
    u.length u (Nat.le_refl _) d j hj) (S.le_refl _)) ?_
  by_cases ha : D.accAt d = 0
  · show _ * D.accAt d ≤ _
    rw [ha, S.mul_zero]; exact S.zero_le _
  · have hes := edges_of_key H E keys fI M hU hj
    obtain ⟨e, he, hok⟩ := edgesOk_mem hes (s := .eps (.id tail) (D.accAt d)) (by simp [specEdges, D, ha])
    cases e with
    | eps t w =>
      simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨rfl, rfl⟩ := hok
      refine S.le_trans ?_ (le_sumL he _)
      simp [stepC]
    | _ => simp [edgeOk] at hok

theorem symEdge_tgt {s : CSym} {k : UKey} {e : Edge} (hok : edgeOk keys fI (symEdge H s (.key k)) e = true) :
    ∃ t : Nat, keys[t]? = some k := by
  cases s with
  | term a =>
    cases e with
    | int a' t => simp only [symEdge, edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok; exact ⟨t, hok.2⟩
    | _ => simp [symEdge, edgeOk] at hok
  | call o inner c =>
    cases e with
    | call o' f t c' => simp only [symEdge, edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok; exact ⟨t, hok.2⟩
    | _ => simp [symEdge, edgeOk] at hok
  | low y =>
    cases e with
    | eps t w =>
      simp only [symEdge, edgeOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨j, _, hj⟩ := tgtOk_comp0 hok.2
      simp only [tgtOk, beq_iff_eq] at hj
      exact ⟨j, hj⟩
    | _ => simp [symEdge, edgeOk] at hok
  | w2 =>
    cases e with
    | eps t w => simp only [symEdge, edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok; exact ⟨t, hok.2⟩
    | _ => simp [symEdge, edgeOk] at hok

/-- One body symbol read backward into its target. -/
theorem sym_bwd (s : CSym) (k : UKey) (q src : Nat) (hsk : ∀ lid d tail, keys[src]? ≠ some (.comp lid d tail))
    (L : List Item → S) (hL' : ∀ v, L v ≤ Wsup M q v src)
    {e : Edge} (he : e ∈ M.out src) (hok : edgeOk keys fI (symEdge H s (.key k)) e = true)
    {t : Nat} (ht : keys[t]? = some k) (u : List Item) :
    conv L (symCnt H M fI s) u ≤ Wsup M q u t := by
  have hnd := (universe_parts H E keys fI M hU).2.2.2.2.1
  cases s with
  | term a =>
    cases e with
    | int a' t' =>
      simp only [symEdge, edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨rfl, ht'⟩ := hok
      have := keys_inj hK ht' ht; subst this
      have hg : ∀ v, v.length ≠ 1 → symCnt H M fI (.term a) v = 0 := fun v hv => by
        simp only [symCnt]; split
        · simp at hv
        · rfl
      rcases List.eq_nil_or_concat u with h | ⟨u', x, rfl⟩
      · subst h; rw [conv_one_nil _ _ hg]; exact S.zero_le _
      rw [List.concat_eq_append, conv_one_snoc _ _ hg]
      refine S.le_trans ?_ (Wsup_last M he q _ _)
      simp only [stepC, ite_true, List.getLast?_concat, List.dropLast_concat, symCnt]
      cases x with
      | grp _ _ _ => simp
      | tok b => by_cases hab : a = b <;> simp [hab, hL']
    | _ => simp [symEdge, edgeOk] at hok
  | call o inner c =>
    cases e with
    | call o' f t' c' =>
      simp only [symEdge, edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨⟨⟨rfl, rfl⟩, hf⟩, ht'⟩ := hok
      have := keys_inj hK ht' ht; subst this
      have hg : ∀ v, v.length ≠ 1 → symCnt H M fI (.call o inner c) v = 0 := fun v hv => by
        simp only [symCnt]; split
        · simp at hv
        · rfl
      rcases List.eq_nil_or_concat u with h | ⟨u', x, rfl⟩
      · subst h; rw [conv_one_nil _ _ hg]; exact S.zero_le _
      rw [List.concat_eq_append, conv_one_snoc _ _ hg]
      refine S.le_trans ?_ (Wsup_last M he q _ _)
      simp only [stepC, ite_true, List.getLast?_concat, List.dropLast_concat, symCnt]
      cases x with
      | tok _ => simp
      | grp o'' v c'' =>
        simp only
        split
        · rw [fragW_eq M fI hnd hf v]; exact S.mul_le_mul (hL' _) (S.le_refl _)
        · simp
    | _ => simp [symEdge, edgeOk] at hok
  | low y =>
    cases e with
    | eps c0 w =>
      simp only [symEdge, edgeOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨rfl, hc⟩ := hok
      obtain ⟨j, hc0, hj⟩ := tgtOk_comp0 hc
      simp only [tgtOk, beq_iff_eq] at hj
      have := keys_inj hK hj ht; subst this
      exact comp_exit H E keys fI M hU idx hK hL _ j q src c0 hc0 he (fun d => hsk _ d j) L hL' u
    | _ => simp [symEdge, edgeOk] at hok
  | w2 =>
    cases e with
    | eps t' w =>
      simp only [symEdge, edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨rfl, ht'⟩ := hok
      have := keys_inj hK ht' ht; subst this
      rw [conv_at_nil_right _ _ (fun v hv => by simp [symCnt, hv])]
      refine S.le_trans ?_ (Wsup_last M he q _ _)
      simp only [symCnt, List.isEmpty_nil, ite_true, stepC]
      exact S.mul_le_mul (hL' u) (S.le_refl _)
    | _ => simp [symEdge, edgeOk] at hok

end

section
variable (H : HFacts) (E : PGrammar) (keys : Array UKey) (fI : Array (Option Nat)) (M : Model)
variable (hU : checkUniverse H E keys fI M = true)
variable (idx : Std.HashMap UKey Nat) (hK : checkKeys keys idx = true) (hL : checkLib H = true)
include hU hK hL

/-- **Private chain of a left-linear rule**, read backward from its first node. -/
theorem rpos_bwd (c m i : Nat) {r : List Sym} (hr : (E.rulesOf m)[i]? = some r)
    {o : UKey} {body : List CSym} {dest : UKey} {w : S} (hn : ruleNfa H c m r = .edge o body dest w)
    (q r0 : Nat) (h0 : keys[r0]? = some (.rpos c m i 0)) :
    ∀ k, k ≤ body.length → ∃ rk, keys[rk]? = some (.rpos c m i k) ∧
      ∀ u, conv (fun v => Wsup M q v r0) (bodyCnt H M fI (body.take k)) u ≤ Wsup M q u rk
  | 0, _ => ⟨r0, h0, fun u => by
      simp only [List.take_zero, bodyCnt]; rw [conv_delta_right]; exact S.le_refl _⟩
  | k + 1, hk => by
    obtain ⟨rk, hrk, hb⟩ := rpos_bwd c m i hr hn q r0 h0 k (by omega)
    have hlt : k < body.length := by omega
    have hs : body[k]? = some body[k] := List.getElem?_eq_getElem hlt
    have hes := edges_of_key H E keys fI M hU hrk
    have hspec : specEdges H E (.rpos c m i k) = [symEdge H body[k] (.key (.rpos c m i (k + 1)))] := by
      simp [specEdges, hr, hn, hs]
    rw [hspec] at hes
    obtain ⟨e, he, hok⟩ := edgesOk_mem hes (List.mem_singleton_self _)
    obtain ⟨t, ht⟩ := symEdge_tgt H E keys fI M hU idx hK hL hok
    refine ⟨t, ht, fun u => ?_⟩
    rw [List.take_succ, hs, Option.toList_some, conv_congr (fun _ => rfl) (bodyCnt_snoc H M fI _ _), conv_assoc]
    exact sym_bwd H E keys fI M hU idx hK hL _ _ q rk (fun lid d tail h => by rw [hrk] at h; cases h)
      _ hb he hok ht u

theorem rpos_end (c m i : Nat) {r : List Sym} (hr : (E.rulesOf m)[i]? = some r)
    {o : UKey} {body : List CSym} {dest : UKey} {w : S} (hn : ruleNfa H c m r = .edge o body dest w)
    {rk : Nat} (hrk : keys[rk]? = some (.rpos c m i body.length)) {t : Nat} (ht : keys[t]? = some dest)
    (q : Nat) (u : List Item) : Wsup M q u rk ≤ Wsup M q u t := by
  have hes := edges_of_key H E keys fI M hU hrk
  have hspec : specEdges H E (.rpos c m i body.length) = [.eps (.key dest) 1] := by
    simp [specEdges, hr, hn]
  rw [hspec] at hes
  obtain ⟨e, he, hok⟩ := edgesOk_mem hes (List.mem_singleton_self _)
  cases e with
  | eps t' w' =>
    simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hok
    obtain ⟨rfl, ht'⟩ := hok
    have := keys_inj hK ht' ht; subst this
    refine S.le_trans ?_ (Wsup_last M he q u _)
    simp [stepC]
  | _ => simp [edgeOk] at hok

end

end Ambiguity

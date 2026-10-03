import Ambiguity.BwdSound

/-!
# Rules against their NFA edges

How many ways a rule derives a word is bounded by what its compiled edge
reads: a body (`bodyCnt`), with the same-component symbol before or after
it and the weight of the empty context.
-/

namespace Ambiguity

section
variable (H : HFacts) (M : Model) (fI : Array (Option Nat)) (cn : Nat → List Item → S)
  (hne : ∀ y, H.isNe y = true → ∀ v, cn y v ≤ DW (H.dfa (H.langOf y)) (wtM M fI) 0 v)
  (heps : ∀ y, H.isNe y = false → ∀ v, cn y v ≤ if v.isEmpty then H.epsOf y else 0)

theorem cntSeq_n (y : Nat) (rest : List Sym) (u : List Item) :
    cntSeq cn (.n y :: rest) u = conv (cn y) (cntSeq cn rest) u := rfl

theorem cntSeq_nil : cntSeq cn [] = delta := funext fun _ => rfl

theorem S_cases (a : S) (h0 : a ≠ 0) (h2 : a ≠ 2) : a = 1 := by
  revert h0 h2; cases a <;> decide

include hne heps in
theorem seq_body : ∀ (syms : List Sym) (body : List CSym), bodySyms H syms = some body →
    ∀ rest u, cntSeq cn (syms ++ rest) u ≤ conv (bodyCnt H M fI body) (cntSeq cn rest) u
  | [], body, hb, rest, u => by
    simp only [bodySyms, Option.some.injEq] at hb; subst hb
    rw [List.nil_append, bodyCnt, conv_delta_left]; exact S.le_refl _
  | .t a :: syms, body, hb, rest, u => by
    simp only [bodySyms] at hb
    cases hb' : bodySyms H syms with
    | none => rw [hb'] at hb; cases hb
    | some body' =>
      rw [hb'] at hb
      simp only [Option.map_eq_map, Option.map_some, Option.some.injEq] at hb; subst hb
      rw [bodyCnt, ← conv_assoc]
      rw [conv_one _ _ (fun v hv => by
        simp only [symCnt]; split
        · simp at hv
        · rfl) u]
      cases u with
      | nil => simp [cntSeq]
      | cons x u =>
        cases x with
        | grp _ _ _ => simp [cntSeq, symCnt]
        | tok b =>
          simp only [List.cons_append, cntSeq, symCnt]
          split
          · rw [S.one_mul]; exact seq_body syms body' hb' rest u
          · exact S.zero_le _
  | .n y :: syms, body, hb, rest, u => by
    simp only [bodySyms] at hb
    rw [List.cons_append, cntSeq_n]
    by_cases hy : H.isNe y = true
    · simp only [hy, ite_true] at hb
      cases hb' : bodySyms H syms with
      | none => rw [hb'] at hb; cases hb
      | some body' =>
        rw [hb'] at hb
        simp only [Option.map_eq_map, Option.map_some, Option.some.injEq] at hb; subst hb
        rw [bodyCnt, ← conv_assoc]
        exact conv_mono (hne y hy) (fun v => seq_body syms body' hb' rest v) u
    · have hy' : H.isNe y = false := by simpa using hy
      simp only [hy', Bool.false_eq_true, ite_false] at hb
      by_cases h0 : H.epsOf y = 0
      · simp [h0] at hb
      · simp only [h0, ite_false] at hb
        by_cases h2 : H.epsOf y = 2
        · simp only [h2, ite_true] at hb
          cases hb' : bodySyms H syms with
          | none => rw [hb'] at hb; cases hb
          | some body' =>
            rw [hb'] at hb
            simp only [Option.map_eq_map, Option.map_some, Option.some.injEq] at hb; subst hb
            rw [bodyCnt, ← conv_assoc]
            refine conv_mono (fun v => ?_) (fun v => seq_body syms body' hb' rest v) u
            refine S.le_trans (heps y hy' v) ?_
            simp only [symCnt, h2]; exact S.le_refl _
        · simp only [h2, ite_false] at hb
          have h1 := S_cases _ h0 h2
          refine S.le_trans (conv_mono (g' := conv (bodyCnt H M fI body) (cntSeq cn rest)) (f' := delta)
            (fun v => ?_) (fun v => seq_body syms body hb rest v) u) ?_
          · refine S.le_trans (heps y hy' v) ?_
            simp only [delta, h1]; exact S.le_refl _
          · rw [conv_delta_left]; exact S.le_refl _

include heps in
theorem seq_dead : ∀ (syms : List Sym), bodySyms H syms = none → ∀ rest u, cntSeq cn (syms ++ rest) u = 0
  | [], hb, _, _ => by simp [bodySyms] at hb
  | .t a :: syms, hb, rest, u => by
    simp only [bodySyms] at hb
    cases hb' : bodySyms H syms with
    | some _ => rw [hb'] at hb; cases hb
    | none =>
      cases u with
      | nil => simp [cntSeq]
      | cons x u =>
        cases x with
        | grp _ _ _ => simp [cntSeq]
        | tok b =>
          simp only [List.cons_append, cntSeq]
          split
          · exact seq_dead syms hb' rest u
          · rfl
  | .n y :: syms, hb, rest, u => by
    simp only [bodySyms] at hb
    rw [List.cons_append, cntSeq_n]
    have tail0 : bodySyms H syms = none → conv (cn y) (cntSeq cn (syms ++ rest)) u = 0 := fun hb' => by
      unfold conv; apply sumL_zero; intro p _; rw [seq_dead syms hb' rest p.2, S.mul_zero]
    by_cases hy : H.isNe y = true
    · simp only [hy, ite_true] at hb
      cases hb' : bodySyms H syms with
      | some _ => rw [hb'] at hb; cases hb
      | none => exact tail0 hb'
    · have hy' : H.isNe y = false := by simpa using hy
      simp only [hy', Bool.false_eq_true, ite_false] at hb
      by_cases h0 : H.epsOf y = 0
      · unfold conv; apply sumL_zero; intro p _
        have := heps y hy' p.1
        rw [h0] at this
        have : cn y p.1 = 0 := S.le_antisymm (by split at this <;> exact this) (S.zero_le _)
        rw [this, S.zero_mul]
      · simp only [h0, ite_false] at hb
        by_cases h2 : H.epsOf y = 2
        · simp only [h2, ite_true] at hb
          cases hb' : bodySyms H syms with
          | some _ => rw [hb'] at hb; cases hb
          | none => exact tail0 hb'
        · simp only [h2, ite_false] at hb
          exact tail0 hb

include heps in
theorem seq_eps : ∀ (syms : List Sym) (w : S), epsCtx H syms = some w →
    ∀ rest u, cntSeq cn (syms ++ rest) u ≤ w * cntSeq cn rest u
  | [], w, hw, rest, u => by
    simp only [epsCtx, Option.some.injEq] at hw; subst hw
    rw [List.nil_append, S.one_mul]; exact S.le_refl _
  | .t a :: syms, w, hw, _, _ => by simp [epsCtx] at hw
  | .n y :: syms, w, hw, rest, u => by
    simp only [epsCtx] at hw
    by_cases hy : H.isNe y = true
    · simp [hy] at hw
    · have hy' : H.isNe y = false := by simpa using hy
      simp only [hy', Bool.false_eq_true, ite_false] at hw
      cases hw' : epsCtx H syms with
      | none => rw [hw'] at hw; cases hw
      | some w' =>
        rw [hw'] at hw
        simp only [Option.map_eq_map, Option.map_some, Option.some.injEq] at hw; subst hw
        rw [List.cons_append, cntSeq_n]
        refine S.le_trans (conv_mono (f' := fun v => if v.isEmpty then H.epsOf y else 0)
          (g' := fun v => w' * cntSeq cn rest v) (heps y hy') (fun v => seq_eps syms w' hw' rest v) u) ?_
        rw [conv_at_nil _ _ (fun v hv => by simp [hv]), S.mul_assoc]
        exact S.le_refl _

end

theorem sameIdx_mem {H : HFacts} {c : Nat} {r : List Sym} {i : Nat} (h : i ∈ sameIdx H c r) :
    ∃ y, r[i]? = some (.n y) := by
  unfold sameIdx at h
  obtain ⟨⟨s, j⟩, hm, rfl⟩ := List.mem_map.mp h
  obtain ⟨hz, hp⟩ := List.mem_filter.mp hm
  have := List.mk_mem_zipIdx_iff_getElem?.mp hz
  cases s with
  | n y => exact ⟨y, this⟩
  | t _ => simp at hp

theorem split_at {r : List Sym} {i : Nat} {s : Sym} (h : r[i]? = some s) :
    r = r.take i ++ (s :: r.drop (i + 1)) := by
  have hi : i < r.length := by
    rcases Nat.lt_or_ge i r.length with hl | hl; exact hl
    simp [List.getElem?_eq_none hl] at h
  have hs : r[i] = s := by simpa [List.getElem?_eq_getElem hi] using h
  have := List.take_append_drop i r
  rw [List.drop_eq_getElem_cons hi, hs] at this
  exact this.symm

/-- The shapes of a rule that compiles to an edge. -/
theorem ruleNfa_edge {H : HFacts} {c m : Nat} {r : List Sym} {o : UKey} {body : List CSym} {dest : UKey} {w : S}
    (hn : ruleNfa H c m r = .edge o body dest w) :
    ((∃ o' inner cl, groupRule? r = some (o', inner, cl) ∧ body = [.call o' inner cl]) ∨
       (groupRule? r = none ∧ bodySyms H r = some body)) ∧ w = 1 ∧
      ((H.isLeft c = true ∧ o = .start c ∧ dest = .entry c m) ∨
       (H.isLeft c = false ∧ o = .entry c m ∧ dest = .cfin c)) ∨
    (groupRule? r = none ∧ ∃ i y, r[i]? = some (.n y) ∧ w ≠ 0 ∧
      ((H.isLeft c = true ∧ epsCtx H (r.take i) = some w ∧ bodySyms H (r.drop (i + 1)) = some body ∧
          o = .entry c y ∧ dest = .entry c m) ∨
       (H.isLeft c = false ∧ epsCtx H (r.drop (i + 1)) = some w ∧ bodySyms H (r.take i) = some body ∧
          o = .entry c m ∧ dest = .entry c y))) := by
  unfold ruleNfa at hn
  cases hg : groupRule? r with
  | some t =>
    obtain ⟨o', inner, cl⟩ := t
    simp only [hg] at hn
    left
    cases hl : H.isLeft c <;> simp only [hl] at hn <;> simp at hn <;> obtain ⟨rfl, rfl, rfl, rfl⟩ := hn <;>
      simp
  | none =>
    simp only [hg] at hn
    cases hs : sameIdx H c r with
    | nil =>
      simp only [hs] at hn
      cases hb : bodySyms H r with
      | none => simp [hb] at hn
      | some b =>
        simp only [hb] at hn
        left
        cases hl : H.isLeft c <;> simp only [hl] at hn <;> simp at hn <;> obtain ⟨rfl, rfl, rfl, rfl⟩ := hn <;>
          simp
    | cons i rest =>
      cases rest with
      | cons _ _ => simp [hs] at hn
      | nil =>
        obtain ⟨y, hy⟩ := sameIdx_mem (H := H) (c := c) (r := r) (i := i) (by rw [hs]; simp)
        simp only [hs, hy] at hn
        right
        refine ⟨rfl, i, y, hy, ?_⟩
        cases hl : H.isLeft c
        · simp only [hl] at hn
          cases he : epsCtx H (r.drop (i + 1)) with
          | none => simp [he] at hn
          | some w' =>
            cases hb : bodySyms H (r.take i) with
            | none => simp [he, hb] at hn
            | some b =>
              simp only [he, hb] at hn
              by_cases h0 : w' = 0
              · simp [h0] at hn
              · simp only [h0] at hn; simp at hn
                obtain ⟨rfl, rfl, rfl, rfl⟩ := hn
                exact ⟨h0, Or.inr ⟨rfl, rfl, rfl, rfl, rfl⟩⟩
        · simp only [hl] at hn
          cases he : epsCtx H (r.take i) with
          | none => simp [he] at hn
          | some w' =>
            cases hb : bodySyms H (r.drop (i + 1)) with
            | none => simp [he, hb] at hn
            | some b =>
              simp only [he, hb] at hn
              by_cases h0 : w' = 0
              · simp [h0] at hn
              · simp only [h0] at hn; simp at hn
                obtain ⟨rfl, rfl, rfl, rfl⟩ := hn
                exact ⟨h0, Or.inl ⟨rfl, rfl, rfl, rfl, rfl⟩⟩

/-- The shapes of a rule that compiles to nothing. -/
theorem ruleNfa_dead {H : HFacts} {c m : Nat} {r : List Sym} (hn : ruleNfa H c m r = .dead) :
    groupRule? r = none ∧ (bodySyms H r = none ∨ ∃ i y, r[i]? = some (.n y) ∧
      ((H.isLeft c = true ∧ ∃ w, epsCtx H (r.take i) = some w ∧ (w = 0 ∨ bodySyms H (r.drop (i + 1)) = none)) ∨
       (H.isLeft c = false ∧ ∃ w, epsCtx H (r.drop (i + 1)) = some w ∧ (w = 0 ∨ bodySyms H (r.take i) = none)))) := by
  unfold ruleNfa at hn
  cases hg : groupRule? r with
  | some t =>
    obtain ⟨o', inner, cl⟩ := t
    simp only [hg] at hn
    cases hl : H.isLeft c <;> simp [hl] at hn
  | none =>
    simp only [hg] at hn
    refine ⟨rfl, ?_⟩
    cases hs : sameIdx H c r with
    | nil =>
      simp only [hs] at hn
      cases hb : bodySyms H r with
      | none => exact Or.inl rfl
      | some b => simp only [hb] at hn; cases hl : H.isLeft c <;> simp [hl] at hn
    | cons i rest =>
      cases rest with
      | cons _ _ => simp [hs] at hn
      | nil =>
        obtain ⟨y, hy⟩ := sameIdx_mem (H := H) (c := c) (r := r) (i := i) (by rw [hs]; simp)
        simp only [hs, hy] at hn
        right
        refine ⟨i, y, hy, ?_⟩
        cases hl : H.isLeft c
        · simp only [hl] at hn
          refine Or.inr ⟨rfl, ?_⟩
          cases he : epsCtx H (r.drop (i + 1)) with
          | none => simp [he] at hn
          | some w' =>
            refine ⟨w', rfl, ?_⟩
            cases hb : bodySyms H (r.take i) with
            | none => exact Or.inr rfl
            | some b =>
              simp only [he, hb] at hn
              by_cases h0 : w' = 0
              · exact Or.inl h0
              · simp [h0] at hn
        · simp only [hl] at hn
          refine Or.inl ⟨rfl, ?_⟩
          cases he : epsCtx H (r.take i) with
          | none => simp [he] at hn
          | some w' =>
            refine ⟨w', rfl, ?_⟩
            cases hb : bodySyms H (r.drop (i + 1)) with
            | none => exact Or.inr rfl
            | some b =>
              simp only [he, hb] at hn
              by_cases h0 : w' = 0
              · exact Or.inl h0
              · simp [h0] at hn

def Rk (cn : Nat → List Item → S) : UKey → List Item → S
  | .entry _ y => cn y
  | _ => delta

section
variable (H : HFacts) (M : Model) (fI : Array (Option Nat)) (cn : Nat → List Item → S)
  (hne : ∀ y, H.isNe y = true → ∀ v, cn y v ≤ DW (H.dfa (H.langOf y)) (wtM M fI) 0 v)
  (heps : ∀ y, H.isNe y = false → ∀ v, cn y v ≤ if v.isEmpty then H.epsOf y else 0)
  (hfrag : ∀ inner v, cntInner cn inner v ≤ fragW M fI inner v)
include hne heps hfrag

theorem group_bound {r : List Sym} {o : Tok} {inner : Option Nat} {cl : Tok}
    (hg : groupRule? r = some (o, inner, cl)) (u : List Item) :
    cntRule cn r u ≤ bodyCnt H M fI [.call o inner cl] u := by
  simp only [cntRule, hg, bodyCnt]
  rw [conv_delta_right]
  split
  · rename_i o' v c'
    simp only [symCnt]
    by_cases h : o = o' ∧ cl = c'
    · rw [if_pos h, if_pos h]; exact hfrag _ _
    · rw [if_neg h]; exact S.zero_le _
  · exact S.zero_le _

theorem plain_bound {r : List Sym} {body : List CSym} (hg : groupRule? r = none) (hb : bodySyms H r = some body)
    (u : List Item) : cntRule cn r u ≤ bodyCnt H M fI body u := by
  have hcr : cntRule cn r u = cntSeq cn r u := by simp [cntRule, hg]
  rw [hcr]
  have := seq_body H M fI cn hne heps r body hb [] u
  rwa [List.append_nil, cntSeq_nil, conv_delta_right] at this

/-- A right-linear rule: its body, then the same-component symbol (or nothing). -/
theorem rule_right {c m : Nat} {r : List Sym} (hl : H.isLeft c = false) {o : UKey} {body : List CSym}
    {dest : UKey} {w : S} (hn : ruleNfa H c m r = .edge o body dest w) (u : List Item) :
    cntRule cn r u ≤ w * conv (bodyCnt H M fI body) (Rk cn dest) u := by
  rcases ruleNfa_edge hn with ⟨hshape, rfl, hor⟩ | ⟨hg, i, y, hy, _, hcase⟩
  · have hd : dest = .cfin c := by
      rcases hor with ⟨h, _⟩ | ⟨_, _, h⟩
      · rw [hl] at h; cases h
      · exact h
    subst hd
    rw [S.one_mul]; simp only [Rk]; rw [conv_delta_right]
    rcases hshape with ⟨o', inner, cl, hg, rfl⟩ | ⟨hg, hb⟩
    · exact group_bound H M fI cn hne heps hfrag hg u
    · exact plain_bound H M fI cn hne heps hfrag hg hb u
  · rcases hcase with ⟨h, _⟩ | ⟨_, hw, hb, _, rfl⟩
    · rw [hl] at h; cases h
    have hcr : cntRule cn r u = cntSeq cn r u := by simp [cntRule, hg]
    rw [hcr]; simp only [Rk]; rw [← conv_smul_right, split_at hy]
    refine S.le_trans (seq_body H M fI cn hne heps _ body hb _ u) (conv_mono (fun _ => S.le_refl _) ?_ u)
    intro v
    rw [cntSeq_n]
    have he := fun v' => seq_eps H cn heps _ w hw [] v'
    simp only [List.append_nil] at he
    refine S.le_trans (conv_mono (fun _ => S.le_refl _) he v) ?_
    rw [conv_smul_right, cntSeq_nil, conv_delta_right]
    exact S.le_refl _

/-- A left-linear rule: the same-component symbol (or nothing), then its body. -/
theorem rule_left {c m : Nat} {r : List Sym} (hl : H.isLeft c = true) {o : UKey} {body : List CSym}
    {dest : UKey} {w : S} (hn : ruleNfa H c m r = .edge o body dest w) (u : List Item) :
    cntRule cn r u ≤ w * conv (Rk cn o) (bodyCnt H M fI body) u := by
  rcases ruleNfa_edge hn with ⟨hshape, rfl, hor⟩ | ⟨hg, i, y, hy, _, hcase⟩
  · have ho : o = .start c := by
      rcases hor with ⟨_, h, _⟩ | ⟨h, _⟩
      · exact h
      · rw [hl] at h; cases h
    subst ho
    rw [S.one_mul]; simp only [Rk]; rw [conv_delta_left]
    rcases hshape with ⟨o', inner, cl, hg, rfl⟩ | ⟨hg, hb⟩
    · exact group_bound H M fI cn hne heps hfrag hg u
    · exact plain_bound H M fI cn hne heps hfrag hg hb u
  · rcases hcase with ⟨_, hw, hb, rfl, _⟩ | ⟨h, _⟩
    · have hcr : cntRule cn r u = cntSeq cn r u := by simp [cntRule, hg]
      rw [hcr]; simp only [Rk]; rw [split_at hy]
      refine S.le_trans (seq_eps H cn heps _ w hw _ u) (S.mul_le_mul (S.le_refl _) ?_)
      rw [cntSeq_n]
      refine conv_mono (fun _ => S.le_refl _) (fun v => ?_) u
      have := seq_body H M fI cn hne heps _ body hb [] v
      rwa [List.append_nil, cntSeq_nil, conv_delta_right] at this
    · rw [hl] at h; cases h

/-- A dead rule derives nothing. -/
theorem rule_dead {c m : Nat} {r : List Sym} (hn : ruleNfa H c m r = .dead) (u : List Item) :
    cntRule cn r u = 0 := by
  apply S.le_antisymm _ (S.zero_le _)
  obtain ⟨hg, hcase⟩ := ruleNfa_dead hn
  have hcr : cntRule cn r u = cntSeq cn r u := by simp [cntRule, hg]
  rw [hcr]
  rcases hcase with hb | ⟨i, y, hy, hcase⟩
  · have := seq_dead H cn heps r hb [] u
    rw [List.append_nil] at this; rw [this]; exact S.le_refl _
  rw [split_at hy]
  rcases hcase with ⟨_, w, hw, h0 | hb⟩ | ⟨_, w, hw, h0 | hb⟩
  · subst h0
    refine S.le_trans (seq_eps H cn heps _ 0 hw _ u) ?_
    rw [S.zero_mul]; exact S.le_refl _
  · refine S.le_trans (seq_eps H cn heps _ w hw _ u) ?_
    rw [cntSeq_n]
    have : conv (cn y) (cntSeq cn (r.drop (i + 1))) u = 0 := by
      unfold conv; apply sumL_zero; intro p _
      have := seq_dead H cn heps _ hb [] p.2
      rw [List.append_nil] at this; rw [this, S.mul_zero]
    rw [this, S.mul_zero]; exact S.le_refl _
  · subst h0
    have hz : ∀ v, cntSeq cn (.n y :: r.drop (i + 1)) v = 0 := fun v => by
      rw [cntSeq_n]
      have he := fun v' => seq_eps H cn heps _ 0 hw [] v'
      simp only [List.append_nil, S.zero_mul] at he
      unfold conv; apply sumL_zero; intro p _
      rw [S.le_antisymm (he p.2) (S.zero_le _), S.mul_zero]
    cases hb' : bodySyms H (r.take i) with
    | none =>
      rw [seq_dead H cn heps _ hb' _ u]; exact S.le_refl _
    | some body =>
      refine S.le_trans (seq_body H M fI cn hne heps _ body hb' _ u) ?_
      unfold conv
      rw [sumL_zero _ fun p _ => by rw [hz, S.mul_zero]]
      exact S.le_refl _
  · rw [seq_dead H cn heps _ hb _ u]; exact S.le_refl _

end

end Ambiguity

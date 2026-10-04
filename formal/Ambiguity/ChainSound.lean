import Ambiguity.Conv

/-!
# Forward lower bounds: DFA copies and chains

A copy of a library DFA followed by a continuation, and a chain reading a
rule body followed by a continuation, count at least the convolution of
what they read with what the continuation counts.
-/

namespace Ambiguity

theorem fe_le_Wsup (M : Model) {t : Nat} {e : Edge} (he : e ∈ M.out t) (u : List Item) (z : Nat) :
    fe M (Wsup M) (Wsup M) u z e ≤ Wsup M t u z :=
  S.le_trans (le_sumL he _) (S.le_trans (S.le_add_left _ _) (Wsup_fwd M t u z))

theorem edgesOk_mem {keys : Array UKey} {fI : Array (Option Nat)} {spec : List SEdge} {es : List Edge}
    (h : edgesOk keys fI spec es = true) {s : SEdge} (hs : s ∈ spec) : ∃ e ∈ es, edgeOk keys fI s e = true := by
  unfold edgesOk at h
  simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at h
  obtain ⟨hl, hz⟩ := h
  obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem hs
  have hi' : i < es.length := hl ▸ hi
  have hm : (spec[i], es[i]) ∈ spec.zip es := by
    rw [List.mem_iff_getElem]; exact ⟨i, by simp; omega, by simp⟩
  exact ⟨es[i], List.getElem_mem hi', hz _ hm⟩

theorem conv_sum_left {α} (l : List α) (a : α → S) (f : α → List Item → S) (g : List Item → S) (u : List Item) :
    conv (fun v => sumL l fun p => a p * f p v) g u = sumL l fun p => a p * conv (f p) g u := by
  induction l with
  | nil => simp only [sumL_nil]; unfold conv; apply sumL_zero; intro p _; simp
  | cons p l ih =>
    simp only [sumL_cons]
    rw [conv_add_left, conv_smul_left, ih]

/-- What one chain symbol reads. -/
noncomputable def symCnt (H : HFacts) (M : Model) (fI : Array (Option Nat)) : CSym → List Item → S
  | .term a => fun v => match v with
    | [.tok b] => if a = b then 1 else 0
    | _ => 0
  | .call o inner c => fun v => match v with
    | [.grp o' w c'] => if o = o' ∧ c = c' then fragW M fI inner w else 0
    | _ => 0
  | .low y => DW (H.dfa (H.langOf y)) (wtM M fI) 0
  | .w2 => fun v => if v.isEmpty then 2 else 0

noncomputable def bodyCnt (H : HFacts) (M : Model) (fI : Array (Option Nat)) : List CSym → List Item → S
  | [] => delta
  | s :: rest => conv (symCnt H M fI s) (bodyCnt H M fI rest)

theorem conv_one (f : List Item → S) (g : List Item → S) (hf : ∀ v, v.length ≠ 1 → f v = 0) :
    ∀ u, conv f g u = match u with
      | x :: u' => f [x] * g u'
      | [] => 0 := by
  intro u
  cases u with
  | nil => rw [conv_nil, hf [] (by simp), S.zero_mul]
  | cons x u =>
    rw [conv_cons, hf [] (by simp), S.zero_mul, S.zero_add]
    cases u with
    | nil => rw [conv_nil]
    | cons y u =>
      rw [conv_cons]
      have : conv (fun v => f (x :: y :: v)) g u = 0 := by
        unfold conv; apply sumL_zero; intro p _
        show f (x :: y :: p.1) * g p.2 = 0
        rw [hf _ (by simp), S.zero_mul]
      rw [this, S.add_zero]

section
variable (H : HFacts) (E : PGrammar) (keys : Array UKey) (fI : Array (Option Nat)) (M : Model)
variable (hU : checkUniverse H E keys fI M = true)
include hU

/-- A DFA copy followed by a continuation. -/
theorem comp_splits (lid tail z : Nat) (F : List Item → S) (hF : ∀ v, F v ≤ Wsup M tail v z) :
    ∀ (u : List Item) (d j : Nat), keys[j]? = some (.comp lid d tail) →
      conv (DW (H.dfa lid) (wtM M fI) d) F u ≤ Wsup M j u z := by
  have hnd := (universe_parts H E keys fI M hU).2.2.2.2.1
  intro u
  induction u with
  | nil =>
    intro d j hj
    have he := edges_of_key H E keys fI M hU hj
    rw [conv_nil]
    refine S.le_trans ?_ (S.le_trans (S.le_add_left _ _) (Wsup_fwd M j [] z))
    simp only [DW]
    let g : SEdge → S := fun s => match s with
      | .eps (.id t) w => if t = tail then w * Wsup M tail [] z else 0
      | _ => 0
    refine S.le_trans ?_ (edgesOk_sum keys fI he g _ ?_)
    · simp only [specEdges]
      by_cases ha : (H.dfa lid).accAt d = 0
      · simp [ha]
      · simp only [ha, ite_false, sumL_append, sumL_cons, sumL_nil, S.add_zero]
        refine S.le_trans ?_ (S.le_add_right _ _)
        simp only [g, ite_true]
        exact S.mul_le_mul (S.le_refl _) (hF [])
    · intro s e hse
      cases s with
      | eps t w =>
        cases t with
        | id t =>
          cases e with
          | eps t' w' =>
            simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hse
            obtain ⟨rfl, rfl⟩ := hse
            simp only [g, fe]
            split <;> simp_all
          | _ => simp [edgeOk] at hse
        | _ => exact S.zero_le _
      | _ => exact S.zero_le _
  | cons x u ih =>
    intro d j hj
    have he := edges_of_key H E keys fI M hU hj
    rw [conv_cons]
    refine S.le_trans ?_ (Wsup_fwd M j (x :: u) z)
    simp only [DW]
    rw [conv_sum_left]
    let g : SEdge → S := fun s => match s with
      | .eps (.id t) w => if t = tail then w * Wsup M tail (x :: u) z else 0
      | .int a (.key (.comp lid' d' tail')) =>
        if lid' = lid ∧ tail' = tail then wtM M fI (.t a) x * conv (DW (H.dfa lid) (wtM M fI) d') F u else 0
      | .call o inner (.key (.comp lid' d' tail')) c =>
        if lid' = lid ∧ tail' = tail then
          wtM M fI (.call o inner c) x * conv (DW (H.dfa lid) (wtM M fI) d') F u else 0
      | _ => 0
    refine S.le_trans ?_ (S.le_trans (edgesOk_sum keys fI he g _ ?_) (S.le_add_left _ _))
    · simp only [specEdges, sumL_append, sumL_map]
      refine S.add_le_add ?_ ?_
      · by_cases ha : (H.dfa lid).accAt d = 0
        · simp [ha]
        · simp only [ha, ite_false, sumL_cons, sumL_nil, S.add_zero, g, ite_true]
          exact S.mul_le_mul (S.le_refl _) (hF _)
      · apply sumL_le_sumL
        intro p _
        obtain ⟨a, d'⟩ := p
        cases a <;> simp [g]
    · intro s e hse
      cases s with
      | eps t w =>
        cases t with
        | id t =>
          cases e with
          | eps t' w' =>
            simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hse
            obtain ⟨rfl, rfl⟩ := hse
            simp only [g, fe]
            split <;> simp_all
          | _ => simp [edgeOk] at hse
        | _ => exact S.zero_le _
      | int a t =>
        cases t with
        | key k =>
          cases k with
          | comp lid' d' tail' =>
            cases e with
            | int a' t' =>
              simp only [edgeOk, tgtOk, Bool.and_eq_true, beq_iff_eq] at hse
              obtain ⟨rfl, ht⟩ := hse
              simp only [g, fe]
              split
              · rename_i hlt
                obtain ⟨rfl, rfl⟩ := hlt
                cases x with
                | grp _ _ _ => simp [wtM]
                | tok b =>
                  simp only [wtM]
                  split
                  · rw [S.one_mul]; exact ih d' t' ht
                  · simp
              · exact S.zero_le _
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
              simp only [g, fe]
              split
              · rename_i hlt
                obtain ⟨rfl, rfl⟩ := hlt
                cases x with
                | tok _ => simp [wtM]
                | grp o'' v c'' =>
                  simp only [wtM]
                  split
                  · rw [fragW_eq M fI hnd hf v]
                    exact S.mul_le_mul (S.le_refl _) (ih d' t' ht)
                  · simp
              · exact S.zero_le _
            | _ => simp [edgeOk] at hse
          | _ => exact S.zero_le _
        | _ => exact S.zero_le _

end

theorem conv_at_nil (f g : List Item → S) (hf : ∀ v, v ≠ [] → f v = 0) (u : List Item) :
    conv f g u = f [] * g u := by
  cases u with
  | nil => rw [conv_nil]
  | cons x u =>
    rw [conv_cons]
    have : conv (fun v => f (x :: v)) g u = 0 := by
      unfold conv; apply sumL_zero; intro p _
      show f (x :: p.1) * g p.2 = 0
      rw [hf _ (by simp), S.zero_mul]
    rw [this, S.add_zero]

theorem tgtOk_comp0 {keys : Array UKey} {lid : Nat} {T : Tgt} {t : Nat} (h : tgtOk keys (.comp0 lid T) t = true) :
    ∃ j, keys[t]? = some (.comp lid 0 j) ∧ tgtOk keys T j = true := by
  unfold tgtOk at h
  split at h
  · rename_i lid' d j hk
    simp only [Bool.and_eq_true, beq_iff_eq] at h
    obtain ⟨⟨rfl, rfl⟩, h⟩ := h
    exact ⟨j, hk, h⟩
  · cases h

section
variable (H : HFacts) (E : PGrammar) (keys : Array UKey) (fI : Array (Option Nat)) (M : Model)
variable (hU : checkUniverse H E keys fI M = true)
include hU

/-- One body symbol read forward along its edge. -/
theorem sym_fwd (s : CSym) (T : Tgt) (z : Nat) (R : List Item → S)
    (hR : ∀ t', tgtOk keys T t' = true → ∀ v, R v ≤ Wsup M t' v z)
    {t : Nat} {e : Edge} (he : e ∈ M.out t) (hok : edgeOk keys fI (symEdge H s T) e = true) (u : List Item) :
    conv (symCnt H M fI s) R u ≤ Wsup M t u z := by
  have hnd := (universe_parts H E keys fI M hU).2.2.2.2.1
  refine S.le_trans ?_ (fe_le_Wsup M he u z)
  cases s with
  | term a =>
    cases e with
    | int a' t' =>
      simp only [symEdge, edgeOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨rfl, ht⟩ := hok
      rw [conv_one _ _ (fun v hv => by
        simp only [symCnt]; split
        · simp at hv
        · rfl) u]
      cases u with
      | nil => exact S.zero_le _
      | cons x u =>
        cases x with
        | grp _ _ _ => simp [symCnt]
        | tok b =>
          simp only [symCnt, fe]
          split
          · rw [S.one_mul]; exact hR t' ht u
          · simp
    | _ => simp [symEdge, edgeOk] at hok
  | call o inner c =>
    cases e with
    | call o' f t' c' =>
      simp only [symEdge, edgeOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨⟨⟨rfl, rfl⟩, hf⟩, ht⟩ := hok
      rw [conv_one _ _ (fun v hv => by
        simp only [symCnt]; split
        · simp at hv
        · rfl) u]
      cases u with
      | nil => exact S.zero_le _
      | cons x u =>
        cases x with
        | tok _ => simp [symCnt]
        | grp o'' v c'' =>
          simp only [symCnt, fe]
          split
          · rw [fragW_eq M fI hnd hf v]
            exact S.mul_le_mul (S.le_refl _) (hR t' ht u)
          · simp
    | _ => simp [symEdge, edgeOk] at hok
  | low y =>
    cases e with
    | eps t0 w =>
      simp only [symEdge, edgeOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨rfl, ht⟩ := hok
      obtain ⟨j, hk, hj⟩ := tgtOk_comp0 ht
      simp only [symCnt, fe, S.one_mul]
      exact comp_splits H E keys fI M hU _ j z R (hR j hj) u 0 t0 hk
    | _ => simp [symEdge, edgeOk] at hok
  | w2 =>
    cases e with
    | eps t' w =>
      simp only [symEdge, edgeOk, Bool.and_eq_true, beq_iff_eq] at hok
      obtain ⟨rfl, ht⟩ := hok
      rw [conv_at_nil _ _ (fun v hv => by simp [symCnt, hv]) u]
      simp only [symCnt, fe, List.isEmpty_nil, ite_true]
      exact S.mul_le_mul (S.le_refl _) (hR t' ht u)
    | _ => simp [symEdge, edgeOk] at hok

/-- A chain reading a rule body forward, then the continuation. -/
theorem chain_fwd (c : Nat) (dest : UKey) (z : Nat) (R : List Item → S)
    (hR : ∀ j, keys[j]? = some dest → ∀ v, R v ≤ Wsup M j v z) :
    ∀ (body : List CSym) (t : Nat), tgtOk keys (chainTgt c body dest) t = true →
      ∀ u, conv (bodyCnt H M fI body) R u ≤ Wsup M t u z
  | [], t, ht, u => by
    simp only [chainTgt, List.isEmpty_nil, ite_true, tgtOk, beq_iff_eq] at ht
    rw [bodyCnt, conv_delta_left]
    exact hR t ht u
  | s :: rest, t, ht, u => by
    simp only [chainTgt, List.isEmpty_cons, Bool.false_eq_true, ite_false, tgtOk, beq_iff_eq] at ht
    have hes := edges_of_key H E keys fI M hU ht
    obtain ⟨e, he, hok⟩ := edgesOk_mem hes (s := symEdge H s (chainTgt c rest dest)) (by simp [specEdges])
    rw [bodyCnt, ← conv_assoc]
    exact sym_fwd H E keys fI M hU s _ z _ (fun t' ht' v => chain_fwd c dest z R hR rest t' ht' v) he hok u

end

end Ambiguity

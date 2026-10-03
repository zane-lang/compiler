import Ambiguity.RuleSound

/-!
# Soundness of the horizontal compilation

Every derivation count of the plain grammar is bounded by the universe
model: a symbol that derives only the empty word by its empty count, a
nonempty symbol by its NFA, a fragment interior by the fragment. At the root
fragment this is the counted model's root, which the certificate bounds by 1.
-/

namespace Ambiguity

/-! ## Symbols deriving only the empty word -/

theorem foldl_mul (f : Sym → S) : ∀ (l : List Sym) (a : S),
    l.foldl (fun acc s => acc * f s) a = a * l.foldl (fun acc s => acc * f s) 1
  | [], a => by simp
  | s :: l, a => by
    simp only [List.foldl_cons]
    rw [foldl_mul f l (a * f s), foldl_mul f l (1 * f s), S.one_mul, S.mul_assoc]

theorem epsCtx_all (H : HFacts) : ∀ (r : List Sym), (∀ s ∈ r, ∃ y, s = .n y ∧ H.isNe y = false) →
    epsCtx H r = some (r.foldl (fun acc s => acc * match s with | .n y => H.epsOf y | _ => 0) 1)
  | [], _ => by simp [epsCtx]
  | s :: r, h => by
    obtain ⟨y, rfl, hy⟩ := h s (List.mem_cons_self ..)
    simp only [epsCtx, hy, Bool.false_eq_true, ite_false]
    rw [epsCtx_all H r (fun s hs => h s (List.mem_cons_of_mem _ hs))]
    simp only [Option.map_eq_map, Option.map_some, List.foldl_cons, S.one_mul]
    rw [foldl_mul _ r (H.epsOf y)]

theorem facts_rule {H : HFacts} {E : PGrammar} (hF : checkFacts H E = true) {x : Nat} {r : List Sym}
    (hr : r ∈ E.rulesOf x) :
    ((groupRule? r).isSome = true ∨ r.any (fun | .t _ => true | .n y => H.isNe y) = true → H.isNe x = true) ∧
    ((groupRule? r).isSome = true ∨ hasBracket r = false) ∧
    (H.isNe x = true → (H.mems (H.compOf x)).contains x = true ∧
      (match ruleNfa H (H.compOf x) x r with | .bad => false | _ => true) = true) := by
  have hx : x < E.rules.size := by
    rcases Nat.lt_or_ge x E.rules.size with h | h; exact h
    simp [PGrammar.rulesOf, Array.getD, Nat.not_lt.mpr h] at hr
  unfold checkFacts at hF
  have := List.all_eq_true.mp (List.all_eq_true.mp hF x (List.mem_range.mpr hx)) r hr
  simp only [Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true', decide_eq_true_eq] at this
  obtain ⟨⟨h1, h2⟩, h3⟩ := this
  refine ⟨h1, ?_, fun hn => ?_⟩
  · rcases h2 with h | h
    · exact Or.inl h
    · exact Or.inr h
  · rcases h3 with h | ⟨⟨h, h'⟩, _⟩
    · rw [hn] at h; cases h
    · exact ⟨h, h'⟩

theorem eps_rule {H : HFacts} {E : PGrammar} (hF : checkFacts H E = true) {x : Nat} (hx : H.isNe x = false)
    {r : List Sym} (hr : r ∈ E.rulesOf x) :
    groupRule? r = none ∧ ∀ s ∈ r, ∃ y, s = .n y ∧ H.isNe y = false := by
  have h1 := (facts_rule hF hr).1
  have hg : groupRule? r = none := by
    cases hg : groupRule? r with
    | none => rfl
    | some _ => have := h1 (Or.inl (by simp [hg])); rw [hx] at this; cases this
  refine ⟨hg, fun s hs => ?_⟩
  cases s with
  | t a =>
    have := h1 (Or.inr (List.any_eq_true.mpr ⟨_, hs, rfl⟩)); rw [hx] at this; cases this
  | n y =>
    refine ⟨y, rfl, ?_⟩
    cases hy : H.isNe y with
    | false => rfl
    | true =>
      have := h1 (Or.inr (List.any_eq_true.mpr ⟨_, hs, by simp [hy]⟩)); rw [hx] at this; cases this

theorem eps_sum {H : HFacts} {E : PGrammar} (hE : checkEps H E = true) {x : Nat} (hx : H.isNe x = false) :
    sumL (E.rulesOf x) (fun r => r.foldl (fun acc s => acc * match s with | .n y => H.epsOf y | _ => 0) 1) ≤
      H.epsOf x := by
  by_cases hxs : x < E.rules.size
  · unfold checkEps at hE
    have := List.all_eq_true.mp hE x (List.mem_range.mpr hxs)
    simp only [hx, Bool.false_or, decide_eq_true_eq] at this
    exact this
  · simp [PGrammar.rulesOf, Array.getD, hxs]

/-- A symbol without a nonempty derivation derives the empty word at most
its empty count. -/
theorem eps_bound {H : HFacts} {E : PGrammar} (hF : checkFacts H E = true) (hE : checkEps H E = true) :
    ∀ n x, H.isNe x = false → ∀ v, cnt E n x v ≤ if v.isEmpty then H.epsOf x else 0
  | 0, _, _, _ => S.zero_le _
  | n + 1, x, hx, v => by
    simp only [cnt]
    let w := fun (r : List Sym) => r.foldl (fun acc s => acc * match s with | .n y => H.epsOf y | _ => 0) 1
    have hr : ∀ r ∈ E.rulesOf x, cntRule (cnt E n) r v ≤ w r * delta v := by
      intro r hr
      obtain ⟨hg, hall⟩ := eps_rule hF hx hr
      have hcr : cntRule (cnt E n) r v = cntSeq (cnt E n) r v := by simp [cntRule, hg]
      rw [hcr]
      have := seq_eps H (cnt E n) (fun y hy v => eps_bound hF hE n y hy v) r (w r) (epsCtx_all H r hall) [] v
      rwa [List.append_nil] at this
    refine S.le_trans (sumL_le_sumL _ hr) ?_
    rw [← sumL_mul]
    refine S.le_trans (S.mul_le_mul (eps_sum hE hx) (S.le_refl _)) ?_
    cases v <;> simp [delta]

/-! ## Entries of right-linear components -/

theorem sumL_zipIdx {α} (f : α → S) : ∀ (l : List α) (n : Nat), sumL (l.zipIdx n) (fun p => f p.1) = sumL l f
  | [], _ => rfl
  | a :: l, n => by simp only [List.zipIdx_cons, sumL_cons, sumL_zipIdx f l (n + 1)]

theorem mem_zipIdx_rules {l : List (List Sym)} {p : List Sym × Nat} (h : p ∈ l.zipIdx) : p.1 ∈ l := by
  have := List.mk_mem_zipIdx_iff_getElem?.mp (show (p.1, p.2) ∈ l.zipIdx from h)
  exact List.mem_of_getElem? this

theorem edgesOk_sum_mem {keys : Array UKey} {fI : Array (Option Nat)} {spec : List SEdge} {es : List Edge}
    (h : edgesOk keys fI spec es = true) (g : SEdge → S) (f : Edge → S)
    (hg : ∀ s ∈ spec, ∀ e, edgeOk keys fI s e = true → g s ≤ f e) :
    sumL spec g ≤ sumL es f := by
  unfold edgesOk at h
  simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at h
  obtain ⟨hl, hz⟩ := h
  induction spec generalizing es with
  | nil => exact S.zero_le _
  | cons s spec ih =>
    cases es with
    | nil => simp at hl
    | cons e es =>
      simp only [sumL_cons]
      exact S.add_le_add (hg s (List.mem_cons_self ..) e (hz (s, e) (by simp)))
        (ih (fun s' hs' e' he' => hg s' (List.mem_cons_of_mem _ hs') e' he') (by simpa using hl)
          (fun p hp => hz p (by simp [hp])))

theorem delta_le (M : Model) (t : Nat) (v : List Item) : delta v ≤ Wsup M t v t := by
  cases v with
  | nil => exact S.le_trans (by simp [delta, base]) (Wsup_ge_base M t [] t)
  | cons _ _ => simp [delta]

theorem compEdges_mem {H : HFacts} {E : PGrammar} {c : Nat} {o : UKey} {sp : SEdge}
    (h : (o, sp) ∈ compEdges H E c) : ∃ m ∈ H.mems c, ∃ r i, (E.rulesOf m)[i]? = some r ∧
      ∃ body dest w, ruleNfa H c m r = .edge o body dest w ∧
        sp = (if H.isLeft c then .eps (.key (.rpos c m i 0)) w else .eps (chainTgt c body dest) w) := by
  unfold compEdges at h
  obtain ⟨m, hm, h⟩ := List.mem_flatMap.mp h
  obtain ⟨⟨r, i⟩, hp, he⟩ := List.mem_filterMap.mp h
  refine ⟨m, hm, r, i, List.mk_mem_zipIdx_iff_getElem?.mp hp, ?_⟩
  cases hn : ruleNfa H c m r with
  | edge o' body dest w =>
    simp only [hn] at he
    refine ⟨body, dest, w, ?_⟩
    cases hl : H.isLeft c <;> simp only [hl, Bool.false_eq_true, ite_false, ite_true, Option.some.injEq,
      Prod.mk.injEq] at he <;> obtain ⟨rfl, rfl⟩ := he <;> simp
  | dead => simp [hn] at he
  | bad => simp [hn] at he

section
variable (H : HFacts) (E : PGrammar) (keys : Array UKey) (fI : Array (Option Nat)) (M : Model)
variable (hU : checkUniverse H E keys fI M = true)
variable (idx : Std.HashMap UKey Nat) (hK : checkKeys keys idx = true) (hL : checkLib H = true)
include hU hK hL

/-- The NFA entry of a right-linear member counts at least its rules. -/
theorem right_entry (cn : Nat → List Item → S)
    (hne : ∀ y, H.isNe y = true → ∀ v, cn y v ≤ DW (H.dfa (H.langOf y)) (wtM M fI) 0 v)
    (heps : ∀ y, H.isNe y = false → ∀ v, cn y v ≤ if v.isEmpty then H.epsOf y else 0)
    {c m s z : Nat} (hl : H.isLeft c = false) (hs : keys[s]? = some (.entry c m))
    (hz : keys[z]? = some (.cfin c)) (hm : m ∈ H.mems c)
    (hIH : ∀ y j, H.isNe y = true → H.compOf y = c → keys[j]? = some (.entry c y) → ∀ v, cn y v ≤ Wsup M j v z)
    (hfr : ∀ r ∈ E.rulesOf m, ∀ o inner cl, groupRule? r = some (o, inner, cl) →
      ∀ v, cntInner cn inner v ≤ fragW M fI inner v)
    (hbad : ∀ r ∈ E.rulesOf m, ruleNfa H c m r ≠ .bad) (u : List Item) :
    sumL (E.rulesOf m) (fun r => cntRule cn r u) ≤ Wsup M s u z := by
  have hes := edges_of_key H E keys fI M hU hs
  let X : Tgt → S := fun T => match T with
    | .key (.chain _ body dest) => conv (bodyCnt H M fI body) (Rk cn dest) u
    | .key k => Rk cn k u
    | _ => 0
  let g : SEdge → S := fun sp => match sp with
    | .eps T w => w * X T
    | _ => 0
  -- the continuation after a chain: the final node, or the entry of a member
  have hRdest : ∀ {r body dest w o}, r ∈ E.rulesOf m → ruleNfa H c m r = .edge o body dest w →
      ∀ j, keys[j]? = some dest → ∀ v, Rk cn dest v ≤ Wsup M j v z := by
    intro r body dest w o _ hn j hj v
    rcases ruleNfa_edge hn with ⟨_, _, hor⟩ | ⟨_, i, y, _, hyn, hyc, _, hcase⟩
    · rcases hor with ⟨h, _⟩ | ⟨_, _, rfl⟩
      · rw [hl] at h; cases h
      · have := keys_inj hK hj hz; subst this
        exact delta_le M j v
    · rcases hcase with ⟨h, _⟩ | ⟨_, _, _, _, rfl⟩
      · rw [hl] at h; cases h
      · exact hIH y j hyn hyc hj v
  have hX : ∀ {r body dest w o}, r ∈ E.rulesOf m → ruleNfa H c m r = .edge o body dest w →
      X (chainTgt c body dest) = conv (bodyCnt H M fI body) (Rk cn dest) u := by
    intro r body dest w o _ hn
    have hd : ∀ c' b d', dest ≠ .chain c' b d' := by
      intro c' b d' h; subst h
      rcases ruleNfa_edge hn with ⟨_, _, hor⟩ | ⟨_, _, _, _, _, _, _, hcase⟩
      · rcases hor with ⟨_, _, h⟩ | ⟨_, _, h⟩ <;> cases h
      · rcases hcase with ⟨_, _, _, _, h⟩ | ⟨_, _, _, _, h⟩ <;> cases h
    cases body with
    | nil =>
      simp only [chainTgt, List.isEmpty_nil, ite_true, bodyCnt]
      rw [conv_delta_left]
      cases dest with
      | chain c' b d' => exact absurd rfl (hd c' b d')
      | _ => rfl
    | cons s0 rest => rfl
  refine S.le_trans ?_ (S.le_trans (edgesOk_sum_mem hes g (fe M (Wsup M) (Wsup M) u z) ?_)
    (S.le_trans (S.le_add_left _ _) (Wsup_fwd M s u z)))
  · simp only [specEdges]
    rw [sumL_filterMap]
    unfold compEdges
    rw [sumL_flatMap]
    refine S.le_trans ?_ (le_sumL hm _)
    rw [sumL_filterMap, ← sumL_zipIdx (fun r => cntRule cn r u) _ 0]
    apply sumL_le_sumL
    intro p hp
    obtain ⟨r, i⟩ := p
    have hr : r ∈ E.rulesOf m := mem_zipIdx_rules hp
    simp only
    cases hn : ruleNfa H c m r with
    | dead => rw [rule_dead H M fI cn hne heps hn u]; exact S.zero_le _
    | bad => exact absurd hn (hbad r hr)
    | edge o body dest w =>
      have ho : o = .entry c m := by
        rcases ruleNfa_edge hn with ⟨_, _, hor⟩ | ⟨_, _, _, _, _, _, _, hcase⟩
        · rcases hor with ⟨h, _⟩ | ⟨_, h, _⟩
          · rw [hl] at h; cases h
          · exact h
        · rcases hcase with ⟨h, _⟩ | ⟨_, _, _, h, _⟩
          · rw [hl] at h; cases h
          · exact h
      subst ho
      simp only [hl, Bool.false_eq_true, ite_false, ite_true, g]
      rw [hX hr hn]
      exact rule_right H M fI cn hne heps (hfr r hr) hl hn u
  · intro sp hsp e hok
    simp only [specEdges] at hsp
    obtain ⟨⟨o, sp'⟩, hmem, hfilt⟩ := List.mem_filterMap.mp hsp
    split at hfilt
    · rename_i ho
      simp only [Option.some.injEq] at hfilt; subst hfilt
      obtain ⟨m', hm', r, i, hri, body, dest, w, hn, rfl⟩ := compEdges_mem hmem
      subst ho
      have hmm : m' = m := by
        rcases ruleNfa_edge hn with ⟨_, _, hor⟩ | ⟨_, _, _, _, _, _, _, hcase⟩
        · rcases hor with ⟨h, _⟩ | ⟨_, h, _⟩
          · rw [hl] at h; cases h
          · simp only [UKey.entry.injEq] at h; exact h.2.symm
        · rcases hcase with ⟨h, _⟩ | ⟨_, _, _, h, _⟩
          · rw [hl] at h; cases h
          · simp only [UKey.entry.injEq] at h; exact h.2.symm
      subst hmm
      have hr : r ∈ E.rulesOf m' := List.mem_of_getElem? hri
      simp only [hl, Bool.false_eq_true, ite_false] at hok ⊢
      cases e with
      | eps t w' =>
        simp only [edgeOk, Bool.and_eq_true, beq_iff_eq] at hok
        obtain ⟨rfl, ht⟩ := hok
        simp only [g, fe]
        rw [hX hr hn]
        exact S.mul_le_mul (S.le_refl _)
          (chain_fwd H E keys fI M hU c dest z _ (hRdest hr hn) body t ht u)
      | _ => simp [edgeOk] at hok
    · cases hfilt

end

end Ambiguity

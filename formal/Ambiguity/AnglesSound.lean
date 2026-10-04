import Ambiguity.Angles
import Ambiguity.QuotientSound

/-!
# Soundness of the angle certificate

`tauk` scans an untagged sentence left to right and decides each tag from the
previous and next tokens and the number of open generic regions. Every tree of
the tagged grammar has a yield that `tauk` reproduces from the untagged yield,
so two parses with the same untagged sentence have the same tagged sentence.
-/

namespace Ambiguity

def untag (a : Tok) : Tok :=
  if a = "GLESS" then "LESS" else if a = "GMORE" then "MORE" else a

def lastOr (w : List Tok) (pv : Tok) : Tok := w.getLast?.getD pv

/-- Tag one untagged token `a` between `pv` and `nx` with `k` open regions. -/
def tagOne (pv : Tok) (k : Nat) (nx : Tok) (a : Tok) : Tok × Nat :=
  if a = "LESS" ∧ pv = "UIDENT" ∧ nx ≠ "LPAREN" then ("GLESS", k + 1)
  else if a = "MORE" ∧ 0 < k then ("GMORE", k - 1)
  else (a, k)

def tauk : Tok → Nat → Tok → List Tok → List Tok × Nat
  | _, k, _, [] => ([], k)
  | pv, k, fol, a :: rest =>
    let bk := tagOne pv k (firstOr rest fol) a
    let ok := tauk a bk.2 fol rest
    (bk.1 :: ok.1, ok.2)

theorem firstOr_append (u₁ u₂ : List Tok) (fol : Tok) :
    firstOr (u₁ ++ u₂) fol = firstOr u₁ (firstOr u₂ fol) := by
  cases u₁ <;> simp [firstOr]

theorem lastOr_cons (a : Tok) (r : List Tok) (pv : Tok) : lastOr (a :: r) pv = lastOr r a := by
  unfold lastOr
  cases r with
  | nil => simp
  | cons b r => simp [List.getLast?_cons]

theorem lastOr_append (u₁ u₂ : List Tok) (pv : Tok) :
    lastOr (u₁ ++ u₂) pv = lastOr u₂ (lastOr u₁ pv) := by
  induction u₁ generalizing pv with
  | nil => rfl
  | cons a r ih => rw [List.cons_append, lastOr_cons, ih, lastOr_cons]

theorem tauk_append (pv : Tok) (k : Nat) (fol : Tok) (u₁ u₂ : List Tok) :
    tauk pv k fol (u₁ ++ u₂) =
      ((tauk pv k (firstOr u₂ fol) u₁).1 ++
        (tauk (lastOr u₁ pv) (tauk pv k (firstOr u₂ fol) u₁).2 fol u₂).1,
       (tauk (lastOr u₁ pv) (tauk pv k (firstOr u₂ fol) u₁).2 fol u₂).2) := by
  induction u₁ generalizing pv k with
  | nil => simp [tauk, lastOr]
  | cons a r ih =>
    simp only [List.cons_append, tauk, firstOr_append, ih, lastOr_cons]

/-! ## The counter along a rule -/

def kAfter (k : Nat) (a : Tok) : Nat :=
  if a = "GLESS" then k + 1 else if a = "GMORE" then k - 1 else k

def kEnd : Nat → List Sym → Nat
  | k, [] => k
  | k, .t a :: rest => kEnd (kAfter k a) rest
  | k, .n _ :: rest => kEnd k rest

def condK (I : Nat → Bool) : Nat → List Sym → Prop
  | _, [] => True
  | kc, .t a :: rest => (a = "MORE" → kc = 0) ∧ (a = "GMORE" → 0 < kc) ∧ condK I (kAfter kc a) rest
  | kc, .n y :: rest => (0 < kc → I y = true) ∧ condK I kc rest

theorem simOk_condK (I : Nat → Bool) (pos : Bool) (k : Nat) (hk : 0 < k ↔ pos = true) :
    ∀ (d : Nat) (rhs : List Sym), simOk I pos d rhs = true →
      condK I (k + d) rhs ∧ kEnd (k + d) rhs = k
  | d, [], h => by simp [simOk] at h; subst h; simp [condK, kEnd]
  | d, .t a :: rest, h => by
    unfold simOk at h
    by_cases h1 : a = "MORE"
    · subst h1
      simp only [ite_true, Bool.and_eq_true, Bool.not_eq_true', beq_iff_eq] at h
      obtain ⟨⟨hp, hd⟩, hr⟩ := h
      subst hd
      have : k = 0 := by rcases Nat.eq_zero_or_pos k with h0 | h0; exact h0; rw [hk.mp h0] at hp; cases hp
      subst this
      have := simOk_condK I pos 0 hk 0 rest hr
      refine ⟨⟨fun _ => rfl, fun e => absurd e (by decide), ?_⟩, ?_⟩
      · simpa [kAfter] using this.1
      · simpa [kEnd, kAfter] using this.2
    · by_cases h2 : a = "GMORE"
      · subst h2
        simp only [show ("GMORE" : Tok) ≠ "MORE" by decide, ite_false, ite_true, Bool.and_eq_true,
          decide_eq_true_eq] at h
        obtain ⟨hd, hr⟩ := h
        have := simOk_condK I pos k hk (d - 1) rest hr
        have e : k + d - 1 = k + (d - 1) := by omega
        simp only [condK, kEnd, kAfter, show ("GMORE" : Tok) ≠ "GLESS" by decide, ite_false, ite_true, e]
        exact ⟨⟨fun e => absurd e (by decide), fun _ => by omega, this.1⟩, this.2⟩
      · by_cases h3 : a = "GLESS"
        · subst h3
          simp only [show ("GLESS" : Tok) ≠ "MORE" by decide, show ("GLESS" : Tok) ≠ "GMORE" by decide,
            ite_false, ite_true] at h
          have := simOk_condK I pos k hk (d + 1) rest h
          simp only [condK, kEnd, kAfter, ite_true, ← Nat.add_assoc] at this ⊢
          exact ⟨⟨fun e => absurd e (by decide), fun e => absurd e (by decide), this.1⟩, this.2⟩
        · simp only [h1, h2, h3, ite_false] at h
          have := simOk_condK I pos k hk d rest h
          refine ⟨⟨fun e => absurd e h1, fun e => absurd e h2, ?_⟩, ?_⟩
          · simpa [kAfter, h2, h3] using this.1
          · simpa [kEnd, kAfter, h2, h3] using this.2
  | d, .n y :: rest, h => by
    unfold simOk at h
    simp only [Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true', decide_eq_true_eq] at h
    obtain ⟨hy, hr⟩ := h
    have := simOk_condK I pos k hk d rest hr
    refine ⟨⟨fun h0 => ?_, this.1⟩, this.2⟩
    rcases hy with hy | hy
    · exfalso
      simp only [Bool.or_eq_false_iff, decide_eq_false_iff_not, Nat.not_lt] at hy
      have : k = 0 := by
        rcases Nat.eq_zero_or_pos k with h0 | h0; exact h0; rw [hk.mp h0] at hy; cases hy.1
      omega
    · exact hy

/-! ## Over-approximation lemmas -/

section
variable (T : GGrammar) (S : AngleSets) (hc : checkAngles T S = true)
include hc

theorem rule_ok {x i : Nat} {r : GRule} (hr : (T.rulesOf x)[i]? = some r) (hne : r.guard ≠ []) :
    ((endseq S.fst r.rhs).all fun e => (S.fst x).contains e) = true ∧
    ((endseq S.lst r.rhs.reverse).all fun e => (S.lst x).contains e) = true ∧
    checkSeq S (S.aft x) (S.prv x) r.rhs = true ∧
    simOk S.inner false 0 r.rhs = true ∧ (!S.inner x || simOk S.inner true 0 r.rhs) = true := by
  unfold checkAngles at hc
  simp only [Bool.and_eq_true, List.all_eq_true] at hc
  have hx : x < T.rules.size := by
    refine Classical.byContradiction fun hx => ?_
    simp [GGrammar.rulesOf, Array.getD, hx] at hr
  have := hc.2 x (List.mem_range.mpr hx) r (List.mem_of_getElem? hr)
  unfold checkRuleAngles at this
  simp only [Bool.or_eq_true, List.isEmpty_iff, Bool.and_eq_true] at this
  rcases this with h | h
  · exact absurd h hne
  · exact ⟨h.1.1.1.1, h.1.1.1.2, h.1.1.2, h.1.2, by simpa [Bool.or_eq_true] using h.2⟩


end

/-! ## FIRST and LAST over-approximate the actual end tokens -/

def FIn (w : List Tok) (F : List (Option Tok)) : Prop :=
  (w = [] → none ∈ F) ∧ ∀ a, w.head? = some a → some a ∈ F

def LIn (w : List Tok) (F : List (Option Tok)) : Prop :=
  (w = [] → none ∈ F) ∧ ∀ a, w.getLast? = some a → some a ∈ F

theorem endseq_append (tbl : Nat → List (Option Tok)) : ∀ (l₁ l₂ : List Sym),
    endseq tbl (l₁ ++ l₂) = (endseq tbl l₁).filter (·.isSome) ++
      (if (endseq tbl l₁).contains none then endseq tbl l₂ else [])
  | [], l₂ => by simp [endseq]
  | .t a :: _, _ => by simp [endseq]
  | .n y :: l₁, l₂ => by
    simp only [List.cons_append, endseq]
    rw [endseq_append tbl l₁ l₂]
    by_cases h : (tbl y).contains none
    · simp only [h, ite_true, List.filter_append, List.contains_append, Bool.or_eq_true]
      by_cases h' : (endseq tbl l₁).contains none
      · simp [h', List.filter_filter]
      · simp [h', List.filter_filter]
    · simp only [h, Bool.false_eq_true, ite_false, List.append_nil, List.filter_filter,
        List.contains_append, Bool.or_false]
      have : ((tbl y).filter (·.isSome)).contains none = false := by
        simp [List.contains_iff_mem, List.mem_filter]
      simp [this]

theorem FIn_cons_t (a : Tok) (w : List Tok) (F : List (Option Tok)) (h : some a ∈ F) : FIn (a :: w) F :=
  ⟨fun e => absurd e (List.cons_ne_nil _ _), fun b hb => by simp at hb; subst hb; exact h⟩

theorem withCtx_first {w : List Tok} {F : List (Option Tok)} (h : FIn w F) {fol : Tok} {A : List Tok}
    (hf : fol ∈ A) : firstOr w fol ∈ withCtx F A := by
  unfold withCtx firstOr
  cases w with
  | nil =>
    have := h.1 rfl
    simp [hf, this]
  | cons a w =>
    have := h.2 a rfl
    simp only [List.head?_cons, Option.getD_some, List.mem_append, List.mem_filterMap, id_eq]
    exact Or.inl ⟨some a, this, rfl⟩

theorem withCtx_last {w : List Tok} {F : List (Option Tok)} (h : LIn w F) {pv : Tok} {P : List Tok}
    (hp : pv ∈ P) : lastOr w pv ∈ withCtx F P := by
  unfold withCtx lastOr
  cases hw : w.getLast? with
  | none =>
    have : w = [] := List.getLast?_eq_none_iff.mp hw
    have := h.1 this
    simp [hp, this]
  | some a =>
    have := h.2 a hw
    simp only [Option.getD_some, List.mem_append, List.mem_filterMap, id_eq]
    exact Or.inl ⟨some a, this, rfl⟩

theorem sub_of_all {F G : List (Option Tok)} (h : (F.all fun e => G.contains e) = true) :
    ∀ e ∈ F, e ∈ G := by
  intro e he
  have := List.all_eq_true.mp h e he
  exact List.contains_iff_mem.mp this

theorem endseq_mem_filter {e : Option Tok} {l : List (Option Tok)} (h : e ∈ l) (hs : e.isSome) :
    e ∈ l.filter (·.isSome) := List.mem_filter.mpr ⟨h, hs⟩

section
variable (T : GGrammar) (S : AngleSets) (hc : checkAngles T S = true)
include hc

mutual
theorem first_wf {x : Nat} {fol : Tok} {t : Tree} (h : WF T x fol t) : FIn (t.yield T x) (S.fst x) := by
  match h with
  | @WF.node _ _ _ i kids r hr hfol hs =>
    have hf := sub_of_all (rule_ok T S hc hr (List.ne_nil_of_mem hfol)).1
    have := first_wfs hs
    simp only [Tree.yield, hr]
    exact ⟨fun e => hf _ (this.1 e), fun a ha => hf _ (this.2 a ha)⟩

theorem first_wfs {rhs : List Sym} {fol : Tok} {kids : List Tree} (h : WFs T rhs fol kids) :
    FIn (rhsYield rhs (yields T (rhsNts rhs) kids)) (endseq S.fst rhs) := by
  match h with
  | .nil => exact ⟨fun _ => by simp [endseq], fun a ha => by simp [rhsYield] at ha⟩
  | @WFs.term _ a rest _ _ _ =>
    simp only [rhsNts, rhsYield, endseq]
    exact FIn_cons_t a _ _ (by simp)
  | @WFs.nt _ y rest _ k ks hk hs =>
    have ihk := first_wf hk
    have ihs := first_wfs hs
    simp only [rhsNts, yields, rhsYield, endseq]
    constructor
    · intro e
      have e1 : k.yield T y = [] := (List.append_eq_nil_iff.mp e).1
      have e2 := (List.append_eq_nil_iff.mp e).2
      have hn := ihk.1 e1
      simp [hn, ihs.1 e2]
    · intro a ha
      cases hky : k.yield T y with
      | nil =>
        rw [hky, List.nil_append] at ha
        have hn := ihk.1 hky
        simp [hn, ihs.2 a ha]
      | cons b l =>
        rw [hky] at ha; simp at ha; subst ha
        have := ihk.2 b (by rw [hky]; rfl)
        exact List.mem_append_left _ (endseq_mem_filter this rfl)
end

mutual
theorem last_wf {x : Nat} {fol : Tok} {t : Tree} (h : WF T x fol t) : LIn (t.yield T x) (S.lst x) := by
  match h with
  | @WF.node _ _ _ i kids r hr hfol hs =>
    have hf := sub_of_all (rule_ok T S hc hr (List.ne_nil_of_mem hfol)).2.1
    have := last_wfs hs
    simp only [Tree.yield, hr]
    exact ⟨fun e => hf _ (this.1 e), fun a ha => hf _ (this.2 a ha)⟩

theorem last_wfs {rhs : List Sym} {fol : Tok} {kids : List Tree} (h : WFs T rhs fol kids) :
    LIn (rhsYield rhs (yields T (rhsNts rhs) kids)) (endseq S.lst rhs.reverse) := by
  match h with
  | .nil => exact ⟨fun _ => by simp [endseq], fun a ha => by simp [rhsYield] at ha⟩
  | @WFs.term _ a rest _ ks hs =>
    have ihs := last_wfs hs
    simp only [rhsNts, rhsYield, List.reverse_cons, endseq_append]
    refine ⟨fun e => absurd e (List.cons_ne_nil _ _), fun b hb => ?_⟩
    cases hr : rhsYield rest (yields T (rhsNts rest) ks) with
    | nil =>
      rw [hr] at hb; simp at hb; subst hb
      have := ihs.1 hr
      simp [this, endseq]
    | cons c l =>
      rw [hr, List.getLast?_cons_cons] at hb
      have := ihs.2 b (by rw [hr]; exact hb)
      exact List.mem_append_left _ (endseq_mem_filter this rfl)
  | @WFs.nt _ y rest _ k ks hk hs =>
    have ihk := last_wf hk
    have ihs := last_wfs hs
    simp only [rhsNts, yields, rhsYield, List.reverse_cons, endseq_append]
    constructor
    · intro e
      have e1 := (List.append_eq_nil_iff.mp e).1
      have e2 := (List.append_eq_nil_iff.mp e).2
      have hn := ihs.1 e2
      simp [hn, endseq, ihk.1 e1]
    · intro a ha
      cases hr : rhsYield rest (yields T (rhsNts rest) ks) with
      | nil =>
        rw [hr, List.append_nil] at ha
        have hn := ihs.1 hr
        have := ihk.2 a ha
        simp [hn, endseq, this]
      | cons c l =>
        rw [hr, List.getLast?_append] at ha
        simp at ha
        have := ihs.2 a (by rw [hr]; simpa using ha)
        exact List.mem_append_left _ (endseq_mem_filter this rfl)
end

end


/-! ## The scanner reproduces every tagged yield -/

theorem untag_UIDENT {a : Tok} : untag a = "UIDENT" ↔ a = "UIDENT" := by
  unfold untag; by_cases h1 : a = "GLESS" <;> by_cases h2 : a = "GMORE" <;> simp_all

theorem untag_LPAREN {a : Tok} : untag a = "LPAREN" ↔ a = "LPAREN" := by
  unfold untag; by_cases h1 : a = "GLESS" <;> by_cases h2 : a = "GMORE" <;> simp_all

theorem firstOr_map (w : List Tok) (f : Tok) : firstOr (w.map untag) (untag f) = untag (firstOr w f) := by
  cases w <;> simp [firstOr]

theorem lastOr_map (w : List Tok) (pv : Tok) : lastOr (w.map untag) (untag pv) = untag (lastOr w pv) := by
  unfold lastOr; rw [List.getLast?_map]; cases w.getLast? <;> rfl

theorem mem_of_subsetT {P Q : List Tok} (h : subsetT P Q = true) {a : Tok} (ha : a ∈ P) : a ∈ Q := by
  unfold subsetT at h
  exact List.contains_iff_mem.mp (List.all_eq_true.mp h a ha)

theorem tag_term (S : AngleSets) (a pv nx : Tok) (kc : Nat) (P N : List Tok) (hpv : pv ∈ P) (hnx : nx ∈ N)
    (hpos : posOk S P N (.t a) = true) (hm : a = "MORE" → kc = 0) (hg : a = "GMORE" → 0 < kc) :
    tagOne (untag pv) kc (untag nx) (untag a) = (a, kAfter kc a) := by
  unfold posOk at hpos
  by_cases h1 : a = "GLESS"
  · subst h1
    simp only [ite_true, Bool.and_eq_true, Bool.not_eq_true'] at hpos
    have hp := mem_of_subsetT hpos.1 hpv
    simp at hp
    have hn : nx ≠ "LPAREN" := by
      intro e; subst e
      have := hpos.2
      rw [List.contains_iff_mem.mpr hnx] at this; cases this
    have hn' : untag nx ≠ "LPAREN" := fun e => hn (untag_LPAREN.mp e)
    subst hp
    have e1 : untag "GLESS" = "LESS" := by simp [untag]
    have e2 : untag "UIDENT" = "UIDENT" := by simp [untag]
    simp only [tagOne, e1, e2]
    rw [if_pos (by simp [hn'])]
    simp [kAfter]
  · by_cases h2 : a = "LESS"
    · subst h2
      simp only [show ("LESS" : Tok) ≠ "GLESS" by decide, ite_false, ite_true, Bool.or_eq_true,
        Bool.not_eq_true'] at hpos
      have : ¬ (untag pv = "UIDENT" ∧ untag nx ≠ "LPAREN") := by
        rintro ⟨e1, e2⟩
        rw [untag_UIDENT] at e1; subst e1
        rcases hpos with h | h
        · exact absurd (List.contains_iff_mem.mpr hpv) (by simpa using h)
        · exact e2 (untag_LPAREN.mpr (by simpa using mem_of_subsetT h hnx))
      have eL : untag "LESS" = "LESS" := by simp [untag]
      simp only [tagOne, eL]
      rw [if_neg (fun ⟨_, h⟩ => this h), if_neg (by simp)]
      simp [kAfter]
    · by_cases h3 : a = "GMORE"
      · subst h3
        have := hg rfl
        simp [tagOne, untag, kAfter, this]
      · by_cases h4 : a = "MORE"
        · subst h4
          have := hm rfl
          simp [tagOne, untag, kAfter, this]
        · simp [tagOne, untag, kAfter, h1, h2, h3, h4]

section
variable (T : GGrammar) (S : AngleSets) (hc : checkAngles T S = true)
include hc

mutual
theorem tau_wf {x : Nat} {fol : Tok} {t : Tree} (h : WF T x fol t) :
    ∀ (pv : Tok) (k : Nat), pv ∈ S.prv x → fol ∈ S.aft x → (0 < k → S.inner x = true) →
      tauk (untag pv) k (untag fol) ((t.yield T x).map untag) = (t.yield T x, k) := by
  intro pv k hpv hfol hk
  match h with
  | @WF.node _ _ _ i kids r hr hg hs =>
    obtain ⟨_, _, hseq, hsim0, hsim1⟩ := rule_ok T S hc hr (List.ne_nil_of_mem hg)
    have hcond : condK S.inner k r.rhs ∧ kEnd k r.rhs = k := by
      by_cases k0 : k = 0
      · subst k0
        have := simOk_condK S.inner false 0 (by simp) 0 r.rhs hsim0
        simpa using this
      · have hin := hk (Nat.pos_of_ne_zero k0)
        simp only [hin, Bool.not_true, Bool.false_or] at hsim1
        have := simOk_condK S.inner true k (by simp; omega) 0 r.rhs hsim1
        simpa using this
    simp only [Tree.yield, hr]
    have := tau_wfs hs (S.aft x) (S.prv x) pv k hpv hfol hseq hcond.1
    rw [this, hcond.2]

theorem tau_wfs {rhs : List Sym} {fol : Tok} {kids : List Tree} (h : WFs T rhs fol kids) :
    ∀ (A P : List Tok) (pv : Tok) (kc : Nat), pv ∈ P → fol ∈ A → checkSeq S A P rhs = true →
      condK S.inner kc rhs →
      tauk (untag pv) kc (untag fol) ((rhsYield rhs (yields T (rhsNts rhs) kids)).map untag) =
        (rhsYield rhs (yields T (rhsNts rhs) kids), kEnd kc rhs) := by
  intro A P pv kc hpv hfol hseq hk
  match h with
  | .nil => simp [rhsYield, tauk, kEnd]
  | @WFs.term _ a rest _ ks hs =>
    simp only [checkSeq, Bool.and_eq_true] at hseq
    simp only [condK] at hk
    have hnx := withCtx_first (first_wfs T S hc hs) hfol
    have ht := tag_term S a pv _ kc P _ hpv hnx hseq.1 hk.1 hk.2.1
    have ih := tau_wfs hs A [a] a (kAfter kc a) (by simp) hfol hseq.2 hk.2.2
    simp only [rhsNts, rhsYield, List.map_cons, tauk, firstOr_map, ht, kEnd]
    rw [ih]
  | @WFs.nt _ y rest _ k ks hkt hs =>
    simp only [checkSeq, Bool.and_eq_true, posOk] at hseq
    simp only [condK] at hk
    have hnx := withCtx_first (first_wfs T S hc hs) hfol
    have hk1 := tau_wf hkt pv kc (mem_of_subsetT hseq.1.1 hpv) (mem_of_subsetT hseq.1.2 hnx) hk.1
    have hpv' := withCtx_last (last_wf T S hc hkt) hpv
    have ih := tau_wfs hs A (prevStep S P (.n y)) (lastOr (k.yield T y) pv) kc hpv' hfol hseq.2 hk.2
    simp only [rhsNts, yields, rhsYield, List.map_append, kEnd]
    rw [tauk_append, firstOr_map, hk1]
    rw [lastOr_map, ih]
end

end

/-! ## Untagged trees are tagged trees -/

def symUntag : Sym → Sym
  | .t a => .t (untag a)
  | s => s

theorem rhsNts_untag : ∀ (rhs : List Sym), rhsNts (rhs.map symUntag) = rhsNts rhs
  | [] => rfl
  | .t _ :: rest => by simp [symUntag, rhsNts, rhsNts_untag rest]
  | .n _ :: rest => by simp [symUntag, rhsNts, rhsNts_untag rest]

theorem tagRule_untag (r : GRule) (h : noGTok r.rhs = true) : (tagRule r).rhs.map symUntag = r.rhs := by
  unfold tagRule
  split
  · simp only [List.map_map]
    conv => rhs; rw [← List.map_id r.rhs]
    apply List.map_congr_left
    intro s hs
    cases s with
    | n y => rfl
    | t a =>
      have : a ≠ "GLESS" ∧ a ≠ "GMORE" := by
        unfold noGTok at h
        have := List.all_eq_true.mp h _ hs
        simpa using this
      simp only [Function.comp, tagSym, symUntag, untag, id]
      by_cases h1 : a = "LESS"
      · simp [h1]
      · by_cases h2 : a = "MORE" <;> simp [h1, h2, this.1, this.2]
  · conv => rhs; rw [← List.map_id r.rhs]
    apply List.map_congr_left
    intro s hs
    cases s with
    | n y => rfl
    | t a =>
      have : a ≠ "GLESS" ∧ a ≠ "GMORE" := by
        unfold noGTok at h
        have := List.all_eq_true.mp h _ hs
        simpa using this
      simp [symUntag, untag, this.1, this.2]

theorem tag_rulesOf (Q : GGrammar) (x : Nat) :
    (tagGrammar Q).rulesOf x = (Q.rulesOf x).map fun r =>
      let r' := tagRule r; { r' with guard := tagGuard r'.guard } := by
  unfold tagGrammar GGrammar.rulesOf
  simp only [Array.getD_eq_getD_getElem?, Array.getElem?_map]
  cases Q.rules[x]? <;> rfl

theorem tagRule_guard (r : GRule) : (tagRule r).guard = r.guard := by
  unfold tagRule; split <;> rfl

theorem mem_tagGuard {g : List Tok} {fol fol' : Tok} (h : fol ∈ g) (hu : untag fol' = fol) :
    fol' ∈ tagGuard g := by
  unfold tagGuard untag at *
  by_cases h1 : fol' = "GLESS"
  · subst h1; simp at hu; subst hu; simp [h]
  · by_cases h2 : fol' = "GMORE"
    · subst h2; simp at hu; subst hu; simp [h]
    · simp [h1, h2] at hu; subst hu; simp [h]

section
variable (Q : GGrammar) (hq : noGTokens Q = true)
include hq

theorem noGTok_rule {x i : Nat} {r : GRule} (hr : (Q.rulesOf x)[i]? = some r) : noGTok r.rhs = true := by
  unfold noGTokens at hq
  have hx : x < Q.rules.size := by
    refine Classical.byContradiction fun hx => ?_
    simp [GGrammar.rulesOf, Array.getD, hx] at hr
  have := Array.all_eq_true.mp hq x hx
  have hm : r ∈ Q.rules[x] := by
    have : Q.rulesOf x = Q.rules[x] := by simp [GGrammar.rulesOf, Array.getD, hx]
    rw [this] at hr; exact List.mem_of_getElem? hr
  exact List.all_eq_true.mp this r hm

mutual
theorem tag_wf {x : Nat} {fol : Tok} {t : Tree} (h : WF Q x fol t) :
    ∀ fol', untag fol' = fol →
      WF (tagGrammar Q) x fol' t ∧ (t.yield (tagGrammar Q) x).map untag = t.yield Q x := by
  intro fol' hu
  match h with
  | @WF.node _ _ _ i kids r hr hg hs =>
    have hr' : ((tagGrammar Q).rulesOf x)[i]? =
        some { tagRule r with guard := tagGuard (tagRule r).guard } := by
      rw [tag_rulesOf, List.getElem?_map, hr]; rfl
    have hrel := tagRule_untag r (noGTok_rule Q hq hr)
    obtain ⟨hs', hy⟩ := tag_wfs hs _ fol' hrel hu
    refine ⟨WF.node _ hr' (by rw [tagRule_guard]; exact mem_tagGuard hg hu) hs', ?_⟩
    simp only [Tree.yield, hr, hr']
    exact hy

theorem tag_wfs {rhs : List Sym} {fol : Tok} {kids : List Tree} (h : WFs Q rhs fol kids) :
    ∀ (rhs' : List Sym) (fol' : Tok), rhs'.map symUntag = rhs → untag fol' = fol →
      WFs (tagGrammar Q) rhs' fol' kids ∧
        (rhsYield rhs' (yields (tagGrammar Q) (rhsNts rhs') kids)).map untag =
          rhsYield rhs (yields Q (rhsNts rhs) kids) := by
  intro rhs' fol' hrel hu
  match h with
  | .nil =>
    cases rhs' with
    | nil => exact ⟨WFs.nil, rfl⟩
    | cons s rest' => simp at hrel
  | @WFs.term _ a rest _ ks hs =>
    cases rhs' with
    | nil => simp at hrel
    | cons s rest' =>
      cases s with
      | n y => simp [symUntag] at hrel
      | t a' =>
        simp only [List.map_cons, symUntag, List.cons.injEq, Sym.t.injEq] at hrel
        obtain ⟨ha, hr⟩ := hrel
        obtain ⟨hs', hy⟩ := tag_wfs hs rest' fol' hr hu
        refine ⟨WFs.term hs', ?_⟩
        simp only [rhsNts, rhsYield, List.map_cons, ha, hy]
  | @WFs.nt _ y rest _ k ks hk hs =>
    cases rhs' with
    | nil => simp at hrel
    | cons s rest' =>
      cases s with
      | t a => simp [symUntag] at hrel
      | n y' =>
        simp only [List.map_cons, symUntag, List.cons.injEq, Sym.n.injEq] at hrel
        obtain ⟨hy', hr⟩ := hrel
        subst hy'
        obtain ⟨hs', hy⟩ := tag_wfs hs rest' fol' hr hu
        have hfk : untag (firstOr (rhsYield rest' (yields (tagGrammar Q) (rhsNts rest') ks)) fol') =
            firstOr (rhsYield rest (yields Q (rhsNts rest) ks)) fol := by
          rw [← firstOr_map, hy, hu]
        obtain ⟨hk', hyk⟩ := tag_wf hk _ hfk
        refine ⟨WFs.nt hk' hs', ?_⟩
        simp only [rhsNts, yields, rhsYield, List.map_append, hyk, hy]
end

end

/-- **R2.** If the tagged grammar is unambiguous and the angle certificate
holds, the untagged grammar is unambiguous. -/
theorem angles_sound (Q : GGrammar) (S : AngleSets) (hq : noGTokens Q = true)
    (hc : checkAngles (tagGrammar Q) S = true) (hT : Unambiguous (tagGrammar Q)) : Unambiguous Q := by
  intro t₁ t₂ w₁ w₂ hy
  have hst : (tagGrammar Q).start = Q.start := rfl
  have hun : untag endTok = endTok := by decide
  obtain ⟨w₁', u₁⟩ := tag_wf Q hq w₁ endTok hun
  obtain ⟨w₂', u₂⟩ := tag_wf Q hq w₂ endTok hun
  rw [← hst] at w₁ w₂ u₁ u₂ w₁' w₂' hy
  have hc' := hc
  unfold checkAngles at hc'
  simp only [Bool.and_eq_true, List.contains_iff_mem] at hc'
  have hpv : startTok ∈ S.prv (tagGrammar Q).start := hc'.1.1
  have hfol : endTok ∈ S.aft (tagGrammar Q).start := hc'.1.2
  have e₁ := tau_wf (tagGrammar Q) S hc w₁' startTok 0 hpv hfol (fun h => absurd h (Nat.lt_irrefl 0))
  have e₂ := tau_wf (tagGrammar Q) S hc w₂' startTok 0 hpv hfol (fun h => absurd h (Nat.lt_irrefl 0))
  rw [u₁] at e₁; rw [u₂] at e₂
  rw [hy] at e₁
  exact hT _ _ w₁' w₂' (congrArg Prod.fst (e₁.symm.trans e₂))

end Ambiguity

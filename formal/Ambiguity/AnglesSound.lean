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
      congr 1
      apply List.filter_congr; intro e _; cases e <;> rfl

theorem FIn_cons_t (a : Tok) (w : List Tok) (F : List (Option Tok)) (h : some a ∈ F) : FIn (a :: w) F :=
  ⟨fun e => by cases e, fun b hb => by simp at hb; subst hb; exact h⟩

theorem withCtx_first {w : List Tok} {F : List (Option Tok)} (h : FIn w F) {fol : Tok} {A : List Tok}
    (hf : fol ∈ A) : firstOr w fol ∈ withCtx F A := by
  unfold withCtx firstOr
  cases w with
  | nil =>
    have := h.1 rfl
    simp [List.contains_iff_mem.mpr this, hf]
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
    simp [List.contains_iff_mem.mpr this, hp]
  | some a =>
    have := h.2 a hw
    simp only [Option.getD_some, List.mem_append, List.mem_filterMap, id_eq]
    exact Or.inl ⟨some a, this, rfl⟩

section
variable {T : GGrammar} {S : AngleSets} (hc : checkAngles T S = true)
include hc

theorem sub_of_all {F G : List (Option Tok)} (h : (F.all fun e => G.contains e) = true) :
    ∀ e ∈ F, e ∈ G := by
  intro e he
  have := List.all_eq_true.mp h e he
  exact List.contains_iff_mem.mp this

mutual
theorem first_wf {x : Nat} {fol : Tok} {t : Tree} (h : WF T x fol t) : FIn (t.yield T x) (S.fst x) := by
  match h with
  | @WF.node _ _ _ i kids r hr hfol hs =>
    have hf := sub_of_all hc (rule_ok T S hc hr (List.ne_nil_of_mem hfol)).1
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
      simp [List.contains_iff_mem.mpr hn, ihs.1 e2]
    · intro a ha
      cases hky : k.yield T y with
      | nil =>
        rw [hky, List.nil_append] at ha
        have hn := ihk.1 hky
        simp [List.contains_iff_mem.mpr hn, ihs.2 a ha]
      | cons b l =>
        rw [hky] at ha; simp at ha; subst ha
        have := ihk.2 a (by rw [hky]; rfl)
        exact List.mem_append_left _ (List.mem_filter.mpr ⟨this, rfl⟩)
end

theorem rhsYield_append_nts (rhs : List Sym) : True := trivial

mutual
theorem last_wf {x : Nat} {fol : Tok} {t : Tree} (h : WF T x fol t) : LIn (t.yield T x) (S.lst x) := by
  match h with
  | @WF.node _ _ _ i kids r hr hfol hs =>
    have hf := sub_of_all hc (rule_ok T S hc hr (List.ne_nil_of_mem hfol)).2.1
    have := last_wfs hs
    simp only [Tree.yield, hr]
    exact ⟨fun e => hf _ (this.1 e), fun a ha => hf _ (this.2 a ha)⟩

theorem last_wfs {rhs : List Sym} {fol : Tok} {kids : List Tree} (h : WFs T rhs fol kids) :
    LIn (rhsYield rhs (yields T (rhsNts rhs) kids)) (endseq S.lst rhs.reverse) := by
  match h with
  | .nil => exact ⟨fun _ => by simp [endseq], fun a ha => by simp [rhsYield] at ha⟩
  | @WFs.term _ a rest _ _ hs =>
    have ihs := last_wfs hs
    simp only [rhsNts, rhsYield, List.reverse_cons, endseq_append]
    constructor
    · intro e; cases e
    · intro b hb
      cases hr : rhsYield rest (yields T (rhsNts rest) _) with
      | nil =>
        rw [hr] at hb; simp at hb; subst hb
        have := ihs.1 hr
        simp [List.contains_iff_mem.mpr this, endseq]
      | cons c l =>
        rw [hr, List.getLast?_cons_cons] at hb
        have := ihs.2 b (by rw [hr]; exact hb)
        exact List.mem_append_left _ (List.mem_filter.mpr ⟨this, by
          rcases b with _ | _ <;> rfl⟩)
  | @WFs.nt _ y rest _ k ks hk hs =>
    have ihk := last_wf hk
    have ihs := last_wfs hs
    simp only [rhsNts, yields, rhsYield, List.reverse_cons, endseq_append]
    constructor
    · intro e
      have e1 := (List.append_eq_nil_iff.mp e).1
      have e2 := (List.append_eq_nil_iff.mp e).2
      have hn := ihs.1 e2
      simp [List.contains_iff_mem.mpr hn, endseq, List.contains_iff_mem.mpr (ihk.1 e1)]
    · intro a ha
      cases hr : rhsYield rest (yields T (rhsNts rest) ks) with
      | nil =>
        rw [hr, List.append_nil] at ha
        have hn := ihs.1 hr
        have := ihk.2 a ha
        simp [List.contains_iff_mem.mpr hn, endseq, this]
      | cons c l =>
        rw [hr, List.getLast?_append_of_ne_nil _ (by simp)] at ha
        have := ihs.2 a (by rw [hr]; exact ha)
        exact List.mem_append_left _ (List.mem_filter.mpr ⟨this, rfl⟩)
end

end

end Ambiguity

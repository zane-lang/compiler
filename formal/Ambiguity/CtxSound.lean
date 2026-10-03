import Ambiguity.Automaton

/-!
# The LR context grammar contains every accepted parse

Every accepted tree of the automaton, annotated with the state its
simulation starts in, is a well-formed tree of `ctxGrammar` with the same
yield, and distinct accepted trees stay distinct. So an unambiguous context
grammar means an unambiguous automaton.
-/

namespace Ambiguity
open Automaton

def Automaton.prodIdx (A : Automaton) (p : Nat) : Nat :=
  (A.prodTable.getD (A.ntIndex (A.lhs p)) []).idxOf p

mutual
def annot (A : Automaton) : ATree → Tree
  | .node p kids => .node (A.prodIdx p) (annots A kids)
def annots (A : Automaton) : List ATree → List Tree
  | [] => []
  | k :: ks => annot A k :: annots A ks
end

theorem lookup_mem {α β} [BEq α] [LawfulBEq α] : ∀ {l : List (α × β)} {k : α} {b : β},
    l.lookup k = some b → (k, b) ∈ l
  | [], _, _, h => by simp at h
  | (k', b') :: l, k, b, h => by
    rw [List.lookup_cons] at h
    split at h
    · rename_i hk; simp at h; subst h; simp at hk; subst hk; simp
    · exact List.mem_cons_of_mem _ (lookup_mem h)

section
variable (A : Automaton) (hA : A.wf = true)
include hA

theorem wf_parts : 0 < A.trans.size ∧ A.reds.size = A.trans.size ∧
    (∀ l ∈ A.trans.toList, ∀ e ∈ l, e.2 < A.trans.size) ∧
    (∀ l ∈ A.reds.toList, ∀ e ∈ l, e.1 < A.prods.size) ∧
    (∀ pr ∈ A.prods.toList, pr.1 ∈ A.nts.toList) ∧ A.start ∈ A.nts.toList := by
  unfold Automaton.wf at hA
  simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq, Array.all_eq_true',
    List.all_eq_true, Array.contains_iff_mem] at hA
  obtain ⟨⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩, h6⟩ := hA
  refine ⟨h1, h2, ?_, ?_, ?_, by simpa using h6⟩
  · intro l hl e he; exact h3 l (by simpa using hl) e he
  · intro l hl e he; exact h4 l (by simpa using hl) e he
  · intro pr hpr; simpa using h5 pr (by simpa using hpr)

theorem step_lt {q : Nat} {s : String} {q' : Nat} (h : A.step q s = some q') : q' < A.trans.size := by
  obtain ⟨_, _, h3, _⟩ := wf_parts A hA
  unfold Automaton.step at h
  have hm := lookup_mem h
  by_cases hq : q < A.trans.size
  · have : A.trans.getD q [] = A.trans[q] := by simp [Array.getD, hq]
    rw [this] at hm
    exact h3 _ (by simp) _ hm
  · have : A.trans.getD q [] = [] := by simp [Array.getD, hq]
    rw [this] at hm; cases hm

theorem look_prod_lt {r p : Nat} {a : Tok} (h : a ∈ A.look r p) : p < A.prods.size := by
  obtain ⟨_, _, _, h4, _⟩ := wf_parts A hA
  unfold Automaton.look at h
  cases hl : (A.reds.getD r []).lookup p with
  | none => rw [hl] at h; simp at h
  | some ts =>
    have hm := lookup_mem hl
    by_cases hr : r < A.reds.size
    · have : A.reds.getD r [] = A.reds[r] := by simp [Array.getD, hr]
      rw [this] at hm
      exact h4 _ (by simp) _ hm
    · have : A.reds.getD r [] = [] := by simp [Array.getD, hr]
      rw [this] at hm; cases hm

theorem lhs_nt {p : Nat} (hp : p < A.prods.size) : A.ntIndex (A.lhs p) < A.nts.size := by
  obtain ⟨_, _, _, _, h5, _⟩ := wf_parts A hA
  have : A.lhs p ∈ A.nts.toList := by
    have := h5 A.prods[p] (by simp)
    simpa [Automaton.lhs, Array.getD, hp] using this
  unfold Automaton.ntIndex
  have := List.idxOf_lt_length_of_mem this
  simpa using this

end

/-! ## The rules of the context grammar -/

theorem ctx_rulesOf (A : Automaton) {q xi : Nat} (hq : q < A.trans.size) (hx : xi < A.nts.size) :
    (A.ctxGrammar).rulesOf (q * A.nts.size + xi) =
      (A.prodTable.getD xi []).map fun p => A.ctxRule q p := by
  have hm : 0 < A.nts.size := by omega
  have hi : q * A.nts.size + xi < A.trans.size * A.nts.size := by
    have : (q + 1) * A.nts.size ≤ A.trans.size * A.nts.size := Nat.mul_le_mul_right _ hq
    rw [Nat.add_mul, Nat.one_mul] at this; omega
  have hmod : (q * A.nts.size + xi) % A.nts.size = xi := by
    rw [Nat.add_comm, Nat.add_mul_mod_self_right, Nat.mod_eq_of_lt hx]
  have hdiv : (q * A.nts.size + xi) / A.nts.size = q := by
    rw [Nat.add_comm, Nat.add_mul_div_right _ _ hm, Nat.div_eq_of_lt hx, Nat.zero_add]
  unfold Automaton.ctxGrammar GGrammar.rulesOf
  rw [Array.getD_eq_getD_getElem?, Array.getElem?_ofFn]
  simp [hi, hmod, hdiv]

theorem mem_prodTable (A : Automaton) {p : Nat} (hp : p < A.prods.size) (hx : A.ntIndex (A.lhs p) < A.nts.size) :
    p ∈ A.prodTable.getD (A.ntIndex (A.lhs p)) [] := by
  unfold Automaton.prodTable
  simp [Array.getD, hx, hp]

theorem prodTable_lhs (A : Automaton) {xi p : Nat} (h : p ∈ A.prodTable.getD xi []) :
    A.ntIndex (A.lhs p) = xi := by
  unfold Automaton.prodTable at h
  by_cases hx : xi < A.nts.size
  · simp [Array.getD, hx] at h; exact h.2
  · simp [Array.getD, hx] at h

theorem getElem?_prodIdx (A : Automaton) {p : Nat} (hp : p < A.prods.size) (hx : A.ntIndex (A.lhs p) < A.nts.size) :
    (A.prodTable.getD (A.ntIndex (A.lhs p)) [])[A.prodIdx p]? = some p := by
  unfold Automaton.prodIdx
  have hm := mem_prodTable A hp hx
  rw [List.getElem?_eq_getElem (List.idxOf_lt_length_of_mem hm)]
  simp [List.getElem_idxOf]

theorem ctxId_eq (A : Automaton) (q : Nat) (x : String) : A.ctxId q x = q * A.nts.size + A.ntIndex x := rfl

/-! ## Runs give context trees -/

theorem ayields_term (A : Automaton) {a : String} {rest : List String} {kids : List ATree}
    (h : A.isNt a = false) : ayields A (a :: rest) kids = a :: ayields A rest kids := by
  rw [ayields.eq_def]; simp [h]

theorem ayields_nt (A : Automaton) {x : String} {rest : List String} {k : ATree} {kids : List ATree}
    (h : A.isNt x = true) : ayields A (x :: rest) (k :: kids) = k.yield A ++ ayields A rest kids := by
  rw [ayields.eq_def]; simp [h]

mutual
theorem acc_ctx (A : Automaton) (hA : A.wf = true) {q : Nat} {fol : Tok} {t : ATree}
    (h : AccT A q fol t) (hq : q < A.trans.size) :
    WF A.ctxGrammar (A.ctxId q (A.lhs t.prod)) fol (annot A t) ∧
      (annot A t).yield A.ctxGrammar (A.ctxId q (A.lhs t.prod)) = t.yield A := by
  match h with
  | @AccT.node _ _ _ p kids r hrun hlook _ =>
    have hp := look_prod_lt A hA hlook
    have hx := lhs_nt A hA hp
    obtain ⟨tl, hwalk, hlast, hwfs, hy⟩ := run_ctx A hA hrun hq
    have hrule : (A.ctxGrammar.rulesOf (A.ctxId q (A.lhs p)))[A.prodIdx p]? =
        some (A.ctxRule q p) := by
      rw [ctxId_eq, ctx_rulesOf A hq hx, List.getElem?_map, getElem?_prodIdx A hp hx]; rfl
    have hcr : A.ctxRule q p = { rhs := A.ctxRhs (q :: tl) (A.rhs p), guard := A.look r p } := by
      unfold Automaton.ctxRule
      rw [hwalk]
      simp only [‹(A.step q (A.lhs p)).isSome = true›, ite_true, hlast]
    rw [hcr] at hrule
    refine ⟨WF.node _ hrule hlook hwfs, ?_⟩
    simp only [ATree.prod, annot, Tree.yield, hrule, ATree.yield]
    exact hy

theorem run_ctx (A : Automaton) (hA : A.wf = true) {q : Nat} {rhs : List String} {fol : Tok}
    {kids : List ATree} {r : Nat} (h : ARun A q rhs fol kids r) (hq : q < A.trans.size) :
    ∃ tl, A.walk q rhs = some (q :: tl) ∧ (q :: tl).getLastD q = r ∧
      WFs A.ctxGrammar (A.ctxRhs (q :: tl) rhs) fol (annots A kids) ∧
      rhsYield (A.ctxRhs (q :: tl) rhs) (yields A.ctxGrammar (rhsNts (A.ctxRhs (q :: tl) rhs)) (annots A kids)) =
        ayields A rhs kids := by
  match h with
  | .nil => exact ⟨[], rfl, rfl, by simp [Automaton.ctxRhs]; exact WFs.nil, by simp [Automaton.ctxRhs, rhsYield, ayields]⟩
  | @ARun.term _ _ a q' rest _ _ _ hnt hstep hrest =>
    obtain ⟨tl, hw, hl, hwfs, hy⟩ := run_ctx A hA hrest (step_lt A hA hstep)
    refine ⟨q' :: tl, by simp [Automaton.walk, hstep, hw], by simpa [List.getLastD] using hl, ?_, ?_⟩
    · simp only [Automaton.ctxRhs, hnt]
      exact WFs.term hwfs
    · simp only [Automaton.ctxRhs, hnt, Bool.false_eq_true, ite_false, rhsNts, rhsYield]
      rw [ayields_term A hnt, ← hy]
  | @ARun.nt _ _ x q' rest _ k kids' _ hnt hstep hk hacc hrest =>
    obtain ⟨tl, hw, hl, hwfs, hy⟩ := run_ctx A hA hrest (step_lt A hA hstep)
    obtain ⟨hwfk, hyk⟩ := acc_ctx A hA hacc hq
    rw [hk] at hwfk hyk
    refine ⟨q' :: tl, by simp [Automaton.walk, hstep, hw], by simpa [List.getLastD] using hl, ?_, ?_⟩
    · simp only [Automaton.ctxRhs, hnt, ite_true, annots]
      refine WFs.nt ?_ hwfs
      rw [hy]; exact hwfk
    · simp only [Automaton.ctxRhs, hnt, ite_true, rhsNts, annots, yields, rhsYield]
      rw [ayields_nt A hnt, hyk, hy]
end

/-! ## Distinct accepted trees have distinct annotations -/

mutual
theorem annot_inj (A : Automaton) (hA : A.wf = true) {q : Nat} {f₁ f₂ : Tok} {t₁ t₂ : ATree}
    (h₁ : AccT A q f₁ t₁) (h₂ : AccT A q f₂ t₂) (hl : A.lhs t₁.prod = A.lhs t₂.prod)
    (he : annot A t₁ = annot A t₂) : t₁ = t₂ := by
  match h₁, h₂ with
  | @AccT.node _ _ _ p₁ kids₁ _ hrun₁ hlook₁ _, @AccT.node _ _ _ p₂ kids₂ _ hrun₂ hlook₂ _ =>
    simp only [annot, Tree.node.injEq] at he
    obtain ⟨hi, hk⟩ := he
    simp only [ATree.prod] at hl
    have hp₁ := look_prod_lt A hA hlook₁
    have hp₂ := look_prod_lt A hA hlook₂
    have e₁ := getElem?_prodIdx A hp₁ (lhs_nt A hA hp₁)
    have e₂ := getElem?_prodIdx A hp₂ (lhs_nt A hA hp₂)
    rw [hl, hi] at e₁
    rw [e₁] at e₂
    cases e₂
    rw [runs_inj A hA hrun₁ hrun₂ hk]

theorem runs_inj (A : Automaton) (hA : A.wf = true) {q : Nat} {rhs : List String} {f₁ f₂ : Tok}
    {kids₁ kids₂ : List ATree} {r₁ r₂ : Nat}
    (h₁ : ARun A q rhs f₁ kids₁ r₁) (h₂ : ARun A q rhs f₂ kids₂ r₂)
    (he : annots A kids₁ = annots A kids₂) : kids₁ = kids₂ := by
  match h₁, h₂ with
  | .nil, .nil => rfl
  | .term _ hs₁ hr₁, .term _ hs₂ hr₂ =>
    rw [hs₁] at hs₂; cases hs₂
    exact runs_inj A hA hr₁ hr₂ he
  | .term hn₁ _ _, .nt hn₂ _ _ _ _ => rw [hn₁] at hn₂; cases hn₂
  | .nt hn₁ _ _ _ _, .term hn₂ _ _ => rw [hn₁] at hn₂; cases hn₂
  | .nt _ hs₁ hk₁ ha₁ hr₁, .nt _ hs₂ hk₂ ha₂ hr₂ =>
    rw [hs₁] at hs₂; cases hs₂
    simp only [annots, List.cons.injEq] at he
    rw [annot_inj A hA ha₁ ha₂ (hk₁.trans hk₂.symm) he.1, runs_inj A hA hr₁ hr₂ he.2]
end

/-- **R1.** An unambiguous context grammar means an unambiguous automaton. -/
theorem ctx_sound (A : Automaton) (hA : A.wf = true) (h : Unambiguous A.ctxGrammar) :
    AUnambiguous A := by
  intro t₁ t₂ ⟨a₁, l₁, _⟩ ⟨a₂, l₂, _⟩ hy
  have h0 := (wf_parts A hA).1
  obtain ⟨w₁, y₁⟩ := acc_ctx A hA a₁ h0
  obtain ⟨w₂, y₂⟩ := acc_ctx A hA a₂ h0
  rw [l₁] at w₁ y₁
  rw [l₂] at w₂ y₂
  have := h _ _ w₁ w₂ (by simp only [Automaton.ctxGrammar] at y₁ y₂ ⊢; rw [y₁, y₂, hy])
  exact annot_inj A hA a₁ a₂ (l₁.trans l₂.symm) this

end Ambiguity

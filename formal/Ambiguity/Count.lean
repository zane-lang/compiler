import Ambiguity.Items
import Ambiguity.Plain
import Ambiguity.Horizontal
import Ambiguity.LookaheadSound

/-!
# Counting derivations of a plain grammar over structured words

`cnt E n x u` is the capped number of derivation trees of `x`, of size at
most `n`, whose structured yield is `u`. Two distinct trees with the same
structured yield make it `2`.
-/

namespace Ambiguity

def splits (u : List Item) : List (List Item × List Item) :=
  (List.range (u.length + 1)).map fun i => (u.take i, u.drop i)

def cntSeq (cn : Nat → List Item → S) : List Sym → List Item → S
  | [], u => if u.isEmpty then 1 else 0
  | .t a :: rest, u =>
    match u with
    | .tok b :: u' => if a = b then cntSeq cn rest u' else 0
    | _ => 0
  | .n y :: rest, u => sumL (splits u) fun p => cn y p.1 * cntSeq cn rest p.2

def cntInner (cn : Nat → List Item → S) : Option Nat → List Item → S
  | none, v => if v.isEmpty then 1 else 0
  | some y, v => cn y v

def cntRule (cn : Nat → List Item → S) (r : List Sym) (u : List Item) : S :=
  match groupRule? r with
  | some (o, inner, c) =>
    match u with
    | [.grp o' v c'] => if o = o' ∧ c = c' then cntInner cn inner v else 0
    | _ => 0
  | none => cntSeq cn r u

def cnt (E : PGrammar) : Nat → Nat → List Item → S
  | 0, _, _ => 0
  | n + 1, x, u => sumL (E.rulesOf x) fun r => cntRule (cnt E n) r u

/-! ## Structured yields of trees -/

def rhsItems : List Sym → List (List Item) → List Item
  | [], _ => []
  | .t a :: rest, ys => .tok a :: rhsItems rest ys
  | .n _ :: rest, y :: ys => y ++ rhsItems rest ys
  | .n _ :: rest, [] => rhsItems rest []

mutual
def Tree.iy (E : PGrammar) (x : Nat) : Tree → List Item
  | .node i kids =>
    match (E.rulesOf x)[i]? with
    | some r =>
      match groupRule? r with
      | some (o, _, c) => [.grp o (iys E (rhsNts r) kids).flatten c]
      | none => rhsItems r (iys E (rhsNts r) kids)
    | none => []
def iys (E : PGrammar) : List Nat → List Tree → List (List Item)
  | x :: xs, t :: ts => t.iy E x :: iys E xs ts
  | _, _ => []
end


/-! ## Sums with two distinguished terms -/

theorem sumL_two_idx {α} (l : List α) (f : α → S) {i j : Nat} (hij : i ≠ j) (hi : i < l.length)
    (hj : j < l.length) (h1 : 1 ≤ f l[i]) (h2 : 1 ≤ f l[j]) : sumL l f = 2 := by
  induction l generalizing i j with
  | nil => simp at hi
  | cons a l ih =>
    simp only [sumL_cons]
    cases i with
    | zero =>
      cases j with
      | zero => exact absurd rfl hij
      | succ j =>
        have : 1 ≤ sumL l f := S.le_trans h2 (le_sumL (List.getElem_mem (by simpa using hj)) f)
        exact S.one_add_one h1 this
    | succ i =>
      cases j with
      | zero =>
        have : 1 ≤ sumL l f := S.le_trans h1 (le_sumL (List.getElem_mem (by simpa using hi)) f)
        rw [S.add_comm]; exact S.one_add_one this h2
      | succ j =>
        rw [ih (by omega) (by simpa using hi) (by simpa using hj) h1 h2]
        cases f a <;> rfl

theorem sumL_two_mem {α} (l : List α) (f : α → S) {a b : α} (hab : a ≠ b)
    (ha : a ∈ l) (hb : b ∈ l) (h1 : 1 ≤ f a) (h2 : 1 ≤ f b) : sumL l f = 2 := by
  obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem ha
  obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hb
  exact sumL_two_idx l f (fun e => hab (by subst e; rfl)) hi hj h1 h2

theorem one_le_mul {a b : S} (ha : 1 ≤ a) (hb : 1 ≤ b) : 1 ≤ a * b := by
  revert ha hb; cases a <;> cases b <;> decide

theorem two_mul_le {a b : S} (ha : a = 2) (hb : 1 ≤ b) : a * b = 2 := by
  subst ha; revert hb; cases b <;> decide

theorem mul_two {a b : S} (ha : 1 ≤ a) (hb : b = 2) : a * b = 2 := by
  subst hb; revert ha; cases a <;> decide

theorem mem_splits (u₁ u₂ : List Item) : (u₁, u₂) ∈ splits (u₁ ++ u₂) := by
  unfold splits
  rw [List.mem_map]
  exact ⟨u₁.length, List.mem_range.mpr (by simp; omega), by simp⟩


/-! ## Shape of group rules -/

def hasBracket (r : List Sym) : Bool := r.any fun | .t a => isOpen a || isClose a | _ => false

theorem groupRule_spec {r : List Sym} {o : Tok} {inner : Option Nat} {c : Tok}
    (h : groupRule? r = some (o, inner, c)) :
    closerOf o = some c ∧ ((inner = none ∧ r = [.t o, .t c]) ∨ ∃ y, inner = some y ∧ r = [.t o, .n y, .t c]) := by
  unfold groupRule? at h
  split at h
  · rename_i o' c'
    split at h
    · rename_i hc; simp at h; obtain ⟨rfl, rfl, rfl⟩ := h; exact ⟨by simpa using hc, Or.inl ⟨rfl, rfl⟩⟩
    · cases h
  · rename_i o' y c'
    split at h
    · rename_i hc; simp at h; obtain ⟨rfl, rfl, rfl⟩ := h; exact ⟨by simpa using hc, Or.inr ⟨y, rfl, rfl⟩⟩
    · cases h
  · cases h

theorem flatten_append (u v : List Item) : flatten (u ++ v) = flatten u ++ flatten v := by
  induction u with
  | nil => rfl
  | cons x u ih => simp [flatten, ih]

theorem properL_append (u v : List Item) : properL (u ++ v) = (properL u && properL v) := by
  induction u with
  | nil => simp [properL]
  | cons x u ih => simp [properL, ih, Bool.and_assoc]

section
variable (E : PGrammar)

mutual
theorem iy_flat {x : Nat} {t : Tree} (h : PWF E x t) : flatten (t.iy E x) = t.pyield E x := by
  match h with
  | @PWF.node _ _ i kids r hr hs =>
    simp only [Tree.iy, Tree.pyield, hr]
    cases hg : groupRule? r with
    | some oic =>
      obtain ⟨o, inner, c⟩ := oic
      obtain ⟨_, hshape⟩ := groupRule_spec hg
      simp only
      rcases hshape with ⟨rfl, rfl⟩ | ⟨y, rfl, rfl⟩
      · cases hs with
        | term hs => cases hs with
          | term hs => cases hs; simp [flatten, Item.flat, rhsNts, iys, rhsYield]
      · cases hs with
        | term hs => cases hs with
          | @nt _ _ k ks hk hs => cases hs with
            | term hs => cases hs; simp [flatten, Item.flat, rhsNts, iys, rhsYield, pyields, iy_flat hk]
    | none =>
      simp only
      exact iys_flat hs

theorem iys_flat {r : List Sym} {kids : List Tree} (h : PWFs E r kids) :
    flatten (rhsItems r (iys E (rhsNts r) kids)) = rhsYield r (pyields E (rhsNts r) kids) := by
  match h with
  | .nil => rfl
  | @PWFs.term _ a rest _ hs => simp [rhsItems, rhsNts, rhsYield, flatten, Item.flat, iys_flat hs]
  | @PWFs.nt _ y rest k ks hk hs =>
    simp only [rhsItems, rhsNts, iys, rhsYield, pyields, flatten_append, iy_flat hk, iys_flat hs]
end

variable (hshape : ∀ x r, r ∈ E.rulesOf x → (groupRule? r).isSome ∨ hasBracket r = false)
include hshape

mutual
theorem iy_proper {x : Nat} {t : Tree} (h : PWF E x t) : properL (t.iy E x) = true := by
  match h with
  | @PWF.node _ _ i kids r hr hs =>
    simp only [Tree.iy, hr]
    cases hg : groupRule? r with
    | some oic =>
      obtain ⟨o, inner, c⟩ := oic
      obtain ⟨hoc, hsh⟩ := groupRule_spec hg
      simp only
      rcases hsh with ⟨rfl, rfl⟩ | ⟨y, rfl, rfl⟩
      · cases hs with
        | term hs => cases hs with
          | term hs => cases hs; simp [properL, Item.proper, hoc, rhsNts, iys]
      · cases hs with
        | term hs => cases hs with
          | @nt _ _ k ks hk hs => cases hs with
            | term hs => cases hs; simp [properL, Item.proper, hoc, rhsNts, iys, iy_proper hk]
    | none =>
      simp only
      have hb : hasBracket r = false := by
        rcases hshape x r (List.mem_of_getElem? hr) with h' | h'
        · simp [hg] at h'
        · exact h'
      exact iys_proper hb hs

theorem iys_proper {r : List Sym} {kids : List Tree} (hb : hasBracket r = false) (h : PWFs E r kids) :
    properL (rhsItems r (iys E (rhsNts r) kids)) = true := by
  match h with
  | .nil => rfl
  | @PWFs.term _ a rest _ hs =>
    simp only [hasBracket, List.any_cons, Bool.or_eq_false_iff] at hb
    simp only [rhsItems, rhsNts, properL, Item.proper, Bool.and_eq_true, Bool.not_eq_true']
    exact ⟨hb.1, iys_proper (by simpa [hasBracket] using hb.2) hs⟩
  | @PWFs.nt _ y rest k ks hk hs =>
    simp only [hasBracket, List.any_cons, Bool.false_or] at hb
    simp only [rhsItems, rhsNts, iys, properL_append, iy_proper hk,
      iys_proper (by simpa [hasBracket] using hb) hs, Bool.and_self]
end

end


/-! ## One tree counts at least once, two distinct trees count twice -/

section
variable (E : PGrammar)

theorem kid_size {i : Nat} {kids : List Tree} {n : Nat} (h : (Tree.node i kids).size ≤ n + 1)
    {k : Tree} (hk : k ∈ kids) : k.size ≤ n := by
  have := size_lt_of_mem hk
  simp [Tree.size] at h; omega

theorem cnt_rule_le {n x : Nat} {u : List Item} {r : List Sym} (hr : r ∈ E.rulesOf x) :
    cntRule (cnt E n) r u ≤ cnt E (n + 1) x u := by
  simp only [cnt]; exact le_sumL hr (fun r => cntRule (cnt E n) r u)

theorem seq_ge1 (n : Nat) : ∀ {r : List Sym} {kids : List Tree}, PWFs E r kids →
    (∀ k ∈ kids, ∀ y, PWF E y k → 1 ≤ cnt E n y (k.iy E y)) →
    1 ≤ cntSeq (cnt E n) r (rhsItems r (iys E (rhsNts r) kids))
  | _, _, .nil, _ => by simp [cntSeq, rhsItems]
  | _, _, .term h, hk => by simp only [rhsItems, cntSeq, ite_true]; exact seq_ge1 n h hk
  | _, _, @PWFs.nt _ y rest k ks hky h, hk => by
    simp only [rhsItems, rhsNts, iys, cntSeq]
    have h1 := hk k (by simp) y hky
    have h2 := seq_ge1 n h (fun k' hm => hk k' (by simp [hm]))
    exact S.le_trans (one_le_mul h1 h2) (le_sumL (mem_splits _ _) (fun p => cnt E n y p.1 * cntSeq (cnt E n) rest p.2))

theorem rule_ge1 (n : Nat) (ih : ∀ x t, PWF E x t → t.size ≤ n → 1 ≤ cnt E n x (t.iy E x))
    {x i : Nat} {kids : List Tree} {r : List Sym} (hr : (E.rulesOf x)[i]? = some r) (hs : PWFs E r kids)
    (hsz : (Tree.node i kids).size ≤ n + 1) :
    1 ≤ cntRule (cnt E n) r ((Tree.node i kids).iy E x) := by
  simp only [Tree.iy, hr, cntRule]
  cases hg : groupRule? r with
  | some oic =>
    obtain ⟨o, inner, c⟩ := oic
    obtain ⟨_, hsh⟩ := groupRule_spec hg
    rcases hsh with ⟨rfl, rfl⟩ | ⟨y, rfl, rfl⟩
    · cases hs with
      | term hs => cases hs with
        | term hs => cases hs; simp [cntInner, rhsNts, iys]
    · cases hs with
      | term hs => cases hs with
        | @nt _ _ k ks hk hs => cases hs with
          | term hs =>
            cases hs
            simp only [rhsNts, iys, List.flatten_cons, List.flatten_nil, List.append_nil, and_self,
              ite_true, cntInner]
            exact ih y k hk (kid_size hsz (by simp))
  | none =>
    simp only
    exact seq_ge1 E n hs fun k hm y hk => ih y k hk (kid_size hsz hm)

theorem cnt_ge1 : ∀ n x t, PWF E x t → t.size ≤ n → 1 ≤ cnt E n x (t.iy E x) := by
  intro n
  induction n with
  | zero => intro x t _ h; cases t; simp [Tree.size] at h
  | succ n ih =>
    intro x t hw hsz
    match hw with
    | @PWF.node _ _ i kids r hr hs =>
      exact S.le_trans (rule_ge1 E n ih hr hs hsz) (cnt_rule_le E (List.mem_of_getElem? hr))

theorem rhsItems_len : ∀ {r : List Sym} {kids : List Tree}, PWFs E r kids →
    kids.length = (rhsNts r).length
  | _, _, .nil => rfl
  | _, _, .term h => by simp [rhsNts, rhsItems_len h]
  | _, _, .nt _ h => by simp [rhsNts, rhsItems_len h]

/-- Distinct kid lists with the same structured yield count twice. -/
theorem seq_two (n : Nat)
    (ih : ∀ y k₁ k₂, PWF E y k₁ → PWF E y k₂ → k₁ ≠ k₂ → k₁.iy E y = k₂.iy E y →
      k₁.size ≤ n → k₂.size ≤ n → cnt E n y (k₁.iy E y) = 2) :
    ∀ {r : List Sym} {kids₁ kids₂ : List Tree}, PWFs E r kids₁ → PWFs E r kids₂ → kids₁ ≠ kids₂ →
      rhsItems r (iys E (rhsNts r) kids₁) = rhsItems r (iys E (rhsNts r) kids₂) →
      (∀ k ∈ kids₁, k.size ≤ n) → (∀ k ∈ kids₂, k.size ≤ n) →
      (∀ k ∈ kids₁, ∀ y, PWF E y k → 1 ≤ cnt E n y (k.iy E y)) →
      (∀ k ∈ kids₂, ∀ y, PWF E y k → 1 ≤ cnt E n y (k.iy E y)) →
      cntSeq (cnt E n) r (rhsItems r (iys E (rhsNts r) kids₁)) = 2
  | _, _, _, .nil, .nil, hne, _, _, _, _, _ => absurd rfl hne
  | _, _, _, @PWFs.term _ a rest _ h₁, .term h₂, hne, hy, s₁, s₂, g₁, g₂ => by
    simp only [rhsItems, List.cons.injEq, true_and] at hy
    simp only [rhsItems, cntSeq, ite_true]
    exact seq_two n ih h₁ h₂ hne hy s₁ s₂ g₁ g₂
  | _, _, _, @PWFs.nt _ y rest k₁ ks₁ hk₁ hs₁, @PWFs.nt _ _ _ k₂ ks₂ hk₂ hs₂, hne, hy, s₁, s₂, g₁, g₂ => by
    simp only [rhsItems, rhsNts, iys] at hy ⊢
    simp only [cntSeq]
    let F := fun (p : List Item × List Item) => cnt E n y p.1 * cntSeq (cnt E n) rest p.2
    have one₁ : 1 ≤ cntSeq (cnt E n) rest (rhsItems rest (iys E (rhsNts rest) ks₁)) :=
      seq_ge1 E n hs₁ fun k hm => g₁ k (by simp [hm])
    have one₂ : 1 ≤ cntSeq (cnt E n) rest (rhsItems rest (iys E (rhsNts rest) ks₂)) :=
      seq_ge1 E n hs₂ fun k hm => g₂ k (by simp [hm])
    have c₁ := g₁ k₁ (by simp) y hk₁
    have c₂ := g₂ k₂ (by simp) y hk₂
    by_cases he : k₁.iy E y = k₂.iy E y
    · rw [he] at hy
      have hr := List.append_cancel_left hy
      by_cases hk : k₁ = k₂
      · subst hk
        have hks : ks₁ ≠ ks₂ := fun e => hne (by rw [e])
        have := seq_two n ih hs₁ hs₂ hks hr (fun k hm => s₁ k (by simp [hm])) (fun k hm => s₂ k (by simp [hm]))
          (fun k hm => g₁ k (by simp [hm])) (fun k hm => g₂ k (by simp [hm]))
        have h2 : F (k₁.iy E y, rhsItems rest (iys E (rhsNts rest) ks₁)) = 2 := mul_two c₁ this
        rw [← he] at hy
        exact S.le_antisymm (S.le_two _) (h2 ▸ le_sumL (mem_splits _ _) F)
      · have := ih y k₁ k₂ hk₁ hk₂ hk he (s₁ k₁ (by simp)) (s₂ k₂ (by simp))
        have h2 : F (k₁.iy E y, rhsItems rest (iys E (rhsNts rest) ks₁)) = 2 := two_mul_le this one₁
        exact S.le_antisymm (S.le_two _) (h2 ▸ le_sumL (mem_splits _ _) F)
    · have hp : (k₁.iy E y, rhsItems rest (iys E (rhsNts rest) ks₁)) ≠
          (k₂.iy E y, rhsItems rest (iys E (rhsNts rest) ks₂)) := fun e => he (Prod.mk.inj e).1
      have m₂ : (k₂.iy E y, rhsItems rest (iys E (rhsNts rest) ks₂)) ∈
          splits (k₁.iy E y ++ rhsItems rest (iys E (rhsNts rest) ks₁)) := by
        rw [hy]; exact mem_splits _ _
      exact sumL_two_mem _ F hp (mem_splits _ _) m₂ (one_le_mul c₁ one₁) (one_le_mul c₂ one₂)

theorem cnt_two : ∀ n x t₁ t₂, PWF E x t₁ → PWF E x t₂ → t₁ ≠ t₂ → t₁.iy E x = t₂.iy E x →
    t₁.size ≤ n → t₂.size ≤ n → cnt E n x (t₁.iy E x) = 2 := by
  intro n
  induction n with
  | zero => intro x t₁ _ _ _ _ _ h; cases t₁; simp [Tree.size] at h
  | succ n ih =>
    intro x t₁ t₂ w₁ w₂ hne hy z₁ z₂
    match w₁, w₂ with
    | @PWF.node _ _ i₁ kids₁ r₁ hr₁ hs₁, @PWF.node _ _ i₂ kids₂ r₂ hr₂ hs₂ =>
      have ge : ∀ x t, PWF E x t → t.size ≤ n → 1 ≤ cnt E n x (t.iy E x) := cnt_ge1 E n
      have g₁ := rule_ge1 E n ge hr₁ hs₁ z₁
      have g₂ := rule_ge1 E n ge hr₂ hs₂ z₂
      rw [← hy] at g₂
      have two_of : cntRule (cnt E n) r₁ ((Tree.node i₁ kids₁).iy E x) = 2 →
          cnt E (n + 1) x ((Tree.node i₁ kids₁).iy E x) = 2 := fun h2 =>
        S.le_antisymm (S.le_two _) (h2 ▸ cnt_rule_le E (List.mem_of_getElem? hr₁))
      by_cases hi : i₁ = i₂
      · subst hi
        rw [hr₁] at hr₂; cases hr₂
        have hk : kids₁ ≠ kids₂ := fun e => hne (by rw [e])
        apply two_of
        have hy' := hy
        simp only [Tree.iy, hr₁] at hy'
        simp only [Tree.iy, hr₁, cntRule]
        cases hg : groupRule? r₁ with
        | some oic =>
          obtain ⟨o, inner, c⟩ := oic
          obtain ⟨_, hsh⟩ := groupRule_spec hg
          rw [hg] at hy'
          rcases hsh with ⟨rfl, rfl⟩ | ⟨y, rfl, rfl⟩
          · have l₁ := rhsItems_len E hs₁
            have l₂ := rhsItems_len E hs₂
            simp only [rhsNts, List.length_nil] at l₁ l₂
            exact absurd ((List.length_eq_zero_iff.mp l₁).trans (List.length_eq_zero_iff.mp l₂).symm) hk
          · cases hs₁ with | term h => cases h with | @nt _ _ k₁ ks₁ hk₁ h => cases h with | term h =>
            cases h
            cases hs₂ with | term h => cases h with | @nt _ _ k₂ ks₂ hk₂ h => cases h with | term h =>
            cases h
            simp only [rhsNts, iys, List.flatten_cons, List.flatten_nil, List.append_nil,
              List.cons.injEq, Item.grp.injEq, true_and, and_true] at hy'
            have hk' : k₁ ≠ k₂ := fun e => hk (by rw [e])
            simp only [rhsNts, iys, List.flatten_cons, List.flatten_nil, List.append_nil, and_self,
              ite_true, cntInner]
            exact ih y k₁ k₂ hk₁ hk₂ hk' hy' (kid_size z₁ (by simp)) (kid_size z₂ (by simp))
        | none =>
          rw [hg] at hy'
          simp only at hy' ⊢
          exact seq_two E n ih hs₁ hs₂ hk hy' (fun k hm => kid_size z₁ hm) (fun k hm => kid_size z₂ hm)
            (fun k hm y hw => ge y k hw (kid_size z₁ hm)) (fun k hm y hw => ge y k hw (kid_size z₂ hm))
      · simp only [cnt]
        have hl₁ : i₁ < (E.rulesOf x).length := by
          rcases Nat.lt_or_ge i₁ (E.rulesOf x).length with h | h; exact h
          simp [List.getElem?_eq_none h] at hr₁
        have hl₂ : i₂ < (E.rulesOf x).length := by
          rcases Nat.lt_or_ge i₂ (E.rulesOf x).length with h | h; exact h
          simp [List.getElem?_eq_none h] at hr₂
        have e₁ : (E.rulesOf x)[i₁] = r₁ := by rw [List.getElem?_eq_getElem hl₁] at hr₁; exact Option.some.inj hr₁
        have e₂ : (E.rulesOf x)[i₂] = r₂ := by rw [List.getElem?_eq_getElem hl₂] at hr₂; exact Option.some.inj hr₂
        exact sumL_two_idx _ _ hi hl₁ hl₂ (by rw [e₁]; exact g₁) (by rw [e₂]; exact g₂)

end

end Ambiguity

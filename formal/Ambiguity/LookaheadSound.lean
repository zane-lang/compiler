import Ambiguity.Lookahead
import Ambiguity.Plain
import Ambiguity.AnglesSound

/-!
# Soundness of the lookahead product

Every guarded tree of `T` becomes a tree of the specified plain grammar with
the same yield (`KWF`), the projection `pkids` recovers it, and the explored
grammar contains every specified tree.
-/

namespace Ambiguity

def lsymNts : List LSym → List LKey
  | [] => []
  | .t _ :: rest => lsymNts rest
  | .n k :: rest => k :: lsymNts rest

def lrhsYield : List LSym → List (List Tok) → List Tok
  | [], _ => []
  | .t a :: rest, ys => a :: lrhsYield rest ys
  | .n _ :: rest, y :: ys => y ++ lrhsYield rest ys
  | .n _ :: rest, [] => lrhsYield rest []

section
variable (T : GGrammar) (F : FirstTbl)

mutual
def kyield : LKey → Tree → List Tok
  | κ, .node j kids =>
    match (specRules T F κ)[j]? with
    | some r => lrhsYield r (kyields (lsymNts r) kids)
    | none => []
def kyields : List LKey → List Tree → List (List Tok)
  | k :: ks, t :: ts => kyield k t :: kyields ks ts
  | _, _ => []
end

mutual
inductive KWF : LKey → Tree → Prop
  | node {κ j kids} (r : List LSym) : (specRules T F κ)[j]? = some r → KWFs r kids → KWF κ (.node j kids)
inductive KWFs : List LSym → List Tree → Prop
  | nil : KWFs [] []
  | term {a rest kids} : KWFs rest kids → KWFs (.t a :: rest) kids
  | nt {k rest e kids} : KWF k e → KWFs rest kids → KWFs (.n k :: rest) (e :: kids)
end

def pkidsWrap : LKey → Nat → List Tree → List Tree
  | .nt .., j, l => [.node j l]
  | _, _, l => l

mutual
/-- Projection back to trees of `T`: a nonterminal key gives one tree, any
other key the subtrees of the `T` positions it covers. -/
def pkids : LKey → Tree → List Tree
  | κ, .node j kids => pkidsWrap κ j (pkidsL (lsymNts ((specRules T F κ)[j]?.getD [])) kids)
def pkidsL : List LKey → List Tree → List Tree
  | k :: ks, t :: ts => pkids k t ++ pkidsL ks ts
  | _, _ => []
end

/-! ## The explored grammar contains the specified trees -/

section
variable (L : LGrammar) (hL : checkExplore T F L = true)
include hL

theorem explore_rule {j : Nat} {κ : LKey} (hj : L.keys[j]? = some κ) {i : Nat} {r : List LSym}
    (hr : (specRules T F κ)[i]? = some r) :
    ∃ r', (L.plain.rulesOf j)[i]? = some r' ∧ r'.length = r.length ∧
      ∀ ab ∈ r.zip r', symOk L.keys ab.1 ab.2 = true := by
  unfold checkExplore at hL
  simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at hL
  obtain ⟨⟨hsz, _⟩, hall⟩ := hL
  have hjs : j < L.keys.size := by
    rcases Nat.lt_or_ge j L.keys.size with h | h; exact h
    simp [Array.getElem?_eq_none h] at hj
  have := hall j (List.mem_range.mpr hjs)
  rw [hj] at this
  simp only [Option.getD_some, Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at this
  obtain ⟨hlen, hz⟩ := this
  have hi : i < (specRules T F κ).length := by
    rcases Nat.lt_or_ge i (specRules T F κ).length with h | h; exact h
    simp [List.getElem?_eq_none h] at hr
  have hrj : j < L.rules.size := hsz ▸ hjs
  let rs := L.rules[j]?.getD []
  have hi' : i < rs.length := hlen ▸ hi
  refine ⟨rs[i], ?_, ?_, ?_⟩
  · simp [LGrammar.plain, PGrammar.rulesOf, Array.getD, hrj, rs, List.getElem?_eq_getElem hi']
  · have hm : (r, rs[i]) ∈ (specRules T F κ).zip rs := by
      rw [List.mem_iff_getElem?]; refine ⟨i, ?_⟩
      simp [List.getElem?_zip_eq_some, hr, List.getElem?_eq_getElem hi']
    have := hz _ hm
    simp only [Bool.and_eq_true, beq_iff_eq] at this
    exact this.1.symm
  · have hm : (r, rs[i]) ∈ (specRules T F κ).zip rs := by
      rw [List.mem_iff_getElem?]; refine ⟨i, ?_⟩
      simp [List.getElem?_zip_eq_some, hr, List.getElem?_eq_getElem hi']
    have := hz _ hm
    simp only [Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at this
    exact this.2

mutual
theorem explore_wf {κ : LKey} {e : Tree} (h : KWF T F κ e) :
    ∀ j, L.keys[j]? = some κ → PWF L.plain j e ∧ e.pyield L.plain j = kyield T F κ e := by
  intro j hj
  match h with
  | @KWF.node _ _ _ i kids r hr hs =>
    obtain ⟨r', hr', hlen, hok⟩ := explore_rule T F L hL hj hr
    obtain ⟨hs', hy⟩ := explore_wfs hs r' hlen hok
    refine ⟨PWF.node r' hr' hs', ?_⟩
    simp only [Tree.pyield, hr', kyield, hr]
    exact hy

theorem explore_wfs {r : List LSym} {kids : List Tree} (h : KWFs T F r kids) :
    ∀ r' : List Sym, r'.length = r.length → (∀ ab ∈ r.zip r', symOk L.keys ab.1 ab.2 = true) →
      PWFs L.plain r' kids ∧
        rhsYield r' (pyields L.plain (rhsNts r') kids) = lrhsYield r (kyields T F (lsymNts r) kids) := by
  intro r' hlen hok
  match h, r' with
  | .nil, [] => exact ⟨PWFs.nil, rfl⟩
  | .nil, _ :: _ => simp at hlen
  | .term _, [] => simp at hlen
  | .nt _ _, [] => simp at hlen
  | @KWFs.term _ _ a rest _ hs, s :: rest' =>
    have h1 := hok (.t a, s) (by simp)
    have h2 : ∀ ab ∈ rest.zip rest', symOk L.keys ab.1 ab.2 = true :=
      fun ab hab => hok ab (by simp [hab])
    cases s with
    | n j => simp [symOk] at h1
    | t b =>
      simp only [symOk, beq_iff_eq] at h1
      subst h1
      obtain ⟨hs', hy⟩ := explore_wfs hs rest' (by simpa using hlen) h2
      exact ⟨PWFs.term hs', by simp only [rhsNts, rhsYield, lrhsYield, lsymNts]; rw [hy]⟩
  | @KWFs.nt _ _ k rest e ks hk hs, s :: rest' =>
    have h1 := hok (.n k, s) (by simp)
    have h2 : ∀ ab ∈ rest.zip rest', symOk L.keys ab.1 ab.2 = true :=
      fun ab hab => hok ab (by simp [hab])
    cases s with
    | t b => simp [symOk] at h1
    | n j =>
      simp only [symOk, beq_iff_eq] at h1
      obtain ⟨hs', hy⟩ := explore_wfs hs rest' (by simpa using hlen) h2
      obtain ⟨hk', hyk⟩ := explore_wf hk j h1
      exact ⟨PWFs.nt hk' hs', by
        simp only [rhsNts, pyields, rhsYield, lrhsYield, lsymNts, kyields]; rw [hyk, hy]⟩
end

end

end


/-! ## Slices and splitting -/

def slice (l : List Sym) (a b : Nat) : List Sym := (l.drop a).take (b - a)

theorem slice_empty (l : List Sym) {a b : Nat} (h : b ≤ a) : slice l a b = [] := by
  simp [slice, Nat.sub_eq_zero_of_le h]

theorem slice_cons (l : List Sym) {a b : Nat} (h : a < b) (hb : b ≤ l.length) :
    slice l a b = l[a]'(by omega) :: slice l (a + 1) b := by
  unfold slice
  rw [List.drop_eq_getElem_cons (by omega)]
  rw [show b - a = (b - (a + 1)) + 1 by omega, List.take_succ_cons]

theorem slice_append (l : List Sym) {a m b : Nat} (h1 : a ≤ m) (h2 : m ≤ b) :
    slice l a b = slice l a m ++ slice l m b := by
  unfold slice
  have hd : l.drop m = (l.drop a).drop (m - a) := by
    rw [List.drop_drop]; congr 1; omega
  rw [show b - a = (m - a) + (b - m) by omega, List.take_add, hd]

theorem slice_full (l : List Sym) : slice l 0 l.length = l := by simp [slice]

theorem wfs_length {G : GGrammar} : ∀ {rhs : List Sym} {fol : Tok} {kids : List Tree},
    WFs G rhs fol kids → kids.length = (rhsNts rhs).length
  | _, _, _, .nil => rfl
  | _, _, _, .term h => by simp [rhsNts, wfs_length h]
  | _, _, _, .nt _ h => by simp [rhsNts, wfs_length h]

theorem rhsNts_append (l₁ l₂ : List Sym) : rhsNts (l₁ ++ l₂) = rhsNts l₁ ++ rhsNts l₂ := by
  induction l₁ with
  | nil => rfl
  | cons s l ih => cases s <;> simp [rhsNts, ih]

theorem yields_append (G : GGrammar) : ∀ (xs₁ xs₂ : List Nat) (k₁ k₂ : List Tree),
    k₁.length = xs₁.length → yields G (xs₁ ++ xs₂) (k₁ ++ k₂) = yields G xs₁ k₁ ++ yields G xs₂ k₂
  | [], _, [], _, _ => rfl
  | x :: xs, xs₂, k :: ks, k₂, h => by
    simp only [List.cons_append, yields]
    rw [yields_append G xs xs₂ ks k₂ (by simpa using h)]
  | [], _, _ :: _, _, h => by simp at h
  | _ :: _, _, [], _, h => by simp at h

theorem rhsYield_append : ∀ (l₁ l₂ : List Sym) (ys₁ ys₂ : List (List Tok)),
    ys₁.length = (rhsNts l₁).length →
    rhsYield (l₁ ++ l₂) (ys₁ ++ ys₂) = rhsYield l₁ ys₁ ++ rhsYield l₂ ys₂
  | [], _, [], _, _ => rfl
  | [], _, _ :: _, _, h => by simp [rhsNts] at h
  | .t a :: l₁, l₂, ys₁, ys₂, h => by
    simp only [List.cons_append, rhsYield]; rw [rhsYield_append l₁ l₂ ys₁ ys₂ (by simpa [rhsNts] using h)]
  | .n x :: l₁, l₂, y :: ys₁, ys₂, h => by
    simp only [List.cons_append, rhsYield]
    rw [rhsYield_append l₁ l₂ ys₁ ys₂ (by simpa [rhsNts] using h), List.append_assoc]
  | .n x :: l₁, l₂, [], ys₂, h => by simp [rhsNts] at h

theorem yields_length (G : GGrammar) : ∀ (xs : List Nat) (ks : List Tree),
    ks.length = xs.length → (yields G xs ks).length = xs.length
  | [], [], _ => rfl
  | _ :: xs, _ :: ks, h => by simp [yields, yields_length G xs ks (by simpa using h)]
  | [], _ :: _, h => by simp at h
  | _ :: _, [], h => by simp at h

def Y (G : GGrammar) (rhs : List Sym) (kids : List Tree) : List Tok :=
  rhsYield rhs (yields G (rhsNts rhs) kids)

/-- Splitting a well-formed sequence at an append. -/
theorem wfs_split {G : GGrammar} : ∀ (l₁ l₂ : List Sym) {fol : Tok} {kids : List Tree},
    WFs G (l₁ ++ l₂) fol kids →
    ∃ k₁ k₂, kids = k₁ ++ k₂ ∧ WFs G l₂ fol k₂ ∧ WFs G l₁ (firstOr (Y G l₂ k₂) fol) k₁ ∧
      Y G (l₁ ++ l₂) kids = Y G l₁ k₁ ++ Y G l₂ k₂
  | [], l₂, _, kids, h => ⟨[], kids, rfl, h, WFs.nil, by simp [Y, rhsNts, rhsYield, yields]⟩
  | .t a :: l₁, l₂, _, kids, h => by
    cases h with
    | term h =>
      obtain ⟨k₁, k₂, rfl, h2, h1, hy⟩ := wfs_split l₁ l₂ h
      refine ⟨k₁, k₂, rfl, h2, WFs.term h1, ?_⟩
      simp only [Y, List.cons_append, rhsNts, rhsYield] at hy ⊢; rw [hy]
  | .n x :: l₁, l₂, _, kids, h => by
    cases h with
    | @nt _ _ _ k ks hk hs =>
      obtain ⟨k₁, k₂, rfl, h2, h1, hy⟩ := wfs_split l₁ l₂ hs
      refine ⟨k :: k₁, k₂, rfl, h2, WFs.nt ?_ h1, ?_⟩
      · have hk' : WF G x (firstOr (Y G (l₁ ++ l₂) (k₁ ++ k₂)) _) k := hk
        rw [hy, firstOr_append] at hk'; exact hk'
      · simp only [Y, List.cons_append, rhsNts, yields, rhsYield] at hy ⊢
        rw [hy, List.append_assoc]


/-! ## Unfolding the specification -/

section
variable (F : FirstTbl)

theorem sFirst_ge {rhs : List Sym} {a b : Nat} {t : Tok} (h : ¬ a < b) : sFirst F rhs a b t = [none] := by
  rw [sFirst]; simp [h]

theorem sFirst_t {rhs : List Sym} {a b : Nat} {t s : Tok} (h : a < b) (hs : rhs[a]? = some (.t s)) :
    sFirst F rhs a b t = [some s] := by
  rw [sFirst]; simp [h, hs]

theorem sFirst_n {rhs : List Sym} {a b : Nat} {t : Tok} {y : Nat} (h : a < b) (hs : rhs[a]? = some (.n y)) :
    sFirst F rhs a b t = ((sFirst F rhs (a + 1) b t).flatMap fun g =>
      (F y (g.getD t)).map fun e => if e.isNone then g else e).eraseDups := by
  rw [sFirst]; simp [h, hs]

end

section
variable (T : GGrammar) (F : FirstTbl)

theorem kmk {κ : LKey} {j : Nat} {r : List LSym} {ch : List Tree}
    (hr : (specRules T F κ)[j]? = some r) (hs : KWFs T F r ch) :
    KWF T F κ (.node j ch) ∧ kyield T F κ (.node j ch) = lrhsYield r (kyields T F (lsymNts r) ch) ∧
      pkids T F κ (.node j ch) = pkidsWrap κ j (pkidsL T F (lsymNts r) ch) := by
  refine ⟨KWF.node r hr hs, ?_, ?_⟩
  · rw [kyield.eq_def]; simp [hr]
  · rw [pkids.eq_def]; simp only [hr, Option.getD_some]

theorem mem_idx {l : List (List LSym)} {r : List LSym} (h : r ∈ l) : ∃ j : Nat, l[j]? = some r := by
  obtain ⟨j, hj, e⟩ := List.getElem_of_mem h
  exact ⟨j, by rw [List.getElem?_eq_getElem hj, e]⟩

def NLP (k : Tree) : Prop :=
  ∀ y fol, WF T y fol k → (k.yield T y).head? ∈ F y fol ∧
    ∀ f, (f = none ∨ f = some (k.yield T y).head?) →
      ∃ e, KWF T F (.nt y f fol) e ∧ kyield T F (.nt y f fol) e = k.yield T y ∧
        pkids T F (.nt y f fol) e = [k]

theorem groupAt_spec {rhs : List Sym} {a : Nat} {o c : Tok} {m : Nat} (h : groupAt rhs a = some (o, c, m)) :
    rhs[a]? = some (.t o) ∧ a < m ∧ rhs[m]? = some (.t c) := by
  unfold groupAt at h
  split at h
  · rename_i o' ho
    split at h
    · rename_i c' m' _ _
      split at h
      · rename_i hc
        simp only [Option.some.injEq, Prod.mk.injEq] at h
        obtain ⟨rfl, rfl, rfl⟩ := h
        exact ⟨ho, hc.1, hc.2⟩
      · cases h
    · cases h
  · cases h

theorem wfs_slice_cons {rhs : List Sym} {a b : Nat} (h : a < b) (hb : b ≤ rhs.length) {s : Sym}
    (hs : rhs[a]? = some s) : slice rhs a b = s :: slice rhs (a + 1) b := by
  rw [slice_cons rhs h hb]
  have : rhs[a]'(by omega) = s := by
    rw [List.getElem?_eq_getElem (by omega)] at hs; exact Option.some.inj hs
  rw [this]

theorem seg {x i : Nat} {r : GRule} (hr : ruleAt T x i = some r) :
    ∀ n a b, b - a = n → b ≤ r.rhs.length → ∀ fol kids,
      WFs T (slice r.rhs a b) fol kids → (∀ k ∈ kids, NLP T F k) →
      (Y T (slice r.rhs a b) kids).head? ∈ sFirst F r.rhs a b fol ∧
      ∀ f, (f = none ∨ f = some (Y T (slice r.rhs a b) kids).head?) →
        ∃ e, KWF T F (.seq x i a b f fol) e ∧
          kyield T F (.seq x i a b f fol) e = Y T (slice r.rhs a b) kids ∧
          pkids T F (.seq x i a b f fol) e = kids := by
  intro n
  induction n using Nat.strongRecOn with
  | _ n ih =>
  intro a b hn hb fol kids hw hk
  by_cases hab : a < b
  · have ha : a < r.rhs.length := by omega
    cases hs : r.rhs[a]? with
    | none => rw [List.getElem?_eq_getElem ha] at hs; cases hs
    | some s =>
      rw [wfs_slice_cons hab hb hs] at hw ⊢
      cases s with
      | t s =>
        cases hw with
        | term hw =>
        have hfirst : (Y T (.t s :: slice r.rhs (a + 1) b) kids).head? = some s := by
          simp [Y, rhsNts, rhsYield]
        refine ⟨by rw [hfirst, sFirst_t F hab hs]; simp, fun f hf => ?_⟩
        rw [hfirst] at hf
        have hf' : f = none ∨ f = some (some s) := hf
        -- the rest of the segment, or the group and what follows it
        cases hg : groupAt r.rhs a with
        | some ocm =>
          obtain ⟨o, c, m⟩ := ocm
          obtain ⟨ho, ham, hcm⟩ := groupAt_spec hg
          rw [hs] at ho; cases ho
          by_cases hmb : m < b
          · -- split the interior and the tail
            have hsp : slice r.rhs (a + 1) b = slice r.rhs (a + 1) m ++ (.t c :: slice r.rhs (m + 1) b) := by
              rw [slice_append r.rhs (show a + 1 ≤ m by omega) (show m ≤ b by omega),
                wfs_slice_cons (show m < b from hmb) hb hcm]
            rw [hsp] at hw
            obtain ⟨k₁, k₂, rfl, h2, h1, hy⟩ := wfs_split _ _ hw
            cases h2 with
            | term h2 =>
            have hc1 : firstOr (Y T (.t c :: slice r.rhs (m + 1) b) k₂) fol = c := by
              simp [Y, rhsNts, rhsYield, firstOr]
            rw [hc1] at h1
            have hk₁ : ∀ k ∈ k₁, NLP T F k := fun k hm => hk k (List.mem_append_left _ hm)
            have hk₂ : ∀ k ∈ k₂, NLP T F k := fun k hm => hk k (List.mem_append_right _ hm)
            obtain ⟨-, hin⟩ := ih (m - (a + 1)) (by omega) (a + 1) m rfl (by omega) c k₁ h1 hk₁
            obtain ⟨ein, kin, yin, pin⟩ := hin none (Or.inl rfl)
            obtain ⟨-, haf⟩ := ih (b - (m + 1)) (by omega) (m + 1) b rfl hb fol k₂ h2 hk₂
            obtain ⟨eaf, kaf, yaf, paf⟩ := haf none (Or.inl rfl)
            -- the interior key
            have hsin : specRules T F (.inner x i a) = [[.n (.seq x i (a + 1) m none c)]] := by
              simp [specRules, hr, hg]
            obtain ⟨kI, yI, pI⟩ := kmk T F (κ := .inner x i a) (j := 0) (by rw [hsin]; rfl)
              (KWFs.nt kin KWFs.nil)
            -- the group key
            have hgrp : ∃ eg, KWF T F (.grp x i a) eg ∧
                kyield T F (.grp x i a) eg = s :: (Y T (slice r.rhs (a + 1) m) k₁ ++ [c]) ∧
                pkids T F (.grp x i a) eg = k₁ := by
              by_cases hm1 : m = a + 1
              · subst hm1
                have hse : slice r.rhs (a + 1) (a + 1) = [] := slice_empty _ (Nat.le_refl _)
                rw [hse] at h1 yin
                cases h1
                have hsg : specRules T F (.grp x i a) = [[.t s, .t c]] := by
                  simp [specRules, hr, hg]
                obtain ⟨kg, yg, pg⟩ := kmk T F (κ := .grp x i a) (j := 0) (by rw [hsg]; rfl)
                  (KWFs.term (KWFs.term KWFs.nil))
                refine ⟨_, kg, ?_, ?_⟩
                · rw [yg, hse]; simp [lrhsYield, Y, rhsYield]
                · rw [pg]; simp [pkidsL, pkidsWrap, lsymNts]
              · have hsg : specRules T F (.grp x i a) = [[.t s, .n (.inner x i a), .t c]] := by
                  simp [specRules, hr, hg, hm1]
                obtain ⟨kg, yg, pg⟩ := kmk T F (κ := .grp x i a) (j := 0) (by rw [hsg]; rfl)
                  (KWFs.term (KWFs.nt kI (KWFs.term KWFs.nil)))
                refine ⟨_, kg, ?_, ?_⟩
                · rw [yg]; simp [lrhsYield, lsymNts, kyields, yI, yin]
                · rw [pg]; simp [pkidsL, pkidsWrap, lsymNts, pI, pin]
            obtain ⟨eg, kg, yg, pg⟩ := hgrp
            have hss : specRules T F (.seq x i a b f fol) =
                [[.n (.grp x i a), .n (.seq x i (m + 1) b none fol)]] := by
              simp [specRules, hr, hab, hs, hg, hmb, hf']
            obtain ⟨k3, y3, p3⟩ := kmk T F (κ := .seq x i a b f fol) (j := 0) (by rw [hss]; rfl)
              (KWFs.nt kg (KWFs.nt kaf KWFs.nil))
            refine ⟨_, k3, ?_, ?_⟩
            · rw [y3]
              simp only [lrhsYield, lsymNts, kyields, yg, yaf, List.append_nil]
              rw [hsp]
              have hy' : rhsYield (slice r.rhs (a + 1) m ++ .t c :: slice r.rhs (m + 1) b)
                  (yields T (rhsNts (slice r.rhs (a + 1) m ++ .t c :: slice r.rhs (m + 1) b)) (k₁ ++ k₂)) =
                  Y T (slice r.rhs (a + 1) m) k₁ ++ Y T (.t c :: slice r.rhs (m + 1) b) k₂ := hy
              simp only [Y, rhsNts, rhsYield]
              rw [hy']
              simp [Y, rhsYield, rhsNts]
            · rw [p3]; simp [pkidsL, pkidsWrap, lsymNts, pg, paf]
          · have hss : specRules T F (.seq x i a b f fol) = [[.t s, .n (.seq x i (a + 1) b none fol)]] := by
              simp [specRules, hr, hab, hs, hg, hmb, hf']
            obtain ⟨-, hre⟩ := ih (b - (a + 1)) (by omega) (a + 1) b rfl hb fol kids hw hk
            obtain ⟨er, kr, yr, pr⟩ := hre none (Or.inl rfl)
            obtain ⟨k3, y3, p3⟩ := kmk T F (κ := .seq x i a b f fol) (j := 0) (by rw [hss]; rfl)
              (KWFs.term (KWFs.nt kr KWFs.nil))
            refine ⟨_, k3, ?_, ?_⟩
            · rw [y3]; simp [lrhsYield, lsymNts, kyields, yr, Y, rhsNts, rhsYield]
            · rw [p3]; simp [pkidsL, pkidsWrap, lsymNts, pr]
        | none =>
          have hss : specRules T F (.seq x i a b f fol) = [[.t s, .n (.seq x i (a + 1) b none fol)]] := by
            simp [specRules, hr, hab, hs, hg, hf']
          obtain ⟨-, hre⟩ := ih (b - (a + 1)) (by omega) (a + 1) b rfl hb fol kids hw hk
          obtain ⟨er, kr, yr, pr⟩ := hre none (Or.inl rfl)
          obtain ⟨k3, y3, p3⟩ := kmk T F (κ := .seq x i a b f fol) (j := 0) (by rw [hss]; rfl)
            (KWFs.term (KWFs.nt kr KWFs.nil))
          refine ⟨_, k3, ?_, ?_⟩
          · rw [y3]; simp [lrhsYield, lsymNts, kyields, yr, Y, rhsNts, rhsYield]
          · rw [p3]; simp [pkidsL, pkidsWrap, lsymNts, pr]
      | n y =>
        cases hw with
        | @nt _ _ _ k ks hky hw =>
        have hkk : NLP T F k := hk k (by simp)
        have hks : ∀ k' ∈ ks, NLP T F k' := fun k' hm => hk k' (by simp [hm])
        obtain ⟨hfr, hre⟩ := ih (b - (a + 1)) (by omega) (a + 1) b rfl hb fol ks hw hks
        let Yr := Y T (slice r.rhs (a + 1) b) ks
        let g0 := Yr.head?
        have hafter : firstOr Yr fol = g0.getD fol := rfl
        have hky' : WF T y (g0.getD fol) k := hafter ▸ hky
        obtain ⟨hfk, hkt⟩ := hkk y _ hky'
        let Yk := k.yield T y
        have hYeq : Y T (.n y :: slice r.rhs (a + 1) b) (k :: ks) = Yk ++ Yr := by
          simp [Y, rhsNts, yields, rhsYield, Yk, Yr]
        have hhead : (Yk ++ Yr).head? = if Yk.head?.isNone then g0 else Yk.head? := by
          cases hY : Yk with
          | nil => simp [g0]
          | cons z zs => simp
        refine ⟨?_, fun f hf => ?_⟩
        · rw [hYeq, sFirst_n F hab hs, List.mem_eraseDups, List.mem_flatMap]
          exact ⟨g0, hfr, List.mem_map.mpr ⟨_, hfk, hhead.symm⟩⟩
        · rw [hYeq] at hf
          have hspec : specRules T F (.seq x i a b f fol) =
              (sFirst F r.rhs (a + 1) b fol).eraseDups.flatMap fun g =>
                let after := g.getD fol
                let rest := LSym.n (.seq x i (a + 1) b (some g) fol)
                let child := F y after
                match f with
                | none => if child.isEmpty then [] else [[.n (.nt y none after), rest]]
                | some fv =>
                  (if fv.isSome && child.contains fv then [[.n (.nt y (some fv) after), rest]] else []) ++
                  (if child.contains none && fv == g then [[.n (.nt y (some none) after), rest]] else []) := by
            unfold specRules; simp only [hr, if_pos hab, hs]; rfl
          obtain ⟨er, kr, yr, pr⟩ := hre (some g0) (Or.inr rfl)
          -- choose the child annotation
          have hchoice : ∃ f', (f' = none ∨ f' = some Yk.head?) ∧
              [LSym.n (.nt y f' (g0.getD fol)), LSym.n (.seq x i (a + 1) b (some g0) fol)] ∈
                specRules T F (.seq x i a b f fol) := by
            rw [hspec]
            have hg0 : g0 ∈ (sFirst F r.rhs (a + 1) b fol).eraseDups := List.mem_eraseDups.mpr hfr
            rcases hf with rfl | rfl
            · refine ⟨none, Or.inl rfl, List.mem_flatMap.mpr ⟨g0, hg0, ?_⟩⟩
              have : (F y (g0.getD fol)).isEmpty = false := by
                cases hF : F y (g0.getD fol) with
                | nil => rw [hF] at hfk; cases hfk
                | cons _ _ => rfl
              simp [this]
            · cases hYk : Yk.head? with
              | some z =>
                refine ⟨some (some z), Or.inr rfl, List.mem_flatMap.mpr ⟨g0, hg0, ?_⟩⟩
                rw [hYk] at hfk
                rw [hhead, hYk]
                simp [hfk]
              | none =>
                refine ⟨some none, Or.inr rfl, List.mem_flatMap.mpr ⟨g0, hg0, ?_⟩⟩
                rw [hYk] at hfk
                rw [hhead, hYk]
                simp [hfk]
          obtain ⟨f', hf', hmem⟩ := hchoice
          obtain ⟨ek, kk, yk, pk⟩ := hkt f' hf'
          obtain ⟨j, hj⟩ := mem_idx hmem
          obtain ⟨k3, y3, p3⟩ := kmk T F hj (KWFs.nt kk (KWFs.nt kr KWFs.nil))
          refine ⟨_, k3, ?_, ?_⟩
          · rw [y3, hYeq]; simp [lrhsYield, lsymNts, kyields, yk, yr, Yk, Yr]
          · rw [p3]; simp [pkidsL, pkidsWrap, lsymNts, pk, pr]
  · rw [slice_empty r.rhs (by omega)] at hw ⊢
    cases hw
    refine ⟨by simp [Y, rhsYield, sFirst_ge F hab], fun f hf => ?_⟩
    have hspec : specRules T F (.seq x i a b f fol) = [[]] := by
      simp only [specRules, hr, hab, ite_false]
      have : f = none ∨ f = some none := by simpa [Y, rhsYield] using hf
      simp [this]
    obtain ⟨h1, h2, h3⟩ := kmk T F (κ := .seq x i a b f fol) (j := 0) (by rw [hspec]; rfl) KWFs.nil
    exact ⟨_, h1, by rw [h2]; rfl, by rw [h3]; rfl⟩

mutual
def Tree.size : Tree → Nat
  | .node _ kids => 1 + Tree.sizes kids
def Tree.sizes : List Tree → Nat
  | [] => 0
  | t :: ts => t.size + Tree.sizes ts
end

theorem size_lt_of_mem : ∀ {kids : List Tree} {k : Tree}, k ∈ kids → k.size ≤ Tree.sizes kids
  | _ :: _, _, .head _ => by simp [Tree.sizes]
  | _ :: ts, _, .tail _ h => by have := size_lt_of_mem h; simp [Tree.sizes]; omega

theorem node_lemma (hF : checkFirst T F = true) : ∀ n (t : Tree), t.size ≤ n → NLP T F t := by
  intro n
  induction n with
  | zero => intro t h; cases t; simp [Tree.size] at h
  | succ n ih =>
    intro t ht y fol hw
    match hw with
    | @WF.node _ _ _ i kids r hr hg hs =>
      have hkids : ∀ k ∈ kids, NLP T F k := fun k hm =>
        ih k (by have := size_lt_of_mem hm; simp [Tree.size] at ht; omega)
      have hra : ruleAt T y i = some r := hr
      rw [← slice_full r.rhs] at hs
      obtain ⟨hfirst, hseq⟩ := seg T F hra _ 0 r.rhs.length rfl (Nat.le_refl _) fol kids hs hkids
      rw [slice_full] at hfirst hseq
      have hyield : (Tree.node i kids).yield T y = Y T r.rhs kids := by
        simp [Tree.yield, hr, Y]
      rw [hyield]
      have hy : y < T.rules.size := by
        refine Classical.byContradiction fun h => ?_
        simp [GGrammar.rulesOf, Array.getD, h] at hr
      refine ⟨?_, fun f hf => ?_⟩
      · unfold checkFirst at hF
        have := List.all_eq_true.mp hF y (List.mem_range.mpr hy)
        have := List.all_eq_true.mp this r (List.mem_of_getElem? hr)
        have := List.all_eq_true.mp this fol hg
        have := List.all_eq_true.mp this _ hfirst
        exact List.contains_iff_mem.mp this
      · obtain ⟨e, ke, ye, pe⟩ := hseq f hf
        have hspec : (specRules T F (.nt y f fol))[i]? = some [.n (.seq y i 0 r.rhs.length f fol)] := by
          simp only [specRules, List.getElem?_map, List.getElem?_zipIdx, hr, Option.map_some]
          have hfo : fOk f (sFirst F r.rhs 0 r.rhs.length fol) = true := by
            rcases hf with rfl | rfl
            · rfl
            · simp [fOk, hfirst]
          simp [hg, hfo]
        obtain ⟨k3, y3, p3⟩ := kmk T F hspec (KWFs.nt ke KWFs.nil)
        refine ⟨_, k3, ?_, ?_⟩
        · rw [y3]; simp [lrhsYield, lsymNts, kyields, ye]
        · rw [p3]; simp [pkidsL, pkidsWrap, lsymNts, pe]

/-- **R3.** The specified plain product, as explored, being unambiguous means
the guarded grammar is. -/
theorem lookahead_sound (hF : checkFirst T F = true) (L : LGrammar) (hL : checkExplore T F L = true)
    (hU : PUnambiguous L.plain) : Unambiguous T := by
  intro t₁ t₂ w₁ w₂ hy
  have h0 : L.keys[0]? = some (startKey T) := by
    unfold checkExplore at hL
    simp only [Bool.and_eq_true, beq_iff_eq] at hL
    exact hL.1.2
  obtain ⟨-, n₁⟩ := node_lemma T F hF _ t₁ (Nat.le_refl _) _ _ w₁
  obtain ⟨-, n₂⟩ := node_lemma T F hF _ t₂ (Nat.le_refl _) _ _ w₂
  obtain ⟨e₁, k₁, y₁, p₁⟩ := n₁ none (Or.inl rfl)
  obtain ⟨e₂, k₂, y₂, p₂⟩ := n₂ none (Or.inl rfl)
  obtain ⟨q₁, z₁⟩ := explore_wf T F L hL k₁ 0 h0
  obtain ⟨q₂, z₂⟩ := explore_wf T F L hL k₂ 0 h0
  have he : e₁ = e₂ := hU _ _ q₁ q₂ (by
    show e₁.pyield L.plain 0 = e₂.pyield L.plain 0
    rw [z₁, z₂]; exact (y₁.trans hy).trans y₂.symm)
  subst he
  have := p₁.symm.trans p₂
  simpa using this

end

end Ambiguity

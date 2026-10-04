import Ambiguity.Source

/-!
# The GLR grammar against the source grammar

Menhir's `--GLR` backend parses a rewritten grammar: nullable symbols in
right-nullable suffixes are split into an empty and a nonempty part, and the
empty part is inlined away. Each production of the rewritten grammar `G` is
checked against a source production of `S`: it either keeps or drops each
source symbol (a dropped symbol is replaced by a fixed empty derivation), or it
is a unit production from a symbol to its nonempty part.

`rho` maps the rewritten grammar's trees to source trees. It preserves
well-formedness and yields, so the trees the GLR parser returns, read as
source trees, are source derivations of the same tokens; and since the GLR
relation is unambiguous, so are they.
-/

namespace Ambiguity

/-! ## Well-formed trees of an automaton's grammar -/

mutual
inductive AWF (A : Automaton) : ATree → Prop
  | node {p kids} : p < A.prods.size → AWFs A (A.rhs p) kids → AWF A (.node p kids)
inductive AWFs (A : Automaton) : List String → List ATree → Prop
  | nil : AWFs A [] []
  | term {a rest kids} : A.isNt a = false → AWFs A rest kids → AWFs A (a :: rest) kids
  | nt {x rest k kids} : A.isNt x = true → A.lhs k.prod = x → AWF A k → AWFs A rest kids →
      AWFs A (x :: rest) (k :: kids)
end

mutual
def wfB (A : Automaton) : ATree → Bool
  | .node p kids => decide (p < A.prods.size) && wfsB A (A.rhs p) kids
def wfsB (A : Automaton) : List String → List ATree → Bool
  | [], [] => true
  | a :: rest, kids =>
    if A.isNt a then
      match kids with
      | k :: ks => A.lhs k.prod == a && wfB A k && wfsB A rest ks
      | [] => false
    else wfsB A rest kids
  | [], _ :: _ => false
end

mutual
theorem wfB_sound (A : Automaton) : ∀ t, wfB A t = true → AWF A t
  | .node p kids, h => by
    simp only [wfB, Bool.and_eq_true, decide_eq_true_eq] at h
    exact .node h.1 (wfsB_sound A _ kids h.2)
  termination_by t => (sizeOf t, 0)
theorem wfsB_sound (A : Automaton) : ∀ xs kids, wfsB A xs kids = true → AWFs A xs kids
  | [], [], _ => .nil
  | [], _ :: _, h => by simp [wfsB] at h
  | a :: rest, [], h => by
    by_cases ha : A.isNt a = true
    · simp [wfsB, ha] at h
    · have : wfsB A rest [] = true := by simpa [wfsB, ha] using h
      exact .term (by simpa using ha) (wfsB_sound A rest [] this)
  | a :: rest, k :: ks, h => by
    by_cases ha : A.isNt a = true
    · simp only [wfsB, ha, ite_true, Bool.and_eq_true, beq_iff_eq] at h
      exact .nt ha h.1.1 (wfB_sound A k h.1.2) (wfsB_sound A rest ks h.2)
    · have : wfsB A rest (k :: ks) = true := by simpa [wfsB, ha] using h
      exact .term (by simpa using ha) (wfsB_sound A rest (k :: ks) this)
  termination_by xs kids => (sizeOf kids, xs.length)
end

theorem look_lt (A : Automaton) (hA : A.wf = true) {r p : Nat} {fol : Tok} (h : fol ∈ A.look r p) :
    p < A.prods.size := by
  unfold Automaton.look at h
  cases hl : (A.reds.getD r []).lookup p with
  | none => rw [hl] at h; simp at h
  | some ts =>
    have hm := lookup_mem' hl
    have hr : r < A.reds.size := by
      rcases Nat.lt_or_ge r A.reds.size with h' | h'; exact h'
      simp [Array.getD, Nat.not_lt.mpr h'] at hm
    have := (wf_parts A hA).2.2.2.1 (A.reds.getD r []) (by simp [Array.getD, hr]) _ hm
    exact this

mutual
theorem acc_awf (A : Automaton) (hA : A.wf = true) : ∀ {q fol t}, AccT A q fol t → AWF A t
  | _, _, _, .node hr hl _ => .node (look_lt A hA hl) (run_awfs A hA hr)
theorem run_awfs (A : Automaton) (hA : A.wf = true) : ∀ {q xs fol kids r}, ARun A q xs fol kids r → AWFs A xs kids
  | _, _, _, _, _, .nil => .nil
  | _, _, _, _, _, .term ha _ hr => .term ha (run_awfs A hA hr)
  | _, _, _, _, _, .nt hx _ hl hk hr => .nt hx hl (acc_awf A hA hk) (run_awfs A hA hr)
end

/-! ## Production correspondence -/

/-- How a rewritten production relates to the source: a unit production to a
symbol's nonempty part, or a source production with each symbol kept or
dropped. -/
inductive Corr where
  | unit
  | align (s : Nat) (keep : List Bool)
  deriving Repr, Inhabited

section
variable (G S : Automaton) (corr : Array Corr) (base : Std.HashMap String String)
  (eps : Std.HashMap String ATree)

/-- The source symbol a rewritten symbol stands for. -/
def baseOf (y : String) : String := base.getD y y

def epsTree (x : String) : ATree := (eps.get? x).getD default

def epsOk (x : String) : Bool :=
  match eps.get? x with
  | some t => wfB S t && S.lhs t.prod == x && t.yield S == []
  | none => false

def alignOk : List String → List Bool → List String → Bool
  | [], [], [] => true
  | x :: xs, true :: ks, y :: ys =>
    (if S.isNt x then G.isNt y && baseOf base y == x else !G.isNt y && y == x) && alignOk xs ks ys
  | x :: xs, false :: ks, ys => S.isNt x && epsOk S eps x && alignOk xs ks ys
  | _, _, _ => false

def checkProd (p : Nat) : Bool :=
  match corr[p]? with
  | some .unit =>
    match G.rhs p with
    | [y] => G.isNt y && baseOf base y == baseOf base (G.lhs p)
    | _ => false
  | some (.align s keep) =>
    decide (s < S.prods.size) && baseOf base (G.lhs p) == S.lhs s && alignOk G S base eps (S.rhs s) keep (G.rhs p)
  | none => false

def checkCorr : Bool :=
  (List.range G.prods.size).all (checkProd G S corr base eps) && baseOf base G.start == S.start

mutual
def rho : ATree → ATree
  | .node p kids =>
    match corr[p]? with
    | some (.align s keep) => .node s (rhoKids (S.rhs s) keep kids)
    | _ => rhoHead kids
def rhoHead : List ATree → ATree
  | c :: _ => rho c
  | [] => default
def rhoKids : List String → List Bool → List ATree → List ATree
  | x :: xs, true :: ks, k :: kk => if S.isNt x then rho k :: rhoKids xs ks kk else rhoKids xs ks (k :: kk)
  | x :: xs, true :: ks, [] => if S.isNt x then [] else rhoKids xs ks []
  | x :: xs, false :: ks, kids => epsTree eps x :: rhoKids xs ks kids
  | _, _, _ => []
end

theorem rho_align {p s : Nat} {keep : List Bool} {kids : List ATree} (h : corr[p]? = some (.align s keep)) :
    rho S corr eps (.node p kids) = .node s (rhoKids S corr eps (S.rhs s) keep kids) := by
  rw [rho, h]

theorem rho_unit {p : Nat} {c : ATree} (h : corr[p]? = some .unit) :
    rho S corr eps (.node p [c]) = rho S corr eps c := by
  rw [rho, h]; simp only; rw [rhoHead]

theorem rk_nil (kids : List ATree) : rhoKids S corr eps [] [] kids = [] := by
  cases kids <;> rw [rhoKids] <;> simp

theorem rk_nt {x : String} {xs : List String} {ks : List Bool} {k : ATree} {kk : List ATree}
    (hx : S.isNt x = true) :
    rhoKids S corr eps (x :: xs) (true :: ks) (k :: kk) = rho S corr eps k :: rhoKids S corr eps xs ks kk := by
  rw [rhoKids, if_pos hx]

theorem rk_term {x : String} {xs : List String} {ks : List Bool} {kids : List ATree}
    (hx : S.isNt x = false) :
    rhoKids S corr eps (x :: xs) (true :: ks) kids = rhoKids S corr eps xs ks kids := by
  cases kids <;> rw [rhoKids] <;> simp [hx]

theorem rk_drop {x : String} {xs : List String} {ks : List Bool} {kids : List ATree} :
    rhoKids S corr eps (x :: xs) (false :: ks) kids = epsTree eps x :: rhoKids S corr eps xs ks kids := by
  rw [rhoKids]

variable (hc : checkCorr G S corr base eps = true)
include hc

theorem prod_ok {p : Nat} (hp : p < G.prods.size) : checkProd G S corr base eps p = true := by
  unfold checkCorr at hc
  simp only [Bool.and_eq_true, List.all_eq_true, List.mem_range] at hc
  exact hc.1 p hp

theorem eps_ok {x : String} (h : epsOk S eps x = true) :
    AWF S (epsTree eps x) ∧ S.lhs (epsTree eps x).prod = x ∧ (epsTree eps x).yield S = [] := by
  unfold epsOk at h
  unfold epsTree
  cases he : eps.get? x with
  | none => rw [he] at h; cases h
  | some t =>
    rw [he] at h
    simp only [Bool.and_eq_true, beq_iff_eq] at h
    exact ⟨wfB_sound S t h.1.1, h.1.2, h.2⟩

mutual
/-- **`rho` is a correspondence.** A well-formed tree of the rewritten grammar
becomes a well-formed source tree with the same yield, rooted at the source
symbol its root stands for. -/
theorem rho_wf : ∀ t, AWF G t → AWF S (rho S corr eps t) ∧
    (rho S corr eps t).yield S = t.yield G ∧ S.lhs (rho S corr eps t).prod = baseOf base (G.lhs t.prod)
  | .node p kids, .node hp hk => by
    have hpc := prod_ok G S corr base eps hc hp
    unfold checkProd at hpc
    cases hco : corr[p]? with
    | none => rw [hco] at hpc; cases hpc
    | some co =>
      rw [hco] at hpc
      cases co with
      | align s keep =>
        simp only [Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hpc
        obtain ⟨⟨hs, hb⟩, ha⟩ := hpc
        obtain ⟨w, y⟩ := rhoKids_wf (S.rhs s) keep (G.rhs p) kids ha hk
        rw [rho_align S corr eps hco]
        exact ⟨.node hs w, by rw [ATree.yield, ATree.yield]; exact y, hb.symm⟩
      | unit =>
        cases hr : G.rhs p with
        | nil => rw [hr] at hpc; cases hpc
        | cons y ys =>
          cases ys with
          | cons _ _ => rw [hr] at hpc; cases hpc
          | nil =>
            rw [hr] at hpc
            simp only [Bool.and_eq_true, beq_iff_eq] at hpc
            rw [hr] at hk
            cases hk with
            | term ha _ => rw [hpc.1] at ha; cases ha
            | @nt _ _ c kk _ hl hkc hrest =>
              cases hrest with
              | nil =>
                obtain ⟨w, yl, lh⟩ := rho_wf c hkc
                rw [rho_unit S corr eps hco]
                refine ⟨w, ?_, ?_⟩
                · rw [yl]; simp [ATree.yield, hr, ayields, hpc.1]
                · rw [lh, hl, hpc.2]; rfl
  termination_by t => (sizeOf t, 0)
theorem rhoKids_wf : ∀ xs keep ys kids, alignOk G S base eps xs keep ys = true → AWFs G ys kids →
    AWFs S xs (rhoKids S corr eps xs keep kids) ∧
      ayields S xs (rhoKids S corr eps xs keep kids) = ayields G ys kids
  | [], [], [], kids, _, hk => by
    cases hk; rw [rk_nil]; exact ⟨.nil, by simp [ayields]⟩
  | x :: xs, true :: ks, y :: ys, kids, ha, hk => by
    simp only [alignOk, Bool.and_eq_true] at ha
    obtain ⟨hxy, ha⟩ := ha
    by_cases hx : S.isNt x = true
    · simp only [hx, ite_true, Bool.and_eq_true, beq_iff_eq] at hxy
      cases hk with
      | term hy _ => rw [hxy.1] at hy; cases hy
      | @nt _ _ k kk _ hl hkw hrest =>
        obtain ⟨w1, y1, l1⟩ := rho_wf k hkw
        obtain ⟨w2, y2⟩ := rhoKids_wf xs ks ys kk ha hrest
        rw [rk_nt S corr eps hx]
        refine ⟨.nt hx (by rw [l1, hl, hxy.2]) w1 w2, ?_⟩
        simp only [ayields, hx, ite_true, hxy.1, y1, y2]
    · have hx' : S.isNt x = false := by simpa using hx
      simp only [hx', Bool.false_eq_true, ite_false, Bool.and_eq_true, Bool.not_eq_true', beq_iff_eq] at hxy
      obtain ⟨hy, rfl⟩ := hxy
      cases hk with
      | nt hy' _ _ _ => rw [hy] at hy'; cases hy'
      | term _ hrest =>
        obtain ⟨w2, y2⟩ := rhoKids_wf xs ks ys kids ha hrest
        rw [rk_term S corr eps hx']
        refine ⟨.term hx' w2, ?_⟩
        rw [ayields.eq_def, ayields.eq_def]
        simp only [hx', hy, Bool.false_eq_true, ite_false, y2]
  | x :: xs, false :: ks, ys, kids, ha, hk => by
    simp only [alignOk, Bool.and_eq_true] at ha
    obtain ⟨⟨hx, he⟩, ha⟩ := ha
    obtain ⟨w1, l1, y1⟩ := eps_ok G S corr base eps hc he
    obtain ⟨w2, y2⟩ := rhoKids_wf xs ks ys kids ha hk
    rw [rk_drop]
    refine ⟨.nt hx l1 w1 w2, ?_⟩
    simp only [ayields, hx, ite_true, y1, y2, List.nil_append]
  | [], [], _ :: _, _, ha, _ => by simp [alignOk] at ha
  | [], _ :: _, _, _, ha, _ => by simp [alignOk] at ha
  | _ :: _, [], _, _, ha, _ => by simp [alignOk] at ha
  | _ :: _, true :: _, [], _, ha, _ => by simp [alignOk] at ha
  termination_by xs keep ys kids => (sizeOf kids, xs.length)
end

/-- **The GLR result, read in the source grammar.** If the rewritten grammar's
accepted relation is unambiguous, the source trees that `rho` reads off its
accepted trees are source derivations of the same tokens, rooted at the source
start symbol, and at most one for any token string. -/
theorem glr_source (hwf : G.wf = true) (hU : AUnambiguous G) :
    (∀ t, Accepted G t → AWF S (rho S corr eps t) ∧
      (rho S corr eps t).yield S = t.yield G ∧ S.lhs (rho S corr eps t).prod = S.start) ∧
    (∀ t₁ t₂, Accepted G t₁ → Accepted G t₂ →
      (rho S corr eps t₁).yield S = (rho S corr eps t₂).yield S → rho S corr eps t₁ = rho S corr eps t₂) := by
  have hst : baseOf base G.start = S.start := by
    unfold checkCorr at hc; simp only [Bool.and_eq_true, beq_iff_eq] at hc; exact hc.2
  refine ⟨fun t ht => ?_, fun t₁ t₂ h₁ h₂ hy => ?_⟩
  · obtain ⟨w, y, l⟩ := rho_wf G S corr base eps hc t (acc_awf G hwf ht.1)
    exact ⟨w, y, by rw [l, ht.2.1, hst]⟩
  · have y₁ := (rho_wf G S corr base eps hc t₁ (acc_awf G hwf h₁.1)).2.1
    have y₂ := (rho_wf G S corr base eps hc t₂ (acc_awf G hwf h₂.1)).2.1
    rw [hU t₁ t₂ h₁ h₂ (by rw [← y₁, ← y₂, hy])]

end

end Ambiguity

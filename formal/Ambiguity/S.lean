/-!
# The capped counting semiring

`S = {0, 1, 2}` where `2` means "at least two". It is the quotient of `ℕ` by
the congruence that identifies every number `≥ 2`, so it is a commutative
semiring and `n ↦ min n 2` is a homomorphism.
-/

namespace Ambiguity

abbrev Tok := String

inductive S where
  | z | o | m
  deriving DecidableEq, Repr, Inhabited, Hashable, Ord

namespace S

def toNat : S → Nat
  | z => 0 | o => 1 | m => 2

def add : S → S → S
  | z, b => b
  | a, z => a
  | _, _ => m

def mul : S → S → S
  | z, _ => z
  | _, z => z
  | o, b => b
  | a, o => a
  | m, m => m

instance : Add S := ⟨add⟩
instance : Mul S := ⟨mul⟩
instance : OfNat S 0 := ⟨z⟩
instance : OfNat S 1 := ⟨o⟩
instance : OfNat S 2 := ⟨m⟩
instance : LE S := ⟨fun a b => a.toNat ≤ b.toNat⟩
instance (a b : S) : Decidable (a ≤ b) := inferInstanceAs (Decidable (a.toNat ≤ b.toNat))

/-- Capping a natural number. -/
def cap (n : Nat) : S := if n = 0 then z else if n = 1 then o else m

theorem zero_def : (0 : S) = z := rfl
theorem one_def : (1 : S) = o := rfl
theorem two_def : (2 : S) = m := rfl
theorem add_def (a b : S) : a + b = add a b := rfl
theorem mul_def (a b : S) : a * b = mul a b := rfl
theorem le_def (a b : S) : (a ≤ b) = (a.toNat ≤ b.toNat) := rfl

theorem add_comm (a b : S) : a + b = b + a := by cases a <;> cases b <;> rfl
theorem add_assoc (a b c : S) : a + b + c = a + (b + c) := by
  cases a <;> cases b <;> cases c <;> rfl
theorem mul_comm (a b : S) : a * b = b * a := by cases a <;> cases b <;> rfl
theorem mul_assoc (a b c : S) : a * b * c = a * (b * c) := by
  cases a <;> cases b <;> cases c <;> rfl
theorem mul_add (a b c : S) : a * (b + c) = a * b + a * c := by
  cases a <;> cases b <;> cases c <;> rfl
theorem add_mul (a b c : S) : (a + b) * c = a * c + b * c := by
  cases a <;> cases b <;> cases c <;> rfl
@[simp] theorem zero_add (a : S) : 0 + a = a := by cases a <;> rfl
@[simp] theorem add_zero (a : S) : a + 0 = a := by cases a <;> rfl
@[simp] theorem zero_mul (a : S) : 0 * a = 0 := by cases a <;> rfl
@[simp] theorem mul_zero (a : S) : a * 0 = 0 := by cases a <;> rfl
@[simp] theorem one_mul (a : S) : 1 * a = a := by cases a <;> rfl
@[simp] theorem mul_one (a : S) : a * 1 = a := by cases a <;> rfl

@[simp] theorem le_refl (a : S) : a ≤ a := Nat.le_refl _
theorem le_trans {a b c : S} : a ≤ b → b ≤ c → a ≤ c := Nat.le_trans
@[simp] theorem zero_le (a : S) : 0 ≤ a := Nat.zero_le _
theorem le_zero {a : S} : a ≤ 0 → a = 0 := by cases a <;> decide
theorem le_two (a : S) : a ≤ 2 := by cases a <;> decide
theorem add_le_add {a b c d : S} : a ≤ b → c ≤ d → a + c ≤ b + d := by
  cases a <;> cases b <;> cases c <;> cases d <;> decide
theorem mul_le_mul {a b c d : S} : a ≤ b → c ≤ d → a * c ≤ b * d := by
  cases a <;> cases b <;> cases c <;> cases d <;> decide
theorem le_add_right (a b : S) : a ≤ a + b := by cases a <;> cases b <;> decide
theorem le_add_left (a b : S) : b ≤ a + b := by cases a <;> cases b <;> decide
theorem add_le {a b c : S} : a + b ≤ c → a ≤ c ∧ b ≤ c := by
  cases a <;> cases b <;> cases c <;> decide
theorem le_antisymm {a b : S} : a ≤ b → b ≤ a → a = b := by
  cases a <;> cases b <;> decide
/-- Two summands that are each at least one sum to "many". -/
theorem one_add_one {a b : S} : 1 ≤ a → 1 ≤ b → a + b = 2 := by
  cases a <;> cases b <;> decide

instance : Std.Associative (α := S) (· + ·) := ⟨add_assoc⟩
instance : Std.Commutative (α := S) (· + ·) := ⟨add_comm⟩

end S

/-! ## Finite sums -/

/-- Sum of `f` over a list. -/
def sumL {α : Type} (l : List α) (f : α → S) : S :=
  l.foldr (fun a acc => f a + acc) 0

@[simp] theorem sumL_nil {α} (f : α → S) : sumL [] f = 0 := rfl
@[simp] theorem sumL_cons {α} (a : α) (l : List α) (f : α → S) :
    sumL (a :: l) f = f a + sumL l f := rfl

theorem sumL_append {α} (l₁ l₂ : List α) (f : α → S) :
    sumL (l₁ ++ l₂) f = sumL l₁ f + sumL l₂ f := by
  induction l₁ with
  | nil => simp
  | cons a l ih => simp [ih, S.add_assoc]

theorem sumL_le_sumL {α} (l : List α) {f g : α → S} (h : ∀ a ∈ l, f a ≤ g a) :
    sumL l f ≤ sumL l g := by
  induction l with
  | nil => exact S.le_refl _
  | cons a l ih =>
    simp only [sumL_cons]
    exact S.add_le_add (h a (by simp)) (ih fun x hx => h x (by simp [hx]))

theorem sumL_zero {α} (l : List α) {f : α → S} (h : ∀ a ∈ l, f a = 0) : sumL l f = 0 := by
  induction l with
  | nil => rfl
  | cons a l ih =>
    simp only [sumL_cons, h a (by simp), S.zero_add]
    exact ih fun x hx => h x (by simp [hx])

theorem sumL_add {α} (l : List α) (f g : α → S) :
    sumL l (fun a => f a + g a) = sumL l f + sumL l g := by
  induction l with
  | nil => rfl
  | cons a l ih =>
    simp only [sumL_cons, ih]
    -- (fa + ga) + (Sf + Sg) = (fa + Sf) + (ga + Sg)
    cases f a <;> cases g a <;> cases sumL l f <;> cases sumL l g <;> rfl

theorem mul_sumL {α} (c : S) (l : List α) (f : α → S) :
    c * sumL l f = sumL l (fun a => c * f a) := by
  induction l with
  | nil => simp
  | cons a l ih => simp only [sumL_cons, S.mul_add, ih]

theorem sumL_mul {α} (c : S) (l : List α) (f : α → S) :
    sumL l f * c = sumL l (fun a => f a * c) := by
  rw [S.mul_comm, mul_sumL]; simp only [S.mul_comm c]

theorem sumL_comm {α β} (l₁ : List α) (l₂ : List β) (f : α → β → S) :
    sumL l₁ (fun a => sumL l₂ (fun b => f a b)) = sumL l₂ (fun b => sumL l₁ (fun a => f a b)) := by
  induction l₁ with
  | nil => simp [sumL_zero]
  | cons a l ih => simp only [sumL_cons, ih, sumL_add]

theorem le_sumL {α} {l : List α} {a : α} (h : a ∈ l) (f : α → S) : f a ≤ sumL l f := by
  induction l with
  | nil => cases h
  | cons b l ih =>
    simp only [sumL_cons]
    cases h with
    | head => exact S.le_add_right _ _
    | tail _ h => exact S.le_trans (ih h) (S.le_add_left _ _)

/-- Sums over `l` are equal when the summands agree on every element of `l`. -/
theorem sumL_congr {α} (l : List α) {f g : α → S} (h : ∀ a ∈ l, f a = g a) :
    sumL l f = sumL l g := by
  induction l with
  | nil => rfl
  | cons a l ih => simp only [sumL_cons, h a (by simp), ih fun x hx => h x (by simp [hx])]

end Ambiguity

import Ambiguity.Product
import Ambiguity.Vpa

/-!
# Structured words

A token word whose brackets match is a list of `Item`s. `flatten` forgets the
structure; on proper item lists (brackets only as group delimiters) it is
injective, because `parseSeq` recovers the structure.
-/

namespace Ambiguity

mutual
def Item.flat : Item → List Tok
  | .tok a => [a]
  | .grp o v c => o :: flatten v ++ [c]
def flatten : List Item → List Tok
  | [] => []
  | x :: xs => x.flat ++ flatten xs
end

mutual
def Item.proper : Item → Bool
  | .tok a => !isOpen a && !isClose a
  | .grp o v c => closerOf o == some c && properL v
def properL : List Item → Bool
  | [] => true
  | x :: xs => x.proper && properL xs
end

theorem open_not_close {a : Tok} (h : isOpen a = true) : isClose a = false := by
  unfold isOpen closerOf bracketPairs at h
  unfold isClose bracketPairs
  simp only [List.lookup, beq_iff_eq] at h
  split at h <;> (try split at h) <;> (try split at h) <;> (try split at h) <;> simp_all

theorem close_of_closer {o c : Tok} (h : closerOf o = some c) : isClose c = true := by
  unfold closerOf bracketPairs at h
  unfold isClose bracketPairs
  simp only [List.lookup, beq_iff_eq] at h
  split at h <;> (try split at h) <;> (try split at h) <;> (try split at h) <;> simp_all

theorem open_of_closer {o c : Tok} (h : closerOf o = some c) : isOpen o = true := by
  unfold isOpen; rw [h]; rfl

/-- Parse items until a closing bracket or the end. -/
def parseSeq : Nat → List Tok → Option (List Item × List Tok)
  | 0, _ => none
  | _ + 1, [] => some ([], [])
  | fuel + 1, a :: rest =>
    if isClose a then some ([], a :: rest)
    else if isOpen a then
      match parseSeq fuel rest with
      | some (v, c :: rest') =>
        if closerOf a = some c then
          match parseSeq fuel rest' with
          | some (more, r) => some (.grp a v c :: more, r)
          | none => none
        else none
      | _ => none
    else
      match parseSeq fuel rest with
      | some (more, r) => some (.tok a :: more, r)
      | none => none

def stopper (r : List Tok) : Prop := r = [] ∨ ∃ c rest, r = c :: rest ∧ isClose c = true

mutual
def Item.sz' : Item → Nat
  | .tok _ => 1
  | .grp _ v _ => 2 + itemsSz' v
def itemsSz' : List Item → Nat
  | [] => 0
  | x :: xs => x.sz' + itemsSz' xs
end

theorem flatten_length : ∀ (u : List Item), (flatten u).length = itemsSz' u
  | [] => rfl
  | .tok _ :: xs => by simp [flatten, Item.flat, itemsSz', Item.sz', flatten_length xs]; omega
  | .grp _ v _ :: xs => by
    simp [flatten, Item.flat, itemsSz', Item.sz', flatten_length xs, flatten_length v]; omega

theorem parse_flatten : ∀ (k : Nat) (u : List Item), itemsSz' u ≤ k → properL u = true →
    ∀ (r : List Tok) (fuel : Nat), stopper r → itemsSz' u < fuel →
      parseSeq fuel (flatten u ++ r) = some (u, r) := by
  intro k
  induction k with
  | zero =>
    intro u hu _ r fuel hr hf
    cases u with
    | cons x xs => cases x <;> simp [itemsSz', Item.sz'] at hu <;> omega
    | nil =>
      obtain ⟨fuel', rfl⟩ : ∃ f', fuel = f' + 1 := ⟨fuel - 1, by omega⟩
      rcases hr with rfl | ⟨c, rest, rfl, hc⟩
      · rfl
      · simp [flatten, parseSeq, hc]
  | succ k ih =>
    intro u hu hp r fuel hr hf
    obtain ⟨fuel', rfl⟩ : ∃ f', fuel = f' + 1 := ⟨fuel - 1, by omega⟩
    cases u with
    | nil =>
      rcases hr with rfl | ⟨c, rest, rfl, hc⟩
      · rfl
      · simp [flatten, parseSeq, hc]
    | cons x xs =>
      simp only [properL, Bool.and_eq_true] at hp
      cases x with
      | tok a =>
        simp only [Item.proper, Bool.and_eq_true, Bool.not_eq_true'] at hp
        have hxs := ih xs (by simp [itemsSz', Item.sz'] at hu; omega) hp.2 r fuel' hr
          (by simp [itemsSz', Item.sz'] at hf; omega)
        simp only [flatten, Item.flat, List.cons_append, parseSeq, hp.1.1,
          hp.1.2, Bool.false_eq_true, ite_false, List.nil_append, hxs]
      | grp o v c =>
        simp only [Item.proper, Bool.and_eq_true, beq_iff_eq] at hp
        obtain ⟨⟨hoc, hv⟩, hxs⟩ := hp
        have hcl := close_of_closer hoc
        have hop := open_of_closer hoc
        have hnc := open_not_close hop
        simp only [itemsSz', Item.sz'] at hu hf
        have hin := ih v (by omega) hv (c :: (flatten xs ++ r)) fuel' (Or.inr ⟨c, _, rfl, hcl⟩) (by omega)
        have hre := ih xs (by omega) hxs r fuel' hr (by omega)
        have e : flatten (Item.grp o v c :: xs) ++ r = o :: (flatten v ++ c :: (flatten xs ++ r)) := by
          simp [flatten, Item.flat]
        rw [e]
        simp only [parseSeq, hnc, hop, Bool.false_eq_true, ite_false, ite_true, hin, hoc, hre]

theorem flatten_inj {u₁ u₂ : List Item} (h₁ : properL u₁ = true) (h₂ : properL u₂ = true)
    (h : flatten u₁ = flatten u₂) : u₁ = u₂ := by
  have l₁ := flatten_length u₁
  have l₂ := flatten_length u₂
  have p₁ := parse_flatten _ u₁ (Nat.le_refl _) h₁ [] (itemsSz' u₁ + itemsSz' u₂ + 1) (Or.inl rfl) (by omega)
  have p₂ := parse_flatten _ u₂ (Nat.le_refl _) h₂ [] (itemsSz' u₁ + itemsSz' u₂ + 1) (Or.inl rfl) (by omega)
  rw [h] at p₁
  rw [p₁] at p₂
  simpa using p₂

end Ambiguity

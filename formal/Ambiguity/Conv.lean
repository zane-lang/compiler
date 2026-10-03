import Ambiguity.HorizSound

/-!
# Convolution over splits

`conv f g u` sums `f u₁ * g u₂` over the ways to write `u = u₁ ++ u₂`.
It is associative, which lets a rule body be read one symbol at a time from
either end.
-/

namespace Ambiguity

def conv (f g : List Item → S) (u : List Item) : S :=
  sumL (splits u) fun p => f p.1 * g p.2

def delta (u : List Item) : S := if u.isEmpty then 1 else 0

theorem splits_nil : splits [] = [([], [])] := rfl

theorem splits_cons (x : Item) (u : List Item) :
    splits (x :: u) = ([], x :: u) :: (splits u).map fun p => (x :: p.1, p.2) := by
  unfold splits
  rw [List.length_cons, List.range_succ_eq_map, List.map_cons, List.map_map, List.map_map]
  congr 1

theorem conv_nil (f g : List Item → S) : conv f g [] = f [] * g [] := by
  simp [conv, splits_nil]

theorem conv_cons (f g : List Item → S) (x : Item) (u : List Item) :
    conv f g (x :: u) = f [] * g (x :: u) + conv (fun v => f (x :: v)) g u := by
  unfold conv
  rw [splits_cons, sumL_cons, sumL_map]

theorem conv_congr {f f' g g' : List Item → S} (hf : ∀ v, f v = f' v) (hg : ∀ v, g v = g' v) (u : List Item) :
    conv f g u = conv f' g' u := by
  unfold conv; apply sumL_congr; intro p _; rw [hf, hg]

theorem conv_mono {f f' g g' : List Item → S} (hf : ∀ v, f v ≤ f' v) (hg : ∀ v, g v ≤ g' v) (u : List Item) :
    conv f g u ≤ conv f' g' u := by
  unfold conv; apply sumL_le_sumL; intro p _; exact S.mul_le_mul (hf _) (hg _)

theorem conv_add_left (f h g : List Item → S) (u : List Item) :
    conv (fun v => f v + h v) g u = conv f g u + conv h g u := by
  unfold conv; rw [← sumL_add]; apply sumL_congr; intro p _; rw [S.add_mul]

theorem conv_smul_left (a : S) (f g : List Item → S) (u : List Item) :
    conv (fun v => a * f v) g u = a * conv f g u := by
  unfold conv; rw [mul_sumL]; apply sumL_congr; intro p _; rw [S.mul_assoc]

theorem conv_assoc : ∀ (u : List Item) (f g h : List Item → S),
    conv f (conv g h) u = conv (conv f g) h u
  | [], f, g, h => by simp only [conv_nil, S.mul_assoc]
  | x :: u, f, g, h => by
    rw [conv_cons, conv_cons, conv_assoc u, conv_cons, conv_nil]
    have e : (fun v => conv f g (x :: v)) = fun v => f [] * g (x :: v) + conv (fun w => f (x :: w)) g v := by
      funext v; rw [conv_cons]
    rw [e, conv_add_left, conv_smul_left]
    have e2 : conv (fun v => g (x :: v)) h u = conv (fun w => g (x :: w)) h u := rfl
    rw [S.mul_add, S.add_assoc, S.mul_assoc]

theorem conv_delta_left (g : List Item → S) (u : List Item) : conv delta g u = g u := by
  cases u with
  | nil => simp [conv_nil, delta]
  | cons x u =>
    rw [conv_cons]
    have : conv (fun v => delta (x :: v)) g u = 0 := by
      unfold conv; apply sumL_zero; intro p _; simp [delta]
    rw [this]; simp [delta]

theorem conv_delta_right : ∀ (f : List Item → S) (u : List Item), conv f delta u = f u
  | f, [] => by simp [conv_nil, delta]
  | f, x :: u => by
    rw [conv_cons, conv_delta_right (fun v => f (x :: v)) u]
    simp [delta]

end Ambiguity

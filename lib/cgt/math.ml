(* The math functions of `@math$` (math.md §2), as a call to one names it. A
   function keeps its name across the scalars it takes: `abs`, `min` and
   `max` are one variant each for integers and floats alike, and codegen
   picks the instruction by the operands' type. *)

type fn =
  | Bit_and
  | Bit_or
  | Bit_xor
  | Bit_not
  | Shift_left
  | Shift_right
  | Shift_right_logical
  | Rotate_left
  | Rotate_right
  | Pop_count
  | Leading_zeros
  | Trailing_zeros
  | Abs
  | Min
  | Max
  | Sqrt
  | Floor
  | Ceil
  | Trunc
  | Round_even
  | Fma
  | Copy_sign
  | Cbrt
  | Sin
  | Cos
  | Tan
  | Asin
  | Acos
  | Atan
  | Atan2
  | Exp
  | Log
  | Pow
  | Hypot

let all =
  [
    Bit_and; Bit_or; Bit_xor; Bit_not; Shift_left; Shift_right; Shift_right_logical;
    Rotate_left; Rotate_right; Pop_count; Leading_zeros; Trailing_zeros; Abs; Min; Max;
    Sqrt; Floor; Ceil; Trunc; Round_even; Fma; Copy_sign; Cbrt; Sin; Cos; Tan; Asin; Acos;
    Atan; Atan2; Exp; Log; Pow; Hypot;
  ]

(* The name after `@math$`. *)
let name = function
  | Bit_and -> "bitAnd"
  | Bit_or -> "bitOr"
  | Bit_xor -> "bitXor"
  | Bit_not -> "bitNot"
  | Shift_left -> "shiftLeft"
  | Shift_right -> "shiftRight"
  | Shift_right_logical -> "shiftRightLogical"
  | Rotate_left -> "rotateLeft"
  | Rotate_right -> "rotateRight"
  | Pop_count -> "popCount"
  | Leading_zeros -> "leadingZeros"
  | Trailing_zeros -> "trailingZeros"
  | Abs -> "abs"
  | Min -> "min"
  | Max -> "max"
  | Sqrt -> "sqrt"
  | Floor -> "floor"
  | Ceil -> "ceil"
  | Trunc -> "trunc"
  | Round_even -> "roundEven"
  | Fma -> "fma"
  | Copy_sign -> "copySign"
  | Cbrt -> "cbrt"
  | Sin -> "sin"
  | Cos -> "cos"
  | Tan -> "tan"
  | Asin -> "asin"
  | Acos -> "acos"
  | Atan -> "atan"
  | Atan2 -> "atan2"
  | Exp -> "exp"
  | Log -> "log"
  | Pow -> "pow"
  | Hypot -> "hypot"

let of_name n = List.find_opt (fun f -> String.equal (name f) n) all

(* An approximate function's result is the C math library's where the
   program runs (math.md §2.6), so nothing computes one ahead of time. *)
let exact = function
  | Cbrt | Sin | Cos | Tan | Asin | Acos | Atan | Atan2 | Exp | Log | Pow | Hypot -> false
  | Bit_and | Bit_or | Bit_xor | Bit_not | Shift_left | Shift_right | Shift_right_logical
  | Rotate_left | Rotate_right | Pop_count | Leading_zeros | Trailing_zeros | Abs | Min | Max
  | Sqrt | Floor | Ceil | Trunc | Round_even | Fma | Copy_sign ->
      true

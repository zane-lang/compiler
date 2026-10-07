(* A decimal literal's value as an `@primitives$F32` (types.md §2.9): the
   single nearest the literal, ties to even. [float_of_string] rounds the
   decimal to a double first, and rounding that double to a single again is
   wrong in exactly one case: when the double lands on the midpoint between
   two singles, the literal may lie to one side of it, and the second rounding
   then breaks a tie the literal never had. The exact comparison below settles
   that case; every other double rounds to the same single the literal does.
   The text is the literal's digits and its `.`, with no sign. *)

(* A double rounded to the nearest single, ties to even. *)
let single f = Int32.float_of_bits (Int32.bits_of_float f)

(* A natural number as its decimal digits, most significant first, times a
   small factor. *)
let times digits k =
  let n = String.length digits in
  let out = Bytes.make (n + 2) '0' in
  let carry = ref 0 in
  for i = n - 1 downto 0 do
    let d = ((Char.code digits.[i] - 48) * k) + !carry in
    Bytes.set out (i + 2) (Char.chr (48 + (d mod 10)));
    carry := d / 10
  done;
  Bytes.set out 1 (Char.chr (48 + (!carry mod 10)));
  Bytes.set out 0 (Char.chr (48 + (!carry / 10)));
  Bytes.to_string out

let strip_leading s =
  let n = String.length s in
  let rec go i = if i < n - 1 && s.[i] = '0' then go (i + 1) else i in
  String.sub s (go 0) (n - go 0)

let strip_trailing s =
  let rec go n = if n > 0 && s.[n - 1] = '0' then go (n - 1) else n in
  String.sub s 0 (go (String.length s))

(* A finite, non-negative double as its exact decimal: the integer part and
   the fraction's digits. A double is m * 2^e, which is m * 5^-e / 10^-e when
   e is negative. *)
let exact f =
  let fraction, e = Float.frexp f in
  let m = Int64.of_float (Float.ldexp fraction 53) and e = e - 53 in
  let digits = ref (Int64.to_string m) in
  if e >= 0 then begin
    for _ = 1 to e do digits := times !digits 2 done;
    (strip_leading !digits, "")
  end
  else begin
    for _ = 1 to -e do digits := times !digits 5 done;
    let d = String.make (-e) '0' ^ !digits in
    let cut = String.length d - -e in
    (strip_leading (String.sub d 0 cut), strip_trailing (String.sub d cut (-e)))
  end

(* Which side of [f] the literal [text] lies on, as [compare] gives it. *)
let compare_decimal text f =
  let whole, fraction =
    match String.index_opt text '.' with
    | Some i -> (String.sub text 0 i, String.sub text (i + 1) (String.length text - i - 1))
    | None -> (text, "")
  in
  let whole = strip_leading (if whole = "" then "0" else whole) and fraction = strip_trailing fraction in
  let f_whole, f_fraction = exact f in
  let by_length = compare (String.length whole) (String.length f_whole) in
  if by_length <> 0 then by_length
  else
    let by_whole = compare whole f_whole in
    if by_whole <> 0 then by_whole
    else
      let width = max (String.length fraction) (String.length f_fraction) in
      let pad s = s ^ String.make (width - String.length s) '0' in
      compare (pad fraction) (pad f_fraction)

let to_single text =
  let d = float_of_string text in
  let r = single d in
  if (not (Float.is_finite d)) || d = r then r
  else
    (* The single on d's other side, and whether d sits halfway between. A
       literal has no sign, so both are non-negative and the next single up
       is one more in the bits; one past the largest finite single is its
       infinity, which is where rounding up from that midpoint goes. *)
    let step = if d > r then 1l else -1l in
    let other = Int32.float_of_bits (Int32.add (Int32.bits_of_float r) step) in
    let midpoint =
      if Float.is_finite other && Float.is_finite r then (r +. other) /. 2.
      else Float.ldexp 1. 128 -. Float.ldexp 1. 103
    in
    if midpoint <> d then r
    else
      match compare_decimal text d with
      | 0 -> r
      | c -> if c > 0 then Float.max r other else Float.min r other

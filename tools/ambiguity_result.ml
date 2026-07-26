(* Ambiguity findings and bounded-proof outcomes are successful results. The
   command's exit status reports only whether it completed, while stdout carries
   the result itself. *)
let exit code =
  match code with
  | 1 | 3 -> Stdlib.exit 0
  | code -> Stdlib.exit code

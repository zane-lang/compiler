(* Finite product of the exact-history exclusion trie and modular delimiter
   counts. Every balanced input has zero net counts, at every modulus. This
   rejects some incomplete histories without bounding depth or length; it
   does not enforce nesting order or replace the recursive balanced walk. *)

let modulus = match Sys.getenv_opt "AMBIGUITY_DELIMITER_MODULUS" with
  | None | Some "" -> 1
  | Some value -> (match int_of_string_opt value with
      | Some modulus when modulus >= 1 && modulus <= 8 -> modulus
      | _ -> invalid_arg "AMBIGUITY_DELIMITER_MODULUS must be an integer from 1 to 8")

type t = { history : History_filter.t; modulus : int; span : int }

let create ?(modulus = modulus) sentences =
  if modulus < 1 || modulus > 8 then invalid_arg "delimiter modulus out of range";
  { history = History_filter.create sentences; modulus;
    span = modulus * modulus * modulus }

let encode filter history counts =
  if filter.modulus = 1 then history else (history + 1) * filter.span + counts

let decode filter state =
  if filter.modulus = 1 then (state, 0)
  else (state / filter.span - 1, state mod filter.span)

let root filter = encode filter (History_filter.root filter.history) 0

let advance filter state token =
  let history, counts = decode filter state in
  let history = History_filter.advance filter.history history token in
  let component = match token with
    | "LPAREN" -> Some (1, 1) | "RPAREN" -> Some (1, -1)
    | "LBRACKET" -> Some (filter.modulus, 1)
    | "RBRACKET" -> Some (filter.modulus, -1)
    | "LCURLY" -> Some (filter.modulus * filter.modulus, 1)
    | "RCURLY" -> Some (filter.modulus * filter.modulus, -1)
    | _ -> None in
  let counts = match component with
    | None -> counts
    | Some (place, delta) ->
        let old = counts / place mod filter.modulus in
        let next = (old + delta + filter.modulus) mod filter.modulus in
        counts + (next - old) * place in
  encode filter history counts

let is_blocked filter state =
  let history, counts = decode filter state in
  counts <> 0 || History_filter.is_blocked filter.history history

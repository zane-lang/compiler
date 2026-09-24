let check condition message = if not condition then failwith message

let () =
  let empty = History_filter.create [] in
  check (History_filter.root empty = History_filter.other)
    "the disabled filter must add no extra history state";
  let filter =
    History_filter.create
      [ [ "AM"; "AO"; "A" ]; [ "AM"; "AO"; "A"; "B" ]; [ "AO"; "AM"; "A" ] ]
  in
  let step state token = History_filter.advance filter state token in
  let root = History_filter.root filter in
  let am = step root "AM" in
  let am_ao = step am "AO" in
  let am_ao_a = step am_ao "A" in
  check (am <> am_ao) "different prefixes must have different states";
  check (History_filter.is_blocked filter am_ao_a)
    "a blocked complete history must be marked";
  check (History_filter.is_blocked filter (step am_ao_a "B"))
    "a blocked prefix must retain its longer continuation";
  let ao = step root "AO" in
  let ao_am = step ao "AM" in
  check (History_filter.is_blocked filter (step ao_am "A"))
    "AM/AO permutations must have independent prefix states";
  let other = step am_ao_a "UNLISTED" in
  check (other = History_filter.other) "an unmatched history must enter Other";
  check (step other "AM" = other && step other "A" = other)
    "Other must be absorbing";
  check (not (History_filter.is_blocked filter other))
    "Other must contain only nonblocked histories";
  check (History_filter.state_count filter >= 8)
    "all distinct trie prefixes must remain represented";
  let parens = History_filter.create ~paren_limit:2 [ [ "X" ] ] in
  let next = History_filter.advance parens in
  let start = History_filter.root parens in
  check (History_filter.is_dead parens (next start "RPAREN"))
    "an unmatched closing parenthesis cannot begin a derivation";
  let one = next start "LPAREN" in
  check (History_filter.is_blocked parens one)
    "a known unclosed parenthesis cannot accept";
  check (next one "RPAREN" = next start "Y")
    "closing a known parenthesis restores zero depth outside the trie";
  check (History_filter.is_blocked parens (next start "X"))
    "the trie must still exclude a complete history";
  let unknown = next (next (next start "LPAREN") "LPAREN") "LPAREN" in
  check (not (History_filter.is_blocked parens unknown))
    "a saturated count cannot rule out a complete sentence";
  check (not (History_filter.is_dead parens
                 (next (next (next unknown "RPAREN") "RPAREN") "RPAREN")))
    "closing a saturated count cannot be treated as exact"

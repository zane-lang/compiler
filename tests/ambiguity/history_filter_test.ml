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
    "all distinct trie prefixes must remain represented"

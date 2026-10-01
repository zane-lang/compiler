open Ambiguity_engine

let run filter tokens = List.fold_left (Delimiter_history.advance filter)
    (Delimiter_history.root filter) tokens

let () =
  for modulus = 1 to 8 do
    let filter = Delimiter_history.create ~modulus [] in
    assert (not (Delimiter_history.is_blocked filter (run filter [])));
    let deep = List.init 100 (fun _ -> "LPAREN")
        @ ["LBRACKET"; "LCURLY"; "A"; "RCURLY"; "RBRACKET"]
        @ List.init 100 (fun _ -> "RPAREN") in
    assert (not (Delimiter_history.is_blocked filter (run filter deep)));
    if modulus > 1 then begin
      List.iter (fun token ->
        assert (Delimiter_history.is_blocked filter (run filter [token])))
        ["LPAREN"; "RPAREN"; "LBRACKET"; "RBRACKET"; "LCURLY"; "RCURLY"];
      (* Count congruence deliberately admits these non-Dyck histories. *)
      assert (not (Delimiter_history.is_blocked filter
        (run filter ["LPAREN"; "LBRACKET"; "RPAREN"; "RBRACKET"])));
      assert (not (Delimiter_history.is_blocked filter
        (run filter (List.init modulus (fun _ -> "LPAREN")))))
    end;
    let filter = Delimiter_history.create ~modulus
        [["LPAREN"; "A"; "RPAREN"]] in
    assert (Delimiter_history.is_blocked filter
      (run filter ["LPAREN"; "A"; "RPAREN"]));
    assert (not (Delimiter_history.is_blocked filter
      (run filter ["LPAREN"; "A"; "RPAREN"; "B"])));
    assert (not (Delimiter_history.is_blocked filter
      (run filter ["LPAREN"; "B"; "RPAREN"])))
  done

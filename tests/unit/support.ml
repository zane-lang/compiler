(* What every unit test file shares: [check] counts the failures [Unit]
   reports, and the helpers the tests of files use. *)

let failures = ref 0

let check name ok =
  if not ok then begin
    incr failures;
    Printf.printf "FAIL %s\n" name
  end

let raises_bug name f =
  check name (match f () with _ -> false | exception Diagnostic.Internal _ -> true)

(* What a file holds, or [None] when it is gone. *)
let read_all path =
  try Some (In_channel.with_open_bin path In_channel.input_all) with Sys_error _ -> None
let write_all path contents = Out_channel.with_open_bin path (fun oc -> output_string oc contents)

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Sys.rmdir path
  end
  else Sys.remove path

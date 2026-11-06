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

(* [f] given a `zig cc` command, which carries the C library's headers for
   every target, as a C compiler with no SDK or sysroot for one beside it
   has none: Mach-O's on any machine, glibc's on a Mac. On Windows the
   compiler runs it through cmd.exe, so it is a batch file. *)
let with_zig_cc f =
  let zig =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "zane-zig-cc-%d%s" (Unix.getpid ()) (if Sys.win32 then ".cmd" else ""))
  in
  Out_channel.with_open_bin zig (fun oc ->
      output_string oc
        (if Sys.win32 then "@echo off\r\nif defined ZIG (\"%ZIG%\" cc %*) else (zig cc %*)\r\n"
         else "#!/bin/sh\nexec \"${ZIG:-zig}\" cc \"$@\"\n"));
  Unix.chmod zig 0o755;
  Fun.protect ~finally:(fun () -> Sys.remove zig) (fun () -> f zig)

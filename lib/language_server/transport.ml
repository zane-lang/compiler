(* JSON-RPC over standard input and output, as the Language Server Protocol
   frames it: a `Content-Length` header, a blank line, and that many bytes of
   JSON.

   A thread reads messages into a queue, so the server can take every
   message that arrived while it was checking and act on the last edit only
   (docs/design/language-server.md, D10). *)

type message =
  | Request of { id : Yojson.Safe.t; method_ : string; params : Yojson.Safe.t }
  | Notification of { method_ : string; params : Yojson.Safe.t }
  | Response of { id : Yojson.Safe.t; result : Yojson.Safe.t }
  (* The input ended, or a frame could not be read. *)
  | Closed

let read_frame ic =
  let rec headers length =
    match In_channel.input_line ic with
    | None -> None
    | Some line ->
        let line = if String.ends_with ~suffix:"\r" line then String.sub line 0 (String.length line - 1) else line in
        if line = "" then length
        else
          let length =
            match String.index_opt line ':' with
            | Some i when String.lowercase_ascii (String.sub line 0 i) = "content-length" ->
                int_of_string_opt (String.trim (String.sub line (i + 1) (String.length line - i - 1)))
            | _ -> length
          in
          headers length
  in
  match headers None with
  | None -> None
  | Some n -> really_input_string ic n |> Option.some

let decode text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error _ -> None
  | json -> (
      let field name = match json with `Assoc fields -> List.assoc_opt name fields | _ -> None in
      let params = Option.value ~default:`Null (field "params") in
      match (field "id", field "method") with
      | Some id, Some (`String method_) -> Some (Request { id; method_; params })
      | None, Some (`String method_) -> Some (Notification { method_; params })
      | Some id, None -> Some (Response { id; result = Option.value ~default:`Null (field "result") })
      | _ -> None)

type queue = { messages : message Queue.t; lock : Mutex.t; arrived : Condition.t }

(* Starts the thread that reads [ic] into a new queue. *)
let start ic =
  let q = { messages = Queue.create (); lock = Mutex.create (); arrived = Condition.create () } in
  let push m =
    Mutex.lock q.lock;
    Queue.push m q.messages;
    Condition.signal q.arrived;
    Mutex.unlock q.lock
  in
  let rec loop () =
    match read_frame ic with
    (* Input the server cannot read, such as a negative Content-Length,
       ends it as the end of input does, rather than the thread alone. *)
    | exception _ -> push Closed
    | None -> push Closed
    | Some text ->
        (match decode text with Some m -> push m | None -> ());
        loop ()
  in
  ignore (Thread.create loop ());
  q

(* Every message waiting, after waiting for at least one. *)
let take q =
  Mutex.lock q.lock;
  while Queue.is_empty q.messages do
    Condition.wait q.arrived q.lock
  done;
  let all = List.of_seq (Queue.to_seq q.messages) in
  Queue.clear q.messages;
  Mutex.unlock q.lock;
  all

let write oc (json : Yojson.Safe.t) =
  let body = Yojson.Safe.to_string json in
  Printf.fprintf oc "Content-Length: %d\r\n\r\n%s" (String.length body) body;
  flush oc

let respond oc id result = write oc (`Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ])

let respond_error oc id ~code message =
  write oc
    (`Assoc
       [
         ("jsonrpc", `String "2.0");
         ("id", id);
         ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]);
       ])

let notify oc method_ params =
  write oc (`Assoc [ ("jsonrpc", `String "2.0"); ("method", `String method_); ("params", params) ])

let next_id = ref 0

let request oc method_ params =
  incr next_id;
  write oc
    (`Assoc [ ("jsonrpc", `String "2.0"); ("id", `Int !next_id); ("method", `String method_); ("params", params) ])

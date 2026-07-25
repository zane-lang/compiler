type item =
  | ILeaf of string * string
  | IContainer of string * item list

let rec collect ~name node =
  match node with
  | Node.Leaf v ->
      [ILeaf (name, v)]

  | Node.Group { title; body } ->
      let new_name = if name = "" then title else name ^ " > " ^ title in
      collect ~name:new_name body

  | Node.Fields map ->
      let nested_items =
        Node.StringMap.bindings map
        |> List.map (fun (k, v) -> collect ~name:k v)
        |> List.flatten
      in
      if name = "" then nested_items
      else [IContainer (name, nested_items)]

  | Node.Sequence list ->
      if list = [] then
        if name = "" then [] else [IContainer (name, [])]
      else
        List.mapi (fun i v ->
          let element_name =
            if name = "" then Printf.sprintf "[%d]" i
            else Printf.sprintf "%s[%d]" name i
          in
          collect ~name:element_name v
        ) list |> List.flatten

(* Renders into [buf] so callers decide where the tree goes: stdout, a file, or
   a test assertion. *)
let render_to_buffer buf root_node =
  let items = collect ~name:"" root_node in
  let rec add_items prefix items =
    let len = List.length items in
    List.iteri (fun i item ->
      let is_last = (i = len - 1) in
      let branch = if is_last then "└── " else "├── " in
      let nested_prefix = prefix ^ (if is_last then "    " else "│   ") in
      match item with
      | ILeaf (name, value) ->
          if name = "" then
            Buffer.add_string buf (Printf.sprintf "%s%s%s\n" prefix branch value)
          else
            Buffer.add_string buf
              (Printf.sprintf "%s%s%s: %s\n" prefix branch name value)
      | IContainer (name, nested_items) ->
          if name = "" then
            add_items prefix nested_items
          else begin
            Buffer.add_string buf
              (Printf.sprintf "%s%s%s:\n" prefix branch name);
            add_items nested_prefix nested_items
          end
    ) items
  in
  add_items "" items

let render root_node =
  let buf = Buffer.create 1024 in
  render_to_buffer buf root_node;
  Buffer.contents buf

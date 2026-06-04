type item =
  | ILeaf of string * string
  | IContainer of string * item list

let rec collect ~name node =
  match node with
  | Node.Leaf v ->
      [ILeaf (name, v)]
      
  | Node.Group { title; body } ->
      (* Chain group titles with " > " *)
      let new_name = if name = "" then title else name ^ " > " ^ title in
      collect ~name:new_name body
      
  | Node.Fields map ->
      let children =
        Node.StringMap.bindings map
        |> List.map (fun (k, v) -> collect ~name:k v)
        |> List.flatten
      in
      (* If it's the unnamed root, just return the children directly *)
      if name = "" then children
      else [IContainer (name, children)]
      
  | Node.Children list ->
      if list = [] then
        if name = "" then [] else [IContainer (name, [])]
      else
        List.mapi (fun i v ->
          let child_name =
            if name = "" then Printf.sprintf "[%d]" i
            else Printf.sprintf "%s[%d]" name i
          in
          collect ~name:child_name v
        ) list |> List.flatten

let render root_node =
  let items = collect ~name:"" root_node in
  let rec print_items prefix items =
    let len = List.length items in
    List.iteri (fun i item ->
      let is_last = (i = len - 1) in
      let branch = if is_last then "└── " else "├── " in
      let child_prefix = prefix ^ (if is_last then "    " else "│   ") in
      match item with
      | ILeaf (name, value) ->
          if name = "" then
            Printf.printf "%s%s%s\n" prefix branch value
          else
            Printf.printf "%s%s%s: %s\n" prefix branch name value
      | IContainer (name, children) ->
          if name = "" then
            print_items prefix children
          else begin
            Printf.printf "%s%s%s:\n" prefix branch name;
            print_items child_prefix children
          end
    ) items
  in
  print_items "" items

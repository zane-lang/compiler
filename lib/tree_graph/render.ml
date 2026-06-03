let render node =
  let rec render_fields prefix fields =
    let bindings = Node.StringMap.bindings fields in
    let len = List.length bindings in
    List.mapi (fun i (key, child) ->
      render_node prefix (i = len - 1) key child
    ) bindings |> String.concat "\n"

  and render_children prefix name children =
    let len = List.length children in
    List.mapi (fun i child ->
      let key = name ^ "[" ^ string_of_int i ^ "]" in
      render_node prefix (i = len - 1) key child
    ) children |> String.concat "\n"

  and render_node prefix is_last key node =
    let connector = if is_last then "└── " else "├── " in
    let next_prefix = prefix ^ (if is_last then "    " else "│   ") in
    match node with
    | Node.Leaf v ->
        prefix ^ connector ^ key ^ ": " ^ v
    | Node.Fields (_, fields) ->
        let header = prefix ^ connector ^ key ^ ":" in
        if Node.StringMap.is_empty fields then header
        else header ^ "\n" ^ render_fields next_prefix fields
    | Node.Children (name, children) ->
        let header = prefix ^ connector ^ key ^ ":" in
        if children = [] then header
        else header ^ "\n" ^ render_children next_prefix name children
  in
  match node with
  | Node.Leaf v -> v
  | Node.Fields (name, fields) ->
      let header = name ^ ":" in
      if Node.StringMap.is_empty fields then header
      else header ^ "\n" ^ render_fields "" fields
  | Node.Children (name, children) ->
      if children = [] then name ^ ":"
      else render_children "" name children

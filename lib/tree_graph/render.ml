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
    | Node.Group { title; body } ->
        let header = prefix ^ connector ^ key ^ " (" ^ title ^ "):" in
        header ^ "\n" ^ render_node next_prefix true "" body
    | Node.Fields fields ->
        if Node.StringMap.is_empty fields then
          prefix ^ connector ^ key
        else
          let header = prefix ^ connector ^ key ^ ":" in
          header ^ "\n" ^ render_fields next_prefix fields
    | Node.Children children ->
        if children = [] then
          prefix ^ connector ^ key
        else
          let header = prefix ^ connector ^ key ^ ":" in
          header ^ "\n" ^ render_children next_prefix key children
  in
  match node with
  | Node.Leaf v -> v
  | Node.Group { title; body } ->
      let header = "(" ^ title ^ "):" in
      header ^ "\n" ^ render_node "" true "" body
  | Node.Fields fields ->
      if Node.StringMap.is_empty fields then ""
      else render_fields "" fields
  | Node.Children children ->
      if children = [] then ""
      else render_children "" "item" children

(* Intermediate representation to flatten Children into their parent's scope *)
type item = 
  | ILeaf of string * string
  | IContainer of string * item list

let rec collect name = function
  | Node.Leaf v -> [ILeaf (name, v)]
  | Node.Group { title; body } -> collect title body
  | Node.Fields map ->
      let children = Node.StringMap.bindings map 
                     |> List.map (fun (k, v) -> collect k v) 
                     |> List.flatten in
      [IContainer (name, children)]
  | Node.Children list ->
      if list = [] then [IContainer (name, [])]
      else
        (* Flattens the list so elements become direct siblings of other Fields/Children *)
        List.mapi (fun i v ->
          let child_name = if name = "" then Printf.sprintf "[%d]" i else Printf.sprintf "%s[%d]" name i in
          collect child_name v
        ) list |> List.flatten

let render root_node =
  let items = collect "" root_node in
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
            (* Unnamed root container just prints its children without a header *)
            print_items prefix children
          else begin
            Printf.printf "%s%s%s:\n" prefix branch name;
            print_items child_prefix children
          end
    ) items
  in
  print_items "" items

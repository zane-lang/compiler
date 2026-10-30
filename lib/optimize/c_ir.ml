(* A package's C module as stage 5's C evaluator reads it
   (docs/design/ffi.md F16): each function and global the evaluator
   reaches, read once from the module through c_ir_stubs.cpp, which writes
   it out as text with every offset the target's data layout gives. *)

type ty =
  | Void
  | Int of int
  | Float
  | Double
  | Ptr
  | Vector of int * ty
  (* A struct, by its size, alignment and each field's offset and type. *)
  | Struct of { size : int; align : int; fields : (int * ty) array }
  (* An array of [count] elements [stride] bytes apart. *)
  | Array of { count : int; stride : int; align : int; elem : ty }
  (* A type the evaluator does not model, such as `x86_fp80`. *)
  | Other

type const =
  | Cint of int * int64
  | Cfloat of bool * int64 (* a double, and the bits *)
  | Cnull
  | Cundef of ty
  | Czero of ty
  | Cagg of ty * const array
  | Cfunction of string
  | Cglobal of string
  (* A constant address [offset] bytes from another's. *)
  | Cgep of const * int64
  | Ccast of string * ty * const
  | Cbinary of string * const * const
  (* A constant the evaluator does not model: a block's address, an
     integer wider than 64 bits. *)
  | Cother

type operand = Reg of int | Const of const | Asm | Metadata

type callee = Direct of string | Indirect of operand | Inline_asm

(* An instruction: its opcode as LLVM names it, its result type, its flags
   (c_ir_stubs.cpp), and what the opcode takes. *)
type op =
  | Plain of { pred : int; args : operand array }
  | Cast of { from : ty; arg : operand }
  | Alloca of { size : int; align : int; count : operand }
  | Load of { align : int; volatile : bool; atomic : bool; ptr : operand }
  | Store of { align : int; volatile : bool; atomic : bool; ty : ty; value : operand; ptr : operand }
  (* [base] plus [offset] plus each index, of its width, times its scale. *)
  | Gep of { base : operand; offset : int64; terms : (operand * int * int64) list }
  | Phi of (int * operand) list
  | Call of { callee : callee; args : (int * operand) list (* a `byval` argument's size, else -1 *) }
  | Extract of { indices : int list; agg : operand }
  | Insert of { indices : int list; agg : operand; value : operand }
  | Shuffle of { a : operand; b : operand; mask : int array }
  | Ret of operand option
  | Br of int
  | Cond_br of { cond : operand; yes : int; no : int }
  | Switch of { value : operand; default : int; cases : (int64 * int) list }
  | Unreachable
  | Unknown

type instr = { opcode : string; ty : ty; flags : int; op : op; reg : int }

let nsw = 1
let nuw = 2
let exact = 4
let disjoint = 8
let nneg = 16
let fast = 32
let has flag i = i.flags land flag <> 0

type func = { params : int; variadic : bool; ret : ty; blocks : instr array array }

(* ---------------------------------------------------------------------- *)
(* Reading the text                                                       *)
(* ---------------------------------------------------------------------- *)

exception Malformed

type reader = { text : string; mutable at : int }

let word r =
  let start = r.at in
  match String.index_from_opt r.text start ' ' with
  | Some e ->
      r.at <- e + 1;
      String.sub r.text start (e - start)
  | None when start < String.length r.text ->
      r.at <- String.length r.text;
      String.sub r.text start (r.at - start)
  | None -> raise Malformed

let num r = match Int64.of_string_opt (word r) with Some n -> n | None -> raise Malformed
let int r = Int64.to_int (num r)
let bool r = int r <> 0

let name r =
  let colon = String.index_from r.text r.at ':' in
  let n = int_of_string (String.sub r.text r.at (colon - r.at)) in
  let s = String.sub r.text (colon + 1) n in
  r.at <- colon + n + 2;
  s

let list n f = List.init n (fun _ -> f ())

let rec ty r =
  match word r with
  | "v" -> Void
  | "i" -> Int (int r)
  | "f" -> Float
  | "d" -> Double
  | "p" -> Ptr
  | "V" ->
      let n = int r in
      Vector (n, ty r)
  | "S" ->
      let size = int r in
      let align = int r in
      let n = int r in
      let fields =
        Array.of_list
          (list n (fun () ->
               let o = int r in
               (o, ty r)))
      in
      Struct { size; align; fields }
  | "A" ->
      let count = int r in
      let stride = int r in
      let align = int r in
      Array { count; stride; align; elem = ty r }
  | "o" -> Other
  | _ -> raise Malformed

let rec const r =
  match word r with
  | "i" ->
      let bits = int r in
      Cint (bits, num r)
  | "f" ->
      let double = bool r in
      Cfloat (double, num r)
  | "n" -> Cnull
  | "u" -> Cundef (ty r)
  | "z" -> Czero (ty r)
  | "a" ->
      let t = ty r in
      let n = int r in
      Cagg (t, Array.of_list (list n (fun () -> const r)))
  | "F" -> Cfunction (name r)
  | "g" -> Cglobal (name r)
  | "G" ->
      let base = const r in
      Cgep (base, num r)
  | "C" ->
      let op = word r in
      let t = ty r in
      Ccast (op, t, const r)
  | "B" ->
      let op = word r in
      let a = const r in
      Cbinary (op, a, const r)
  | "X" -> Cother
  | _ -> raise Malformed

let operand r =
  match word r with
  | "r" -> Reg (int r)
  | "c" -> Const (const r)
  | "a" -> Asm
  | "m" -> Metadata
  | _ -> raise Malformed

let plain = function
  | "add" | "sub" | "mul" | "udiv" | "sdiv" | "urem" | "srem" | "shl" | "lshr" | "ashr" | "and" | "or" | "xor"
  | "fadd" | "fsub" | "fmul" | "fdiv" | "frem" | "fneg" | "icmp" | "fcmp" | "select" | "freeze" | "extractelement"
  | "insertelement" ->
      true
  | _ -> false

let cast = function
  | "trunc" | "zext" | "sext" | "fptrunc" | "fpext" | "fptoui" | "fptosi" | "uitofp" | "sitofp" | "ptrtoint"
  | "inttoptr" | "bitcast" | "addrspacecast" ->
      true
  | _ -> false

let op r opcode =
  match opcode with
  | _ when plain opcode ->
      let pred = if opcode = "icmp" || opcode = "fcmp" then int r else 0 in
      let n = int r in
      Plain { pred; args = Array.of_list (list n (fun () -> operand r)) }
  | _ when cast opcode ->
      let from = ty r in
      Cast { from; arg = operand r }
  | "alloca" ->
      let size = int r in
      let align = int r in
      Alloca { size; align; count = operand r }
  | "load" ->
      let align = int r in
      let volatile = bool r in
      let atomic = bool r in
      Load { align; volatile; atomic; ptr = operand r }
  | "store" ->
      let align = int r in
      let volatile = bool r in
      let atomic = bool r in
      let ty = ty r in
      let value = operand r in
      Store { align; volatile; atomic; ty; value; ptr = operand r }
  | "getelementptr" -> (
      match word r with
      | "G" ->
          let base = operand r in
          let offset = num r in
          let n = int r in
          let terms =
            list n (fun () ->
                let o = operand r in
                let bits = int r in
                (o, bits, num r))
          in
          Gep { base; offset; terms }
      | _ -> Unknown)
  | "phi" ->
      let n = int r in
      Phi
        (list n (fun () ->
             let b = int r in
             (b, operand r)))
  | "call" ->
      let callee =
        match word r with
        | "d" -> Direct (name r)
        | "a" -> Inline_asm
        | "i" -> Indirect (operand r)
        | _ -> raise Malformed
      in
      let n = int r in
      Call
        {
          callee;
          args =
            list n (fun () ->
                let byval = int r in
                (byval, operand r));
        }
  | "extractvalue" ->
      let n = int r in
      let indices = list n (fun () -> int r) in
      Extract { indices; agg = operand r }
  | "insertvalue" ->
      let n = int r in
      let indices = list n (fun () -> int r) in
      let agg = operand r in
      Insert { indices; agg; value = operand r }
  | "shufflevector" ->
      let a = operand r in
      let b = operand r in
      let n = int r in
      Shuffle { a; b; mask = Array.of_list (list n (fun () -> int r)) }
  | "ret" -> if bool r then Ret (Some (operand r)) else Ret None
  | "br" ->
      if bool r then
        let cond = operand r in
        let yes = int r in
        Cond_br { cond; yes; no = int r }
      else Br (int r)
  | "switch" -> (
      match word r with
      | "S" ->
          let value = operand r in
          let default = int r in
          let n = int r in
          Switch
            {
              value;
              default;
              cases =
                list n (fun () ->
                    let v = num r in
                    (v, int r));
            }
      | _ -> Unknown)
  | "unreachable" -> Unreachable
  | _ ->
      ignore (word r);
      Unknown

let func text =
  let r = { text; at = 0 } in
  if word r <> "F" then raise Malformed;
  let params = int r in
  let variadic = bool r in
  let ret = ty r in
  let next = ref params in
  let nblocks = int r in
  let blocks =
    Array.init nblocks (fun _ ->
        let n = int r in
        Array.init n (fun _ ->
            let opcode = word r in
            let t = ty r in
            let flags = int r in
            let op = op r opcode in
            let reg = !next in
            incr next;
            { opcode; ty = t; flags; op; reg }))
  in
  { params; variadic; ret; blocks }

(* A global the module names: a variable it defines, with whether it is
   constant, thread-local, `unnamed_addr`, its alignment, size, type and
   initializer; an alias of a constant; one defined elsewhere; or a weak
   declaration, null where nothing defines it. *)
type global =
  | Variable of { constant : bool; thread_local : bool; unnamed : bool; align : int; size : int; ty : ty; init : const }
  | Alias of const
  | Elsewhere
  | Weak_global

let global text =
  let r = { text; at = 0 } in
  match word r with
  | "A" -> Alias (const r)
  | "D" -> Elsewhere
  | "W" -> Weak_global
  | "V" ->
      let constant = bool r in
      let thread_local = bool r in
      let unnamed = int r <> 0 in
      let align = int r in
      let size = int r in
      let t = ty r in
      Variable { constant; thread_local; unnamed; align; size; ty = t; init = const r }
  | _ -> raise Malformed

(* ---------------------------------------------------------------------- *)
(* The modules                                                            *)
(* ---------------------------------------------------------------------- *)

external layout_text : Llvm.llmodule -> string = "zane_c_ir_layout"
external function_text : Llvm.llmodule -> string -> string = "zane_c_ir_function"
external global_text : Llvm.llmodule -> string -> string = "zane_c_ir_global"

(* A function the modules name: one with a body, one only declared, with
   whether it never returns, or a weak declaration, null where nothing
   defines it. *)
type fn = Body of func | Declared of { noreturn : bool } | Weak

(* The program's C modules, which hold every package's C (and the
   retained ones of stamped dependencies), each name read from the first
   module that defines it and kept once read. *)
type t = {
  modules : Llvm.llmodule list;
  pointer_bits : int;
  little : bool;
  (* What the target puts before a symbol: `_` on Mach-O, nothing on ELF
     and 64-bit COFF. *)
  prefix : string;
  funcs : (string, fn option) Hashtbl.t;
  globals : (string, global option) Hashtbl.t;
}

let make modules =
  let pointer_bits, little, prefix =
    match modules with
    | m :: _ -> (
        match String.split_on_char ' ' (layout_text m) with
        | [ bits; little; prefix ] -> (int_of_string bits, little = "1", if prefix = "-" then "" else prefix)
        | _ -> raise Malformed)
    | [] -> (64, true, "")
  in
  { modules; pointer_bits; little; prefix; funcs = Hashtbl.create 64; globals = Hashtbl.create 64 }

(* The definition of [name] in the module holding one, else an
   `available_externally` copy of the library's (marked `E`), else its
   declaration in the first declaring it. Renaming gives every name with
   external linkage one module (F9), so a name two modules define is local
   to each, as a `static` function of the program's C and one of a retained
   dependency's may be: which the caller means is its own module's, which
   a name alone does not say, so reaching it stops. *)
let lookup t table read decode defines name =
  match Hashtbl.find_opt table name with
  | Some x -> x
  | None ->
      let texts = List.filter (fun s -> s <> "") (List.map (fun m -> read m name) t.modules) in
      let copy s = String.starts_with ~prefix:"E " s in
      let chosen =
        match List.filter (fun s -> defines s && not (copy s)) texts with
        | [ s ] -> Some s
        | [] -> (
            match List.find_opt copy texts with
            | Some s -> Some (String.sub s 2 (String.length s - 2))
            | None -> List.nth_opt texts 0)
        | _ -> Value.stop ("a name more than one module defines: " ^ name)
      in
      let x = Option.map decode chosen in
      Hashtbl.replace table name x;
      x

(* The IR name of a glue entry or a Zane function the glue names by an
   `__asm__` label [symbol] after the global prefix (docs/design/ffi.md
   F8): `\001` and the label where the target has a prefix, the label
   alone where it has none. *)
let labelled t symbol = if t.prefix = "" then symbol else "\001" ^ t.prefix ^ symbol

(* The symbol a labelled IR name stands for. *)
let unlabelled t name =
  let mark = "\001" ^ t.prefix in
  if t.prefix <> "" && String.starts_with ~prefix:mark name then
    String.sub name (String.length mark) (String.length name - String.length mark)
  else name

let fn t name =
  lookup t t.funcs function_text
    (fun s ->
      if s = "W" then Weak
      else if String.starts_with ~prefix:"D" s then Declared { noreturn = String.ends_with ~suffix:"1" s }
      else Body (func s))
    (fun s -> s <> "W" && not (String.starts_with ~prefix:"D" s))
    name

let global_of t name = lookup t t.globals global_text global (fun s -> s <> "D" && s <> "W") name

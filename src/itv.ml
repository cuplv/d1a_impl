(* Copyright (c) Benno Stein, 2020
 * me@bennostein.org
 * 
 * This source code is derived in part from the Interval domain of
 * Sledge (github.com/facebook/infer ./sledge directory), which is MIT Licensed.
 * As such, this source code is licensed under the same conditions:
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.

 *)

open Import
open Apron
open Option.Monad_infix

type t = Box.t Abstract1.t

let man = lazy (Box.manager_alloc ())

(* Do not eta-reduce!  Will break lazy manager allocation *)
let join l r = Abstract1.join (Lazy.force man) l r

(* Do not eta-reduce! Will break lazy manager allocation
   APRON widening argument order is reversed from my expectation; this function widens [l] by [r],
   treating [l] as the accumulated result of previous joins/widens and [r] as the newest element of that sequence *)
let widen l r = Abstract1.widening (Lazy.force man) r l

(* Do not eta-reduce!  Will break lazy manager allocation *)
let equal l r = Abstract1.is_eq (Lazy.force man) l r

(* Do not eta-reduce!  Will break lazy manager allocation *)
let is_bot itv = Abstract1.is_bottom (Lazy.force man) itv

(* Do not eta-reduce!  Will break lazy manager allocation *)
let implies l r = Abstract1.is_leq (Lazy.force man) l r

let bindings (itv : t) =
  let itv = Abstract1.minimize_environment (Lazy.force man) itv in
  let box = Abstract1.to_box (Lazy.force man) itv in
  let vars = Environment.vars box.box1_env |> uncurry Array.append in
  Array.zip_exn vars box.interval_array

let pp fs itv =
  if is_bot itv then Format.fprintf fs "bottom"
  else
    let pp_pair a_pp b_pp fs (a, b) = Format.fprintf fs "@[(%a@,%a)@]" a_pp a b_pp b in
    bindings itv |> Array.pp "@," (pp_pair Var.print Interval.print) fs

let sexp_of_t (itv : t) =
  let sexps =
    Array.fold (bindings itv) ~init:[] ~f:(fun acc (v, { inf; sup }) ->
        Sexp.List
          [
            Sexp.Atom (Var.to_string v);
            Sexp.Atom (Scalar.to_string inf);
            Sexp.Atom (Scalar.to_string sup);
          ]
        :: acc)
  in
  Sexp.List sexps

let t_of_sexp = function
  | Sexp.List sexps ->
      let constraint_of_sexp = function
        | Sexp.List [ Sexp.Atom v; Sexp.Atom inf; Sexp.Atom sup ] ->
            ( Var.of_string v,
              (Scalar.Float (Float.of_string inf), Scalar.Float (Float.of_string sup)) )
        | _ -> failwith "malformed interval sexp contents"
      in
      let vars, itvs =
        List.fold sexps ~init:([], []) ~f:(fun (v_acc, i_acc) sexp ->
            let v, (inf, sup) = constraint_of_sexp sexp in
            (v :: v_acc, Interval.of_infsup inf sup :: i_acc))
      in
      let vars = Array.of_list vars in
      let itvs = Array.of_list itvs in
      let env = Environment.make [||] vars in
      Abstract1.of_box (Lazy.force man) env vars itvs
  | _ -> failwith "malformed interval sexp"

let init () = Abstract1.top (Lazy.force man) (Environment.make [||] [||])

let apron_unop_of_unop = function
  | Ast.Unop.Neg -> Some Texpr1.Neg
  | op ->
      Format.fprintf Format.err_formatter "Unary op %a has no APRON equivalent" Ast.Unop.pp op;
      None

(* abstractly evaluate boolean binary operation [l op r] at interval [itv] by translating it to [(l - r) op 0]
   (since apron can only solve booleran constraints of that form), and intersecting the result with [itv].
   If that intersection is  ...
     ... bottom then expression is false
     ... equal to [itv] then expression is true
     ... anything else then the expression may be true or false
  Return that result as an apron interval constant: [0,0], [1,1], or [0,1] respectively.
*)
let mk_bool_binop itv op l r =
  let env = Abstract1.env itv in
  let l_minus_r = Texpr1.Binop (Texpr1.Sub, l, r, Texpr1.Double, Texpr1.Rnd) in
  let l_minus_r_op_0 = Tcons1.make (Texpr1.of_expr env l_minus_r) op in
  let tcons_array = Tcons1.array_make env 1 $> fun a -> Tcons1.array_set a 0 l_minus_r_op_0 in
  let intersection = Abstract1.meet_tcons_array (Lazy.force man) itv tcons_array in
  if is_bot intersection then Texpr1.Cst (Coeff.s_of_float 0.)
  else if equal intersection itv then Texpr1.Cst (Coeff.s_of_float 1.)
  else Texpr1.Cst (Coeff.i_of_float 0. 1.)

(* Helper function for [eval_expr], converts a native AST expression into an APRON tree expression *)
let rec texpr_of_expr itv =
  let open Ast in
  function
  | Expr.Var v -> Some (Texpr1.Var (Var.of_string v))
  | Expr.Lit (Int i) -> Some (Texpr1.Cst (Coeff.s_of_float (Float.of_int i)))
  | Expr.Lit (Float f) -> Some (Texpr1.Cst (Coeff.s_of_float f))
  | Expr.Lit _ -> None
  | Expr.Binop { l; op; r } -> (
      texpr_of_expr itv l >>= fun l ->
      texpr_of_expr itv r >>= fun r ->
      let mk_arith_binop op = Some (Texpr1.Binop (op, l, r, Texpr1.Double, Texpr0.Rnd)) in
      match op with
      | Plus -> mk_arith_binop Texpr1.Add
      | Minus -> mk_arith_binop Texpr1.Sub
      | Times -> mk_arith_binop Texpr1.Mul
      | Divided_by -> mk_arith_binop Texpr1.Div
      | Mod -> mk_arith_binop Texpr1.Mod
      | Eq -> Some (mk_bool_binop itv Tcons0.EQ l r)
      | NEq -> Some (mk_bool_binop itv Tcons0.DISEQ l r)
      | Gt -> Some (mk_bool_binop itv Tcons0.SUP l r)
      | Ge -> Some (mk_bool_binop itv Tcons0.SUPEQ l r)
      | Lt -> Some (mk_bool_binop itv Tcons0.SUP r l)
      | Le -> Some (mk_bool_binop itv Tcons0.SUPEQ r l)
      | _ ->
          Format.fprintf Format.err_formatter "Binary op %a has no APRON equivalent" Binop.pp op;
          None )
  | Expr.Unop { op; e } ->
      texpr_of_expr itv e >>= fun e ->
      apron_unop_of_unop op >>= fun op -> Some (Texpr1.Unop (op, e, Texpr1.Double, Texpr0.Rnd))

let eval_expr expr itv =
  let env = Abstract1.env itv in
  texpr_of_expr itv expr >>| (Texpr1.of_expr env >> Abstract1.bound_texpr (Lazy.force man) itv)

let interpret stmt itv =
  let open Ast.Stmt in
  match stmt with
  | Skip | Expr _ -> itv
  | Throw { exn = _ } -> Abstract1.bottom (Lazy.force man) (Abstract1.env itv)
  | Assume e -> (
      match eval_expr e itv with
      | Some cond when Interval.is_zero cond ->
          Abstract1.bottom (Lazy.force man) (Abstract1.env itv)
      | Some _ -> itv
      | None ->
          Format.fprintf Format.err_formatter
            "Unable to compute guard condition %a; assuming possibly true." Ast.Expr.pp e;
          itv )
  | Assign { lhs; rhs } -> (
      let lhs = Var.of_string lhs in
      let env = Abstract1.env itv in
      let new_env =
        if Environment.mem_var env lhs then env else Environment.add env [| lhs |] [||]
      in
      let itv_new_env = Abstract1.change_environment (Lazy.force man) itv new_env true in
      match texpr_of_expr itv rhs with
      | Some rhs_texpr ->
          Abstract1.assign_texpr (Lazy.force man) itv_new_env lhs
            (Texpr1.of_expr new_env rhs_texpr)
            None
      | None ->
          Format.fprintf Format.err_formatter "Unable to abstractly evaluate %a; sending to top"
            Ast.Expr.pp rhs;
          if Environment.mem_var env lhs then
            (* lhs was constrained, quantify that out *)
            Abstract1.forget_array (Lazy.force man) itv [| lhs |] false
          else (* lhs was unconstrained, treat as a `skip`*) itv )

let sanitize itv = itv

let show itv =
  pp Format.std_formatter itv;
  Format.flush_str_formatter ()

let hash seed itv = seeded_hash seed @@ Abstract1.hash (Lazy.force man) itv

let compare _l _r = failwith "todo"

let hash_fold_t h itv = Ppx_hash_lib.Std.Hash.fold_int h (hash 0 itv)
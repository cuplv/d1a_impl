open D1a
open Import
open Cfg_parser
open Ast

module Arr_bounds_check = struct
  include Daig.Make (Array_bounds)

  let array_accesses : Stmt.t -> (Expr.t * Expr.t) list =
    let rec expr_derefs = function
      | Expr.Deref { rcvr = _; field = Expr.Var "length" } -> []
      | Expr.Deref { rcvr; field } -> [ (rcvr, field) ]
      | Expr.Lit _ | Expr.Var _ -> []
      | Expr.Binop { l; op = _; r } -> List.append (expr_derefs l) (expr_derefs r)
      | Expr.Unop { op = _; e } -> expr_derefs e
      | Expr.Array { elts; alloc_site = _ } -> List.bind elts ~f:expr_derefs
    in
    function
    | Assign { lhs = _; rhs } -> expr_derefs rhs
    | Write { rcvr; field; rhs } -> (Expr.Var rcvr, field) :: expr_derefs rhs
    | Throw { exn } -> expr_derefs exn
    | Expr e | Assume e -> expr_derefs e
    | Skip -> []

  let check_all_accesses daig fs =
    let candidates : ((Expr.t * Expr.t) list * Ref.t) Seq.t =
      Seq.filter_map (G.nodes daig) ~f:(function
        | Ref.Stmt { stmt; name = _ } as refcell -> (
            match array_accesses stmt with [] -> None | accesses -> Some (accesses, refcell) )
        | _ -> None)
    in
    Seq.fold candidates ~init:daig ~f:(fun daig (accesses, stmt_ref) ->
        let astates_at_stmt_entry =
          Seq.bind (G.Node.succs stmt_ref daig) ~f:(fun poststate_ref ->
              Seq.filter ~f:Ref.is_astate (G.Node.preds poststate_ref daig))
        in
        List.fold accesses ~init:daig ~f:(fun daig ->
          function
          | Expr.Var rcvr, field ->
              Seq.fold astates_at_stmt_entry ~init:daig ~f:(fun daig ->
                function
                | Stmt _ -> failwith "unreachable by preceding filter on Ref.is_astate"
                | AState _ as astate_ref ->
                    time fs "computing abstract state and checking safety" ~x:astate_ref
                      ~f:(fun astate_ref ->
                        let astate_ref, daig = get astate_ref daig in
                        let _ = Ref.astate_exn astate_ref in
                        Format.fprintf fs
                          ( match Array_bounds.is_safe rcvr field (Ref.astate_exn astate_ref) with
                          | Some true -> "SAFE\t (Array access %s[%a] of statement at %a)\n"
                          | Some false -> "UNSAFE\t (Array access %s[%a] of statement at %a)\n"
                          | None -> "UNKNOWN\t (Array access %s[%a] of statement at %a)\n" )
                          rcvr Expr.pp field Daig.Name.pp (Ref.name stmt_ref);

                        daig))
          | rcvr, field ->
              Format.fprintf fs
                "UNKNOWN\t(Array access %a[%a] of statement at %a has too complex of a receiver)\n"
                Expr.pp rcvr Expr.pp field Daig.Name.pp (Ref.name stmt_ref);
              daig))
end

let test_array_accesses id =
  let cfg = (Util.test_case >> json_of_file >> cfg_of_json) id in
  Cfg.dump_dot cfg ~filename:(Util.cfg_output id);
  let daig = Arr_bounds_check.of_cfg cfg in
  Arr_bounds_check.dump_dot daig ~filename:(Util.daig_output id);
  let fs =
    Unix.openfile ~mode:[ Unix.O_WRONLY; Unix.O_CREAT ] (Util.log_output id)
    |> Unix.out_channel_of_descr |> Format.formatter_of_out_channel
  in
  let daig = Arr_bounds_check.check_all_accesses daig fs in
  Arr_bounds_check.dump_dot daig ~filename:(Util.daig_output (id ^ "_post"))

let%test "buckets tests" =
  test_array_accesses "buckets_swap1";
  test_array_accesses "buckets_swap2";
  test_array_accesses "buckets_swap3";
  test_array_accesses "buckets_swap4";
  true

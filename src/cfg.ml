open Import

module Loc = struct
  module T : sig
    type t [@@deriving equal, compare, hash, sexp]

    val entry : t

    val exit : t

    val fresh : unit -> t

    val sample : unit -> t
    (** Select at random a non-fresh location *)

    val of_int_unsafe : int -> t
    (** "Unsafe" in the sense that it can construct non-fresh names; future [fresh] names will still be fresh. *)

    val reset : unit -> unit

    val pp : t pp

    val to_string : t -> string
  end = struct
    type t = int [@@deriving equal, compare, hash, sexp]

    let entry = 0

    let exit = -1

    let next = ref 1

    let reset () = next := 1

    let of_int_unsafe i = i

    (** Use Splittable_random instead of Base.Random to avoid interfering with program edit generation for experiments  *)

    let rng_state = Splittable_random.State.of_int (Caml.Random.int 1000)

    let sample () = Splittable_random.int rng_state ~lo:0 ~hi:(pred !next)

    let fresh () =
      let curr = !next in
      next := curr + 1;
      curr

    let pp fs l =
      match l with
      | 0 -> Format.fprintf fs "entry"
      | -1 -> Format.fprintf fs "exit"
      | _ -> Format.fprintf fs "l%i" l

    let to_string l =
      pp Format.str_formatter l;
      Format.flush_str_formatter ()
  end

  include T

  module T_comparator : sig
    type t = T.t

    type comparator_witness

    val comparator : (t, comparator_witness) Comparator.t
  end = struct
    include T
    include Comparator.Make (T)
  end

  module Set = struct
    include (Set : module type of Set with type ('a, 'cmp) t := ('a, 'cmp) Set.t)

    type t = Set.M(T_comparator).t [@@deriving compare]

    let empty = Set.empty (module T_comparator)

    let singleton = Set.singleton (module T_comparator)
  end

  module Map = struct
    include (Map : module type of Map with type ('key, 'value, 'cmp) t := ('key, 'value, 'cmp) Map.t)

    type 'v t = 'v Map.M(T_comparator).t

    let empty = Map.empty (module T_comparator)
  end
end

module Fn = struct
  module T = struct
    type t = {
      name : string;
      formals : string list;
      locals : string list;
      entry : Loc.t;
      exit : Loc.t;
    }
    [@@deriving compare, equal, hash, sexp_of]

    let name { name; _ } = name

    let formals { formals; _ } = formals

    let locals { locals; _ } = locals

    let entry { entry; _ } = entry

    let exit { exit; _ } = exit

    let pp fs { name; formals; _ } =
      Format.fprintf fs "%s(%a)" name (List.pp ", " String.pp) formals

    let make ~name ~formals ~entry ~exit ~body =
      let locals =
        List.fold body ~init:[] ~f:(fun locals (_, _, stmt) ->
            Option.cons (Ast.Stmt.def stmt) locals)
      in
      { name; formals; locals; entry; exit }

    let defs { formals; locals; _ } = List.append formals locals
  end

  include T

  module T_comparator : sig
    type t = T.t

    type comparator_witness

    val comparator : (t, comparator_witness) Comparator.t
  end = struct
    include T
    include Comparator.Make (T)
  end

  module Set = struct
    include (Set : module type of Set with type ('a, 'cmp) t := ('a, 'cmp) Set.t)

    type t = Set.M(T_comparator).t [@@deriving compare]

    let empty = Set.empty (module T_comparator)

    let singleton = Set.singleton (module T_comparator)

    let of_list = Set.of_list (module T_comparator)
  end
end

module G =
  Graph.Make
    (struct
      include Regular.Std.Opaque.Make (Loc)

      type t = Loc.t
    end)
    (Ast.Stmt)

type t = G.t * Fn.Set.t

let src : G.Edge.t -> Loc.t = G.Edge.src

let dst : G.Edge.t -> Loc.t = G.Edge.dst

let empty () =
  Loc.reset ();
  Graph.create
    (module G)
    ~nodes:[ Loc.entry; Loc.exit ]
    ~edges:[ (Loc.entry, Loc.exit, Ast.Stmt.skip) ]
    ()
  |> flip pair Fn.Set.empty

(** Algorithm given in 2nd ed. Dragon book section 9.6.6, MODIFIED TO EXCLUDE THE LOOP HEAD ITSELF *)
let natural_loop backedge cfg =
  let rec nat_loop_impl (wl, loop) =
    if Set.is_empty wl then loop
    else
      let process_node acc loc =
        Seq.fold (G.Node.preds loc cfg) ~init:acc ~f:(fun (acc_wl, acc_loop) pred ->
            if
              not
                ( Loc.equal pred (src backedge)
                || Loc.equal pred (dst backedge)
                || Set.mem acc_loop pred )
            then (Set.add acc_wl pred, Set.add acc_loop pred)
            else (acc_wl, acc_loop))
      in
      nat_loop_impl (Set.fold wl ~init:(Loc.Set.empty, loop) ~f:process_node)
  in

  let loop_tail_singleton = Loc.Set.singleton (src backedge) in
  nat_loop_impl @@ pair loop_tail_singleton loop_tail_singleton

let back_edges =
  Graph.depth_first_search
    (module G)
    ~init:[]
    ~leave_edge:(fun kind e acc -> match kind with `Back -> e :: acc | _ -> acc)

let loop_heads = back_edges >> List.map ~f:dst

(** Map from locations to set of loop heads of containing loops.  Locations not in any loop are not in the domain, so [find_exn] is unsafe! *)
let containing_loop_heads cfg : Loc.Set.t Loc.Map.t =
  let back_edges = back_edges cfg in
  List.fold back_edges ~init:Loc.Map.empty ~f:(fun map backedge ->
      let head = dst backedge in
      Set.fold (natural_loop backedge cfg) ~init:map ~f:(fun map l ->
          let heads =
            match Map.find map l with
            | None -> Loc.Set.singleton head
            | Some heads -> Set.add heads head
          in
          Map.set map ~key:l ~data:heads))

(** Returns a partition of [cfg]'s nodes into non-join and join locations;
      the [fst] list returned contains all nodes with at most 1 incoming forward edge,
      and the [snd] contains those with 2 or more.
   *)
let locs_by_forward_indegree cfg : G.Node.t list * G.Node.t list =
  let back_edges = back_edges cfg in
  Graph.depth_first_search
    (module G)
    ~init:([], [])
    ~leave_node:(fun _order n (nj_acc, j_acc) ->
      let forward_indegree =
        Seq.count (G.Node.inputs n cfg) ~f:(List.mem back_edges ~equal:G.Edge.equal >> not)
      in
      if forward_indegree <= 1 then (n :: nj_acc, j_acc) else (nj_acc, n :: j_acc))
    cfg

let reachable_subgraph (cfg : G.t) ~(from : G.node) : G.t =
  let edges =
    Graph.fold_reachable
      (module G)
      cfg from ~init:[]
      ~f:(fun es n ->
        Seq.fold (G.Node.outputs n cfg) ~init:es ~f:(fun es e ->
            (G.Edge.src e, G.Edge.dst e, G.Edge.label e) :: es))
  in
  Graph.create (module G) ~edges ()

(** Add a [stmt]-labelled edge from [loc] in [cfg], preserving other structure.
    Returns: (G.t * Loc.t) pair of resulting CFG and newly-added location
*)
let add_stmt_at (loc : Loc.t) (stmt : Ast.Stmt.t) (cfg : G.t) =
  let new_loc = Loc.fresh () in
  flip pair new_loc
  @@
  (* if [loc] is a loop head or [Cfg.Loc.exit], add the statement _before_ [loc]; otherwise, add it after  *)
  if List.mem (loop_heads cfg) loc ~equal:G.Node.equal || Loc.(equal loc exit) then
    Seq.fold (G.Node.inputs loc cfg) ~init:cfg ~f:(fun cfg edge ->
        G.Edge.remove edge cfg |> G.Edge.(insert (create (src edge) new_loc (label edge))))
    |> G.Edge.(insert (create new_loc loc stmt))
  else
    Seq.fold (G.Node.outputs loc cfg) ~init:cfg ~f:(fun cfg edge ->
        G.Edge.remove edge cfg |> G.Edge.(insert (create new_loc (dst edge) (label edge))))
    |> G.Edge.(insert (create loc new_loc stmt))

let dump_dot ?print ~filename (cfg, fns) =
  let output_fd =
    if Option.is_some print then Unix.stdout else Unix.openfile ~mode:[ Unix.O_WRONLY ] "/dev/null"
  in
  Graph.to_dot
    (module G)
    cfg ~filename
    ~channel:(Unix.out_channel_of_descr output_fd)
    ~string_of_node:Loc.to_string
    ~string_of_edge:(G.Edge.label >> Ast.Stmt.to_string)
    ~node_attrs:(fun n ->
      match Set.find fns ~f:(Fn.entry >> Loc.equal n) with
      | Some fn ->
          let label =
            Format.fprintf Format.str_formatter "%a entry: %a" Fn.pp fn Loc.pp n;
            Format.flush_str_formatter ()
          in
          [ `Label label ]
      | None -> []);
  if Option.is_none print then Unix.close output_fd

(* module Interpreter (Dom : sig
     include Abstract.Dom
   end) =
     struct
       module G = Cfg(Dom.Stmt)
     module State = struct
       module T = struct
         type t = Loc.t * Dom.t [@@deriving compare, sexp]
       end

       include T
       include Comparable.Make (T)

       let pp fs (l, d) = Format.fprintf fs "%a -> %a" Loc.pp l Dom.pp d
     end

     let step cfg : State.t -> Set.M(State).t =
      fun (l, s) ->
       let interpret edge = (dst edge, Dom.interpret (G.Edge.label edge) s) in
       Seq.map ~f:interpret (G.Node.outputs l cfg)
       |> Seq.fold ~init:(Set.empty (module State)) ~f:Set.add

     (* fully path-sensitive; terminates iff cfg's state space is finite *)
     let collect (cfg : G.t) : Set.M(State).t =
       let worklist = ref (Set.singleton (module State) (Loc.entry, Dom.init ())) in
       let accum = ref !worklist in
       (* make a (nondeterministic) small step from [state];
        *  - add new non-bottom states to both the worklist and the collecting semantics
        *  - discard previously-seen/bottom states
        *)
       let process_state wl state =
         Set.fold (step cfg state) ~init:wl ~f:(fun wl s ->
             if Set.mem !accum s || Dom.is_bot (snd s) then wl
             else (
               accum := Set.add !accum s;
               Set.add wl s ))
       in
       while not @@ Set.is_empty !worklist do
         (* step all states in the worklist *)
         let new_worklist = Set.fold !worklist ~init:(Set.empty (module State)) ~f:process_state in
         worklist := new_worklist
       done;
       !accum
   end*)

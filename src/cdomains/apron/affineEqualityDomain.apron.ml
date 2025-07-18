(** OCaml implementation of the affine equalities domain.

    @see <https://doi.org/10.1007/BF00268497> Karr, M. Affine relationships among variables of a program. *)

(** There are two versions of the AffineEqualityDomain.
    Unlike the other version, this version here is NOT based on side effects.
    Abstract states in the newly added domain are represented by structs containing a matrix and an apron environment.
    Matrices are modeled as proposed by Karr: Each variable is assigned to a column and each row represents a linear affine relationship that must hold at the corresponding program point.
    The apron environment is hereby used to organize the order of columns and variables. *)

open GoblintCil
open Pretty

module M = Messages
open GobApron

open SparseVector
open ListMatrix

open Batteries

module Mpqf = SharedFunctions.Mpqf

module AffineEqualityMatrix (Vec: SparseVectorFunctor) (Mx: SparseMatrixFunctor) =
struct
  include Mx(Mpqf) (Vec)
  let dim_add (ch: Apron.Dim.change) m =
    add_empty_columns m ch.dim

  let dim_add ch m = timing_wrap "dim add" (dim_add ch) m


  let dim_remove (ch: Apron.Dim.change) m =
    if Array.length ch.dim = 0 || is_empty m then
      m
    else (
      let m' = Array.fold_left (fun y x -> reduce_col y x) m ch.dim in
      remove_zero_rows @@ del_cols m' ch.dim)

  let dim_remove ch m = timing_wrap "dim remove" (dim_remove ch) m
end

(** It defines the type t of the affine equality domain (a struct that contains an optional matrix and an apron environment) and provides the functions needed for handling variables (which are defined by RelationDomain.D2) such as add_vars remove_vars.
    Furthermore, it provides the function get_coeff_vec that parses an apron expression into a vector of coefficients if the apron expression has an affine form. *)
module VarManagement (Vec: SparseVectorFunctor) (Mx: SparseMatrixFunctor)=
struct
  module Vector = Vec (Mpqf)
  module Matrix = AffineEqualityMatrix (Vec) (Mx)

  let dim_add = Matrix.dim_add

  include SharedFunctions.VarManagementOps(AffineEqualityMatrix (Vec) (Mx))
  include RatOps.ConvenienceOps(Mpqf)

  (** Get the constant from the vector if it is a constant *)

  let to_constant_opt v = match Vector.find_first_non_zero v with
    | None -> Some Mpqf.zero
    | Some (i, value) when i = (Vector.length v) - 1 -> Some value
    | _ -> None

  let to_constant_opt v = timing_wrap "to_constant_opt" (to_constant_opt) v

  let get_coeff_vec (t: t) texp =
    (*Parses a Texpr to obtain a coefficient + const (last entry) vector to repr. an affine relation.
      Returns None if the expression is not affine*)
    let open Apron.Texpr1 in
    let exception NotLinear in
    let zero_vec = Vector.zero_vec @@ Environment.size t.env + 1 in
    let neg v = Vector.map_f_preserves_zero Mpqf.neg v in
    let is_const_vec = Vector.is_const_vec
    in
    let rec convert_texpr = function
      (*If x is a constant, replace it with its const. val. immediately*)
      | Cst x ->
        let of_union = function
          | Coeff.Interval _ -> failwith "Not a constant"
          | Scalar Float x -> Mpqf.of_float x
          | Scalar Mpqf x -> x
          | Scalar Mpfrf x -> Mpfr.to_mpq x
        in
        Vector.set_nth zero_vec ((Vector.length zero_vec) - 1) (of_union x)
      | Var x ->
        let entry_only v = Vector.set_nth v (Environment.dim_of_var t.env x) Mpqf.one in
        begin match t.d with
          | Some m ->
            let row = Matrix.find_opt (fun r -> Vector.nth r (Environment.dim_of_var t.env x) =: Mpqf.one) m in
            begin match row with
              | Some v when is_const_vec v ->
                Vector.set_nth zero_vec ((Vector.length zero_vec) - 1) (Vector.nth v (Vector.length v - 1))
              | _ -> entry_only zero_vec
            end
          | None -> entry_only zero_vec end
      | Unop (Neg, e, _, _) -> neg @@ convert_texpr e
      | Unop (Cast, e, _, _) -> convert_texpr e (*Ignore since casts in apron are used for floating point nums and rounding in contrast to CIL casts*)
      | Unop (Sqrt, e, _, _) -> raise NotLinear
      | Binop (Add, e1, e2, _, _) ->
        let v1 = convert_texpr e1 in
        let v2 = convert_texpr e2 in
        Vector.map2_f_preserves_zero (+:) v1 v2
      | Binop (Sub, e1, e2, _, _) ->
        let v1 = convert_texpr e1 in
        let v2 = convert_texpr e2 in
        Vector.map2_f_preserves_zero (+:) v1 (neg @@ v2)
      | Binop (Mul, e1, e2, _, _) ->
        let v1 = convert_texpr e1 in
        let v2 = convert_texpr e2 in
        begin match to_constant_opt v1, to_constant_opt v2 with
          | _, Some c -> Vector.apply_with_c_f_preserves_zero ( *:) c v1
          | Some c, _ -> Vector.apply_with_c_f_preserves_zero ( *:) c v2
          | _, _ -> raise NotLinear
        end
      | Binop _ -> raise NotLinear
    in
    try
      Some (convert_texpr texp)
    with NotLinear -> None

  let get_coeff_vec t texp = timing_wrap "coeff_vec" (get_coeff_vec t) texp
end

(** As it is specifically used for the new affine equality domain, it can only provide bounds if the expression contains known constants only and in that case, min and max are the same. *)
module ExpressionBounds (Vc: SparseVectorFunctor) (Mx: SparseMatrixFunctor): (SharedFunctions.ConvBounds with type t = VarManagement(Vc) (Mx).t) =
struct
  include VarManagement (Vc) (Mx)

  let bound_texpr t texpr =
    let texpr = Texpr1.to_expr texpr in
    match Option.bind (get_coeff_vec t texpr) to_constant_opt with
    | Some c when Mpqf.get_den c = Z.one ->
      let int_val = Mpqf.get_num c in
      Some int_val, Some int_val
    | _ -> None, None


  let bound_texpr d texpr1 =
    let res = bound_texpr d texpr1 in
    (if M.tracing then
       match res with
       | Some min, Some max -> M.tracel "bounds" "min: %a max: %a" GobZ.pretty min GobZ.pretty max
       | _ -> ()
    );
    res


  let bound_texpr d texpr1 = timing_wrap "bounds calculation" (bound_texpr d) texpr1
end

module D(Vc: SparseVectorFunctor) (Mx: SparseMatrixFunctor) =
struct
  include Printable.Std
  include RatOps.ConvenienceOps (Mpqf)
  include VarManagement (Vc) (Mx)

  module Bounds = ExpressionBounds (Vc) (Mx)
  module V = RelationDomain.V
  module Arg = struct
    let allow_global = true
  end
  module Convert = SharedFunctions.Convert (V) (Bounds) (Arg) (SharedFunctions.Tracked)


  type var = V.t

  let show t =
    let conv_to_ints row =
      let row = Array.copy @@ Vector.to_array row in
      let mpqf_of_z x = Mpqf.of_mpz @@ Z_mlgmpidl.mpzf_of_z x in
      let lcm = mpqf_of_z @@ Array.fold_left (fun x y -> Z.lcm x (Mpqf.get_den y)) Z.one row in
      Array.modify (( *:) lcm) row;
      let int_arr = Array.map Mpqf.get_num row in
      let div = Array.fold_left Z.gcd int_arr.(0) int_arr in
      if not @@ Z.equal div Z.zero then
        Array.modify (fun x -> Z.div x div) int_arr;
      int_arr
    in
    let vec_to_constraint arr env =
      let vars, _ = Environment.vars env in
      let dim_to_str var =
        let coeff =  arr.(Environment.dim_of_var env var) in
        if Z.equal coeff Z.zero then
          ""
        else
          let coeff_str =
            if Z.equal coeff Z.one then "+"
            else if Z.equal coeff Z.minus_one then "-"
            else if Z.lt coeff Z.minus_one then Z.to_string coeff
            else Format.asprintf "+%s" (Z.to_string coeff)
          in
          coeff_str ^ Var.show var
      in
      let const_to_str vl =
        if Z.equal vl Z.zero then
          ""
        else
          let negated = Z.neg vl in
          if Z.gt negated Z.zero then "+" ^ Z.to_string negated
          else Z.to_string negated
      in
      let res = (String.concat "" @@ Array.to_list @@ Array.map dim_to_str vars)
                ^ (const_to_str arr.(Array.length arr - 1)) ^ "=0" in
      if String.starts_with res "+" then
        Str.string_after res 1
      else
        res
    in
    match t.d with
    | None -> "Bottom Env"
    | Some m when Matrix.is_empty m -> "⊤"
    | Some m ->
      let constraint_list = List.init (Matrix.num_rows m) (fun i -> vec_to_constraint (conv_to_ints @@ Matrix.get_row m i) t.env) in
      "[|"^ (String.concat "; " constraint_list) ^"|]"

  let pretty () (x:t) = text (show x)
  let printXml f x = BatPrintf.fprintf f "<value>\n<map>\n<key>\nmatrix\n</key>\n<value>\n%s</value>\n<key>\nenv\n</key>\n<value>\n%a</value>\n</map>\n</value>\n" (XmlUtil.escape (show x)) Environment.printXml x.env
  let eval_interval ask = Bounds.bound_texpr

  let name () = "affeq"

  let to_yojson _ = failwith "ToDo Implement in future"


  let is_bot t = equal t (bot ())

  let bot_env = {d = None; env = Environment.make [||] [||]}

  let is_bot_env t = t.d = None

  let top () = {d = Some (Matrix.empty ()); env = Environment.make [||] [||]}

  let is_top t = Environment.equal empty_env t.env && GobOption.exists Matrix.is_empty t.d

  let is_top_env t = (not @@ Environment.equal empty_env t.env) && GobOption.exists Matrix.is_empty t.d

  let meet t1 t2 =
    let sup_env = Environment.lce t1.env t2.env in

    let t1, t2 = dimchange2_add t1 sup_env, dimchange2_add t2 sup_env in
    if is_bot t1 || is_bot t2 then
      bot ()
    else
      (* Option.get, because is_bot checks if t1.d is None and we checked is_bot before. *)
      let m1, m2 = Option.get t1.d, Option.get t2.d in
      if is_top_env t1 then
        {d = Some (dim_add (Environment.dimchange t2.env sup_env) m2); env = sup_env}
      else if is_top_env t2 then
        {d = Some (dim_add (Environment.dimchange t1.env sup_env) m1); env = sup_env}
      else
        match Matrix.rref_matrix m1 m2 with
        | None -> bot ()
        | rref_matr -> {d = rref_matr; env = sup_env}


  let meet t1 t2 =
    let res = meet t1 t2 in
    if M.tracing then M.tracel "meet" "meet a: %s b: %s -> %s " (show t1) (show t2) (show res) ;
    res

  let meet t1 t2 = timing_wrap "meet" (meet t1) t2

  let leq t1 t2 =
    let env_comp = Environment.cmp t1.env t2.env in (* Apron's Environment.cmp has defined return values. *)
    if env_comp = -2 || env_comp > 0 then
      (* -2:  environments are not compatible (a variable has different types in the 2 environements *)
      (* -1: if env1 is a subset of env2,  (OK)  *)
      (*  0:  if equality,  (OK) *)
      (* +1: if env1 is a superset of env2, and +2 otherwise (the lce exists and is a strict superset of both) *)
      false
    else if is_bot t1 || is_top_env t2 then
      true
    else if is_bot t2 || is_top_env t1 then
      false
    else
      let m1, m2 = Option.get t1.d, Option.get t2.d in
      let m1' = if env_comp = 0 then m1 else dim_add (Environment.dimchange t1.env t2.env) m1 in
      Matrix.is_covered_by m2 m1'

  let leq a b = timing_wrap "leq" (leq a) b

  let leq t1 t2 =
    let res = leq t1 t2 in
    if M.tracing then M.tracel "leq" "leq a: %s b: %s -> %b " (show t1) (show t2) res ;
    res

  let join a b =
    if is_bot a then
      b
    else if is_bot b then
      a
    else
      match Option.get a.d, Option.get b.d with
      | x, y when is_top_env a || is_top_env b -> {d = Some (Matrix.empty ()); env = Environment.lce a.env b.env}
      | x, y when (Environment.cmp a.env b.env <> 0) ->
        let sup_env = Environment.lce a.env b.env in
        let mod_x = dim_add (Environment.dimchange a.env sup_env) x in
        let mod_y = dim_add (Environment.dimchange b.env sup_env) y in
        {d = Some (Matrix.linear_disjunct mod_x mod_y); env = sup_env}
      | x, y when Matrix.equal x y -> {d = Some x; env = a.env}
      | x, y  -> {d = Some(Matrix.linear_disjunct x y); env = a.env}

  let join a b = timing_wrap "join" (join a) b

  let join a b =
    let res = join a b in
    if M.tracing then M.tracel "join" "join a: %s b: %s -> %s " (show a) (show b) (show res) ;
    res

  let widen a b =
    if Environment.equal a.env b.env then
      join a b
    else
      b

  let narrow a b = a

  let pretty_diff () (x, y) =
    dprintf "%s: %a not leq %a" (name ()) pretty x pretty y

  let remove_rels_with_var x var env =
    let j0 = Environment.dim_of_var env var in Matrix.reduce_col x j0

  let remove_rels_with_var x var env = timing_wrap "remove_rels_with_var" remove_rels_with_var x var env

  let forget_vars t vars =
    if is_bot t || is_top_env t || vars = [] then
      t
    else
      let m = Option.get t.d in
      let rem_from m = List.fold_left (fun m' x -> remove_rels_with_var m' x t.env) m vars in
      {d = Some (Matrix.remove_zero_rows @@ rem_from  m); env = t.env}

  let forget_vars t vars =
    let res = forget_vars t vars in
    if M.tracing then M.tracel "ops" "forget_vars %s -> %s" (show t) (show res);
    res

  let forget_vars t vars = timing_wrap "forget_vars" (forget_vars t) vars

  let assign_texpr (t: VarManagement(Vc)(Mx).t) var texp =
    let assign_invertible_rels x var b env =
      let j0 = Environment.dim_of_var env var in
      let a_j0 = Matrix.get_col_upper_triangular x j0  in (*Corresponds to Axj0*)
      let b0 = Vector.nth b j0 in
      let a_j0 = Vector.apply_with_c_f_preserves_zero (/:) b0 a_j0 in (*Corresponds to Axj0/Bj0*)
      let recalc_entries m rd_a = Matrix.map2 (fun x y -> Vector.map2i (fun j z d ->
          if j = j0 then y
          else if Vector.compare_length_with b (j + 1) > 0 then z -: y *: d
          else z +: y *: d) x b) m rd_a
      in
      let x = recalc_entries x a_j0 in
      match Matrix.normalize x with
      | None -> bot ()
      | some_normalized_matrix -> {d = some_normalized_matrix; env = env}
    in
    let assign_invertible_rels x var b env = timing_wrap "assign_invertible" (assign_invertible_rels x var b) env in
    let assign_uninvertible_rel x var b env =
      let b_length = Vector.length b in
      let b = Vector.mapi_f_preserves_zero (fun i z -> if i < b_length - 1 then Mpqf.neg z else z) b in
      let b = Vector.set_nth b (Environment.dim_of_var env var) Mpqf.one in
      match Matrix.rref_vec x b with
      | None -> bot ()
      | some_matrix -> {d = some_matrix; env = env}
    in
    (* let assign_uninvertible_rel x var b env = timing_wrap "assign_uninvertible" (assign_uninvertible_rel x var b) env in *)
    let is_invertible v = Vector.nth v @@ Environment.dim_of_var t.env var <>: Mpqf.zero
    in let affineEq_vec = get_coeff_vec t texp in
    if is_bot t then t else let m = Option.get t.d in
      match affineEq_vec with
      | Some v when is_top_env t ->
        if is_invertible v then t else assign_uninvertible_rel m var v t.env
      | Some v ->
        if is_invertible v then let t' = assign_invertible_rels m var v t.env in {d = t'.d; env = t'.env}
        else let new_m = Matrix.remove_zero_rows @@ remove_rels_with_var m var t.env
          in assign_uninvertible_rel new_m var v t.env
      | None -> {d = Some (Matrix.remove_zero_rows @@ remove_rels_with_var m var t.env); env = t.env}

  let assign_texpr t var texp = timing_wrap "assign_texpr" (assign_texpr t var) texp

  let assign_exp ask (t: VarManagement(Vc)(Mx).t) var exp (no_ov: bool Lazy.t) =
    let t = if not @@ Environment.mem_var t.env var then add_vars t [var] else t in
    (* TODO: Do we need to do a constant folding here? It happens for texpr1_of_cil_exp *)
    match Convert.texpr1_expr_of_cil_exp ask t t.env exp no_ov with
    | exp -> assign_texpr t var exp
    | exception Convert.Unsupported_CilExp _ ->
      if is_bot t then t else forget_vars t [var]

  let assign_exp ask t var exp no_ov =
    let res = assign_exp ask t var exp no_ov in
    if M.tracing then M.tracel "ops" "assign_exp t:\n %s \n var: %a \n exp: %a\n no_ov: %b -> \n %s"
        (show t) Var.pretty var d_exp exp (Lazy.force no_ov) (show res);
    res

  let assign_var (t: VarManagement(Vc)(Mx).t) v v' =
    let t = add_vars t [v; v'] in
    let texpr1 = Texpr1.of_expr (t.env) (Var v') in
    assign_texpr t v (Apron.Texpr1.to_expr texpr1)

  let assign_var t v v' =
    let res = assign_var t v v' in
    if M.tracing then M.tracel "ops" "assign_var t:\n %s \n v: %a \n v': %a\n -> %s" (show t) Var.pretty v Var.pretty v' (show res);
    res

  let assign_var_parallel t vv's =                                (* vv's is a list of pairs of lhs-variables and their rhs-values *)
    let assigned_vars = List.map fst vv's in
    let t = add_vars t assigned_vars in                           (* introduce all lhs-variables to the relation data structure *)
    let primed_vars = List.init                                   (* create a list with primed variables "i'" for each lhs-variable *)
        (List.length assigned_vars)
        (fun i -> Var.of_string (Int.to_string i  ^"'"))
    in (* TODO: we use primed integers as var names, conflict? *)
    let t_primed = add_vars t primed_vars in                      (* introduce primed variables to the relation data structure *)
    (* sequence of assignments: i' = snd vv_i : *)
    let multi_t = List.fold_left2 (fun t' v_prime (_,v') -> assign_var t' v_prime v') t_primed primed_vars vv's in
    match multi_t.d with
    | Some m when not @@ is_top_env multi_t ->                    (* SUBSTITUTE assigned_vars/primed_vars via OVERWRITE & ERASE *)
      let replace_col m x y =                                     (* OVERWRITES column for var_y with column for var_x *)
        let dim_x, dim_y = Environment.dim_of_var multi_t.env x, Environment.dim_of_var multi_t.env y in
        let col_x = Matrix.get_col_upper_triangular m dim_x in
        Matrix.set_col m col_x dim_y
      in
      let erase_cols m old_env to_erase =                         (* ERASES (i.e. entries are removed and column collapsed) from m all to_erase-columns *)
        let new_env = Environment.remove_vars old_env to_erase in
        let dimchange = Environment.dimchange2 old_env new_env in
        if Environment.equal old_env new_env then
          {d = Some m; env = new_env}
        else
          { d = Some (Matrix.remove_zero_rows @@ Matrix.del_cols m (BatOption.get dimchange.remove).dim); env = new_env}
      in
      let switched_m = List.fold_left2 replace_col m primed_vars assigned_vars in (* OVERWRITE columns for assigned_vars with column for primed_vars *)
      let res = erase_cols switched_m multi_t.env primed_vars in                  (* ERASE column for primed_vars *)
      let x = Option.get res.d in
      (match Matrix.normalize x with
       | None -> bot ()
       | some_matrix -> {d = some_matrix; env = res.env})
    | _ -> t

  let assign_var_parallel t vv's =
    let res = assign_var_parallel t vv's in
    if M.tracing then M.tracel "ops" "assign_var parallel: %s -> %s " (show t) (show res);
    res

  let assign_var_parallel t vv's = timing_wrap "var_parallel" (assign_var_parallel t) vv's

  let assign_var_parallel_with t vv's =
    let t' = assign_var_parallel t vv's in
    t.d <- t'.d;
    t.env <- t'.env

  let assign_var_parallel_with t vv's =
    if M.tracing then M.tracel "var_parallel" "assign_var parallel'";
    assign_var_parallel_with t vv's

  let assign_var_parallel' t vs1 vs2 =
    let vv's = List.combine vs1 vs2 in
    assign_var_parallel t vv's

  let assign_var_parallel' t vv's =
    let res = assign_var_parallel' t vv's in
    if M.tracing then M.tracel "ops" "assign_var parallel'";
    res

  let substitute_exp ask t var exp no_ov =
    let t = if not @@ Environment.mem_var t.env var then add_vars t [var] else t in
    let res = assign_exp ask t var exp no_ov in
    forget_vars res [var]

  let substitute_exp ask t var exp no_ov =
    let res = substitute_exp ask t var exp no_ov in
    if M.tracing then M.tracel "ops" "Substitute_expr t: \n %s \n var: %a \n exp: %a \n -> \n %s" (show t) Var.pretty var d_exp exp (show res);
    res

  let substitute_exp ask t var exp no_ov = timing_wrap "substitution" (substitute_exp ask t var exp) no_ov

  (** Assert a constraint expression.

      The overflow is completely handled by the flag "no_ov",
      which is set in relationAnalysis.ml via the function no_overflow.
      In case of a potential overflow, "no_ov" is set to false
      and Convert.tcons1_of_cil_exp will raise the exception Unsupported_CilExp Overflow *)

  let meet_tcons ask t tcons expr =
    let check_const cmp c = if cmp c Mpqf.zero then bot_env else t in
    let meet_vec e =
      (* Flip the sign of the const. val in coeff vec *)
      let coeff = Vector.nth e (Vector.length e - 1) in
      let e = Vector.set_nth e (Vector.length e - 1) (Mpqf.neg coeff) in
      if is_bot t then
        bot ()
      else
        match Matrix.rref_vec (Option.get t.d) e with
        | None -> bot ()
        | some_matrix -> {d = some_matrix; env = t.env}
    in
    match get_coeff_vec t (Texpr1.to_expr @@ Tcons1.get_texpr1 tcons) with
    | Some v ->
      begin match to_constant_opt v, Tcons1.get_typ tcons with
        | Some c, DISEQ -> check_const (=:) c
        | Some c, SUP -> check_const (<=:) c
        | Some c, EQ -> check_const (<>:) c
        | Some c, SUPEQ -> check_const (<:) c
        | None, DISEQ
        | None, SUP ->
          if equal (meet_vec v) t then
            bot_env
          else
            t
        | None, EQ ->
          let res = meet_vec v in
          if is_bot res then
            bot_env
          else
            res
        | _ -> t
      end
    | None -> t

  let meet_tcons t tcons expr = timing_wrap "meet_tcons" (meet_tcons t tcons) expr

  let unify a b =
    meet a b

  let unify a b =
    let res = unify a b  in
    if M.tracing then M.tracel "ops" "unify: %s %s -> %s" (show a) (show b) (show res);
    res

  let assert_constraint ask d e negate no_ov =
    if M.tracing then M.tracel "assert_constraint" "assert_constraint with expr: %a %b" d_exp e (Lazy.force no_ov);
    match Convert.tcons1_of_cil_exp ask d d.env e negate no_ov with
    | tcons1 -> meet_tcons ask d tcons1 e
    | exception Convert.Unsupported_CilExp _ -> d

  let assert_constraint ask d e negate no_ov = timing_wrap "assert_constraint" (assert_constraint ask d e negate) no_ov

  let relift t = t

  let invariant t =
    let invariant m =
      let one_constraint i =
        let row = Matrix.get_row m i in
        let coeff_vars = List.map (fun x ->  Coeff.s_of_mpqf @@ Vector.nth row (Environment.dim_of_var t.env x), x) (vars t) in
        let cst = Coeff.s_of_mpqf @@ Vector.nth row (Vector.length row - 1) in
        let e1 = Linexpr1.make t.env in
        Linexpr1.set_list e1 coeff_vars (Some cst);
        Lincons1.make e1 EQ
      in
      List.init (Matrix.num_rows m) one_constraint
    in
    BatOption.map_default invariant [] t.d

  let cil_exp_of_lincons1 = Convert.cil_exp_of_lincons1

  let env t = t.env

  type marshal = t

  let marshal t = t

  let unmarshal t = t
end

module D2(Vc: SparseVectorFunctor) (Mx: SparseMatrixFunctor): RelationDomain.RD with type var = Var.t =
struct
  module D =  D (Vc) (Mx)
  module ConvArg = struct
    let allow_global = false
  end
  include SharedFunctions.AssertionModule (D.V) (D) (ConvArg)
  include D
end

(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)
open Core_kernel
open Typing_defs

module Reason = Typing_reason
module Type   = Typing_ops
module Env    = Typing_env
module TUtils = Typing_utils
module SN     = Naming_special_names

let rec can_be_null env ty =
  let _, (_, ety) = Env.expand_type env ty in
  match ety with
  | Toption _ | Tprim Nast.Tvoid -> true
  | Tunresolved tyl -> List.exists tyl (can_be_null env)
  | Terr | Tany | Tmixed | Tnonnull | Tarraykind _ | Tprim _ | Tvar _
    | Tfun _ | Tabstract (_, _) | Tclass (_, _) | Ttuple _
    | Tanon (_, _) | Tobject | Tshape _ | Tdynamic -> false

let rec enforce_not_awaitable env p ty =
  let _, ety = Env.expand_type env ty in
  match ety with
  | _, Tunresolved tyl ->
    List.iter tyl (enforce_not_awaitable env p)
  | r, Tclass ((_, awaitable), _) when
      awaitable = SN.Classes.cAwaitable ->
    Errors.discarded_awaitable p (Reason.to_pos r)
  | _, (Terr | Tany | Tmixed | Tnonnull | Tarraykind _ | Tprim _ | Toption _
    | Tvar _ | Tfun _ | Tabstract (_, _) | Tclass (_, _) | Ttuple _
    | Tanon (_, _) | Tobject | Tshape _ | Tdynamic) -> ()

let enforce_nullable_or_not_awaitable env p ty =
  if can_be_null env ty then ()
  else enforce_not_awaitable env p ty

(* We would like to pretend that the wait_for*() functions are overloaded like
 * function wait_for<T>(Awaitable<T> $a): _AsyncWaitHandle<T>
 * function wait_for<T>(?Awaitable<T> $a): _AsyncWaitHandle<?T>
 * function wait_forv<T>(array<Awaitable<T>> $a): _AsyncWaitHandle<array<T>>
 * function wait_forv<T>(array<?Awaitable<T>> $a): _AsyncWaitHandle<array<?T>>
 *
 * Basically we check if the argument to wait_for*() looks option-y and decide
 * the expected types based on that.
 *)
let rec overload_extract_from_awaitable env p opt_ty_maybe =
  let type_var = Env.fresh_type() in
  let r = Reason.Rwitness p in
  let env, e_opt_ty = Env.expand_type env opt_ty_maybe in
  (match e_opt_ty with
  | _, Tunresolved tyl ->
    (* If we cannot fold the intersection into a single type, we need to look at
     * all the types *)
    let env, rtyl = List.fold_right ~f:begin fun ty (env, rtyl) ->
      let env, rty = overload_extract_from_awaitable env p ty in
      (* We have the invariant we'll never have Tunresolved[Tunresolved], but
       * the recursive call above can remove a layer of Awaitable, so we need
       * to flatten any Tunresolved that may have been inside. *)
      TUtils.flatten_unresolved env rty rtyl
    end tyl ~init:(env, []) in
    env, (r, Tunresolved rtyl)
  | _, Toption ty ->
    (* We want to try to avoid easy double nullables here, so we handle Toption
     * with some special logic. *)
    let env, ty = overload_extract_from_awaitable env p ty in
    let env, ty = TUtils.non_null env ty in
    env, (r, Toption ty)
  | r, Tprim Nast.Tvoid ->
    env, (r, Tprim Nast.Tvoid)
  | _, Tdynamic -> (* Awaiting a dynamic results in a new dynamic *)
    env, (r, Tdynamic)
  | _, (Terr | Tany | Tmixed | Tarraykind _ | Tnonnull | Tprim _
    | Tvar _ | Tfun _ | Tabstract (_, _) | Tclass (_, _) | Ttuple _
    | Tanon (_, _) | Tobject | Tshape _ ) ->
    let expected_type = r, Tclass ((p, SN.Classes.cAwaitable), [type_var]) in
    let return_type = match e_opt_ty with
      | _, Tany -> r, Tany
      | _, Terr -> r, Terr
      | _, Tdynamic -> r, Tdynamic
      | _, (Tmixed | Tnonnull | Tarraykind _ | Tprim _ | Tvar _ | Tfun _
        | Tabstract (_, _) | Tclass (_, _) | Ttuple _ | Tanon (_, _)
        | Toption _ | Tunresolved _ | Tobject | Tshape _) -> type_var
    in

    let env = Type.sub_type p Reason.URawait env opt_ty_maybe expected_type in
    env, return_type
  )

let overload_extract_from_awaitable_list env p tyl =
  List.fold_right ~f:begin fun ty (env, rtyl) ->
    let env, rty =  overload_extract_from_awaitable env p ty in
    env, rty::rtyl
  end tyl ~init:(env, [])

let overload_extract_from_awaitable_shape env p fdm =
  Nast.ShapeMap.map_env begin fun env _key (tk, tv) ->
    let env, rtv = overload_extract_from_awaitable env p tv in
    env, (tk, rtv)
  end env fdm

let overload_extract_from_awaitable_aktuple env p fields =
  IMap.map_env begin fun env _key ty ->
    let env, rty = overload_extract_from_awaitable env p ty in
    env, rty
  end env fields

let gena env p ty =
  match snd (TUtils.fold_unresolved env ty) with
  | _, Tarraykind (AKany | AKempty) ->
    env, ty
  | r, Tarraykind (AKvec ty1) ->
    let env, ty1 = overload_extract_from_awaitable env p ty1 in
    env, (r, Tarraykind (AKvec ty1))
  | r, Tarraykind (AKvarray ty1) ->
    let env, ty1 = overload_extract_from_awaitable env p ty1 in
    env, (r, Tarraykind (AKvarray ty1))
  | r, Tarraykind (AKvarray_or_darray ty1) ->
    let env, ty1 = overload_extract_from_awaitable env p ty1 in
    env, (r, Tarraykind (AKvarray_or_darray ty1))
  | r, Tarraykind AKmap (ty1, ty2) ->
    let env, ty2 = overload_extract_from_awaitable env p ty2 in
    env, (r, Tarraykind (AKmap (ty1, ty2)))
  | r, Tarraykind AKdarray (ty1, ty2) ->
    let env, ty2 = overload_extract_from_awaitable env p ty2 in
    env, (r, Tarraykind (AKdarray (ty1, ty2)))
  | r, Tarraykind AKshape fdm ->
    let env, fdm = overload_extract_from_awaitable_shape env p fdm in
    env, (r, Tarraykind (AKshape fdm))
  | r, Tarraykind AKtuple fields ->
    let env, fields = overload_extract_from_awaitable_aktuple env p fields in
    env, (r, Tarraykind (AKtuple fields))
  | r, Ttuple tyl ->
    let env, tyl =
      overload_extract_from_awaitable_list env p tyl in
    env, (r, Ttuple tyl)
  | r, ty ->
    (* Oh well...let's at least make sure it is array-ish *)
    let expected_ty = r, Tarraykind AKany in
    let env =
      Errors.try_
        (fun () -> Type.sub_type p Reason.URawait env (r, ty) expected_ty)
        (fun _ ->
          let ty_str = Typing_print.error ty in
          Errors.gena_expects_array p (Reason.to_pos r) ty_str;
          env
        )
    in
    env, expected_ty

let genva env p tyl =
  let env, rtyl =
    overload_extract_from_awaitable_list env p tyl in
  let inner_type = (Reason.Rwitness p, Ttuple rtyl) in
  env, inner_type

let rec gen_array_rec env p ty =
  let rec is_array env ty = begin
    let env, ety = Env.expand_type env ty in
    match snd (TUtils.fold_unresolved env ety) with
      | _, Ttuple _
      | _, Tarraykind _ -> gen_array_rec env p ety
      | r, Tunresolved tyl -> begin
        (* You can run gen_array_rec on heterogeneous arrays, like this one:
         * array(
         *   'foo' => cached_result(1),
         *   'bar' => array(
         *     'baz' => cached_result(2),
         *   ),
         * )
         *
         * In this case the value type in the array will be unresolved; we need
         * to check all the types in the unresolved. *)
        let env, rtyl = List.fold_right ~f:begin fun ty (env, rtyl) ->
          let env, ty = is_array env ty in
          env, ty::rtyl
        end tyl ~init:(env, []) in
        env, (r, Tunresolved rtyl)
      end
      | _, (Terr | Tany | Tmixed | Tnonnull | Tprim _ | Toption _ | Tvar _
        | Tfun _ | Tabstract (_, _) | Tclass (_, _) | Tanon (_, _) | Tobject
        | Tshape _ | Tdynamic
           ) -> overload_extract_from_awaitable env p ety
  end in
  match snd (TUtils.fold_unresolved env ty) with
  | r, Tarraykind (AKvec vty) ->
    let env, vty = is_array env vty in
    env, (r, Tarraykind (AKvec vty))
  | r, Tarraykind (AKvarray vty) ->
    let env, vty = is_array env vty in
    env, (r, Tarraykind (AKvarray vty))
  | r, Tarraykind (AKvarray_or_darray vty) ->
    let env, vty = is_array env vty in
    env, (r, Tarraykind (AKvarray_or_darray vty))
  | r, Tarraykind (AKmap (kty, vty)) ->
    let env, vty = is_array env vty in
    env, (r, Tarraykind (AKmap( kty, vty)))
  | r, Tarraykind (AKdarray (kty, vty)) ->
    let env, vty = is_array env vty in
    env, (r, Tarraykind (AKdarray(kty, vty)))
  | r, Tarraykind (AKshape fdm) ->
    let env, fdm = Nast.ShapeMap.map_env begin fun env _key (tk, tv) ->
      let env, tv = is_array env tv in
      env, (tk, tv)
    end env fdm in
    env, (r, Tarraykind (AKshape fdm))
  | r, Tarraykind (AKtuple fields) ->
    let env, fields = IMap.map_env begin fun env _key ty ->
      let env, ty = is_array env ty in
      env, ty
    end env fields in
    env, (r, Tarraykind (AKtuple fields))
  | _, Ttuple tyl -> gen_array_va_rec env p tyl
  | _, (Terr | Tany | Tmixed | Tnonnull | Tarraykind _ | Tprim _ | Toption _
    | Tvar _ | Tfun _ | Tabstract (_, _) | Tclass (_, _) | Tdynamic
    | Tanon (_, _) | Tunresolved _ | Tobject | Tshape _
       ) -> gena env p ty

and gen_array_va_rec env p tyl =
  (* For each item in the type list, treat it differently *)
  let rec gen_array_va_rec' env ty =
  (* Unwrap option types (hopefully we won't have option options *)
    (match snd (TUtils.fold_unresolved env ty) with
    | r, Toption opt_ty ->
      let env, opt_ty = gen_array_va_rec' env opt_ty in
      let env, opt_ty = TUtils.non_null env opt_ty in
      env, (r, Toption opt_ty)
    | _, Tarraykind _ -> gen_array_rec env p ty
    | _, Ttuple tyl -> genva env p tyl
    | _, (Terr | Tany | Tmixed | Tnonnull | Tprim _ | Tvar _ | Tfun _ | Tdynamic
      | Tabstract (_, _) | Tclass (_, _) | Tanon (_, _) | Tunresolved _
      | Tobject | Tshape _) ->
       overload_extract_from_awaitable env p ty) in

  let env, rtyl = List.fold_right ~f:begin fun ty (env, rtyl) ->
    let env, ty = gen_array_va_rec' env ty in
    env, ty::rtyl
  end tyl ~init:(env, []) in
  env, (Reason.Rwitness p, Ttuple rtyl)

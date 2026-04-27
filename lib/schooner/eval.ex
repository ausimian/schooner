defmodule Schooner.Eval do
  @moduledoc """
  Tail-recursive direct evaluator for the core Scheme language.

  ## Tail-call invariant

  Every branch of `eval/2`, `apply_proc/2`, and `eval_sequence/2`
  finishes with a direct tail call to one of those three. Nothing
  wraps these calls in a `try`, a tuple constructor, a `with`, or any
  expression that would knock them out of tail position. This is what
  makes Scheme's proper-tail-call requirement fall out of BEAM's
  last-call optimisation. **Adding a wrapper around any of these
  calls breaks the invariant — see `eval_tco_test.exs`.**

  Phase 4 recognises only the core forms: `quote`, `if`, `lambda`,
  top-level `define`, `begin`, application, and variable reference.
  Everything else is either self-evaluating or an error.
  """

  alias Schooner.Env
  alias Schooner.Eval.Error
  alias Schooner.Value

  @spec eval(Value.t(), Env.t()) :: Value.t()

  def eval({:sym, name}, env) do
    case Env.lookup(env, name) do
      {:ok, value} -> value
      :error -> raise Error, reason: {:unbound, name}
    end
  end

  def eval(:null, _env), do: raise(Error, reason: :empty_application)

  def eval({:pair, {:sym, "quote"}, tail}, _env), do: eval_quote(tail)
  def eval({:pair, {:sym, "if"}, tail}, env), do: eval_if(tail, env)
  def eval({:pair, {:sym, "lambda"}, tail}, env), do: eval_lambda(tail, env)
  def eval({:pair, {:sym, "define"}, tail}, env), do: eval_define(tail, env)
  def eval({:pair, {:sym, "begin"}, tail}, env), do: eval_sequence(tail, env)
  def eval({:pair, {:sym, "and"}, tail}, env), do: eval_and(tail, env)
  def eval({:pair, {:sym, "or"}, tail}, env), do: eval_or(tail, env)
  def eval({:pair, {:sym, "when"}, tail}, env), do: eval_when(tail, env)
  def eval({:pair, {:sym, "unless"}, tail}, env), do: eval_unless(tail, env)
  def eval({:pair, {:sym, "cond"}, tail}, env), do: eval_cond(tail, env)
  def eval({:pair, {:sym, "case"}, tail}, env), do: eval_case(tail, env)
  def eval({:pair, {:sym, "let"}, tail}, env), do: eval_let(tail, env)
  def eval({:pair, {:sym, "let*"}, tail}, env), do: eval_let_star(tail, env)
  def eval({:pair, {:sym, "letrec"}, tail}, env), do: eval_letrec_star(tail, env)
  def eval({:pair, {:sym, "letrec*"}, tail}, env), do: eval_letrec_star(tail, env)
  def eval({:pair, {:sym, "do"}, tail}, env), do: eval_do(tail, env)
  def eval({:pair, {:sym, "quasiquote"}, tail}, env), do: eval_quasiquote_top(tail, env)
  def eval({:pair, head, tail}, env), do: eval_apply(head, tail, env)

  def eval(value, _env), do: value

  # ---------------------------------------------------------------------------
  # quote
  # ---------------------------------------------------------------------------

  defp eval_quote({:pair, datum, :null}), do: datum
  defp eval_quote(_), do: raise(Error, reason: {:bad_special_form, "quote"})

  # ---------------------------------------------------------------------------
  # if
  # ---------------------------------------------------------------------------

  defp eval_if({:pair, test, {:pair, then_e, :null}}, env) do
    if Value.truthy?(eval(test, env)) do
      eval(then_e, env)
    else
      :unspecified
    end
  end

  defp eval_if({:pair, test, {:pair, then_e, {:pair, else_e, :null}}}, env) do
    if Value.truthy?(eval(test, env)) do
      eval(then_e, env)
    else
      eval(else_e, env)
    end
  end

  defp eval_if(_, _env), do: raise(Error, reason: {:bad_special_form, "if"})

  # ---------------------------------------------------------------------------
  # lambda
  # ---------------------------------------------------------------------------

  defp eval_lambda({:pair, _params_form, :null}, _env) do
    raise(Error, reason: {:bad_special_form, "lambda"})
  end

  defp eval_lambda({:pair, params_form, body}, env) do
    Value.closure(parse_params(params_form), body, env, nil)
  end

  defp eval_lambda(_, _env), do: raise(Error, reason: {:bad_special_form, "lambda"})

  defp parse_params({:sym, name}), do: {:any, name}
  defp parse_params(:null), do: {:fixed, 0, []}
  defp parse_params({:pair, _, _} = list), do: collect_params(list, [], 0)
  defp parse_params(_), do: raise(Error, reason: :invalid_params)

  defp collect_params(:null, acc, n), do: {:fixed, n, Enum.reverse(acc)}

  defp collect_params({:sym, rest_name}, acc, n) do
    {:fixed_rest, n, Enum.reverse(acc), rest_name}
  end

  defp collect_params({:pair, {:sym, name}, t}, acc, n) do
    collect_params(t, [name | acc], n + 1)
  end

  defp collect_params(_, _, _), do: raise(Error, reason: :invalid_params)

  # ---------------------------------------------------------------------------
  # define — top-level only at MVP; not enforced syntactically yet
  # ---------------------------------------------------------------------------

  defp eval_define({:pair, {:sym, name}, {:pair, expr, :null}}, env) do
    Env.define(env, name, eval(expr, env))
    :unspecified
  end

  defp eval_define({:pair, {:pair, {:sym, _name}, _params}, :null}, _env) do
    raise(Error, reason: {:bad_special_form, "define"})
  end

  defp eval_define({:pair, {:pair, {:sym, name}, params_form}, body}, env) do
    closure = Value.closure(parse_params(params_form), body, env, name)
    Env.define(env, name, closure)
    :unspecified
  end

  defp eval_define(_, _env), do: raise(Error, reason: {:bad_special_form, "define"})

  # ---------------------------------------------------------------------------
  # sequence — body of begin / lambda / define-fn
  # ---------------------------------------------------------------------------

  defp eval_sequence({:pair, last, :null}, env), do: eval(last, env)

  defp eval_sequence({:pair, head, rest}, env) do
    _ = eval(head, env)
    eval_sequence(rest, env)
  end

  defp eval_sequence(:null, _env), do: :unspecified

  # ---------------------------------------------------------------------------
  # application
  # ---------------------------------------------------------------------------

  defp eval_apply(head_expr, args_form, env) do
    proc = eval(head_expr, env)
    args = eval_args(args_form, env, [])
    apply_proc(proc, args)
  end

  defp eval_args(:null, _env, acc), do: Enum.reverse(acc)
  defp eval_args({:pair, h, t}, env, acc), do: eval_args(t, env, [eval(h, env) | acc])
  defp eval_args(_, _env, _acc), do: raise(Error, reason: :improper_application)

  @spec apply_proc(Value.t(), [Value.t()]) :: Value.t()
  def apply_proc({:closure, params, body, env, name}, args) do
    new_env = Env.extend(env, bind_params(params, args, name))
    eval_sequence(body, new_env)
  end

  def apply_proc({:primitive, name, arity, fun}, args) do
    check_primitive_arity!(arity, args, name)
    fun.(args)
  end

  def apply_proc(other, _args), do: raise(Error, reason: {:not_a_procedure, other})

  defp bind_params({:fixed, n, names}, args, fname) do
    case length(args) do
      ^n -> Enum.zip(names, args)
      got -> raise(Error, reason: {:arity_mismatch, fname, {:exact, n}, got})
    end
  end

  defp bind_params({:any, name}, args, _fname), do: [{name, Value.list(args)}]

  defp bind_params({:fixed_rest, n, names, rest_name}, args, fname) do
    case length(args) do
      got when got >= n ->
        {head, tail} = Enum.split(args, n)
        Enum.zip(names, head) ++ [{rest_name, Value.list(tail)}]

      got ->
        raise(Error, reason: {:arity_mismatch, fname, {:at_least, n}, got})
    end
  end

  defp check_primitive_arity!(n, args, name) when is_integer(n) do
    got = length(args)

    if got != n do
      raise(Error, reason: {:arity_mismatch, name, {:exact, n}, got})
    end
  end

  defp check_primitive_arity!({:at_least, n}, args, name) do
    got = length(args)

    if got < n do
      raise(Error, reason: {:arity_mismatch, name, {:at_least, n}, got})
    end
  end

  # ---------------------------------------------------------------------------
  # and / or — short-circuit, return the deciding value (r7rs §4.2.1).
  # `(and)` => #t, `(or)` => #f. Last form is in tail position.
  # ---------------------------------------------------------------------------

  defp eval_and(:null, _env), do: Value.bool(true)
  defp eval_and({:pair, last, :null}, env), do: eval(last, env)

  defp eval_and({:pair, head, rest}, env) do
    case eval(head, env) do
      {:bool, false} = v -> v
      _ -> eval_and(rest, env)
    end
  end

  defp eval_and(_, _env), do: raise(Error, reason: {:bad_special_form, "and"})

  defp eval_or(:null, _env), do: Value.bool(false)
  defp eval_or({:pair, last, :null}, env), do: eval(last, env)

  defp eval_or({:pair, head, rest}, env) do
    case eval(head, env) do
      {:bool, false} -> eval_or(rest, env)
      v -> v
    end
  end

  defp eval_or(_, _env), do: raise(Error, reason: {:bad_special_form, "or"})

  # ---------------------------------------------------------------------------
  # when / unless
  # ---------------------------------------------------------------------------

  defp eval_when({:pair, test, body}, env) when body != :null do
    if Value.truthy?(eval(test, env)) do
      eval_sequence(body, env)
    else
      :unspecified
    end
  end

  defp eval_when(_, _env), do: raise(Error, reason: {:bad_special_form, "when"})

  defp eval_unless({:pair, test, body}, env) when body != :null do
    if Value.truthy?(eval(test, env)) do
      :unspecified
    else
      eval_sequence(body, env)
    end
  end

  defp eval_unless(_, _env), do: raise(Error, reason: {:bad_special_form, "unless"})

  # ---------------------------------------------------------------------------
  # cond — supports (test), (test expr ...), (test => proc), (else expr ...).
  # ---------------------------------------------------------------------------

  defp eval_cond(:null, _env), do: :unspecified

  defp eval_cond({:pair, {:pair, {:sym, "else"}, body}, _rest}, env) when body != :null do
    eval_sequence(body, env)
  end

  defp eval_cond({:pair, {:pair, {:sym, "else"}, _}, _}, _env) do
    raise(Error, reason: {:bad_special_form, "cond"})
  end

  defp eval_cond({:pair, {:pair, test, {:pair, {:sym, "=>"}, {:pair, recv, :null}}}, rest}, env) do
    value = eval(test, env)

    if Value.truthy?(value) do
      proc = eval(recv, env)
      apply_proc(proc, [value])
    else
      eval_cond(rest, env)
    end
  end

  defp eval_cond({:pair, {:pair, test, :null}, rest}, env) do
    case eval(test, env) do
      {:bool, false} -> eval_cond(rest, env)
      v -> v
    end
  end

  defp eval_cond({:pair, {:pair, test, body}, rest}, env) do
    if Value.truthy?(eval(test, env)) do
      eval_sequence(body, env)
    else
      eval_cond(rest, env)
    end
  end

  defp eval_cond(_, _env), do: raise(Error, reason: {:bad_special_form, "cond"})

  # ---------------------------------------------------------------------------
  # case — keys matched with `eqv?`. `(else expr ...)` and `(keys => proc)`
  # supported. Empty key list never matches (it falls through).
  # ---------------------------------------------------------------------------

  defp eval_case({:pair, key_expr, clauses}, env) do
    eval_case_clauses(eval(key_expr, env), clauses, env)
  end

  defp eval_case(_, _env), do: raise(Error, reason: {:bad_special_form, "case"})

  defp eval_case_clauses(_key, :null, _env), do: :unspecified

  defp eval_case_clauses(key, {:pair, {:pair, {:sym, "else"}, body}, _rest}, env)
       when body != :null do
    case body do
      {:pair, {:sym, "=>"}, {:pair, recv, :null}} ->
        apply_proc(eval(recv, env), [key])

      _ ->
        eval_sequence(body, env)
    end
  end

  defp eval_case_clauses(key, {:pair, {:pair, keys, body}, rest}, env) do
    if case_match?(key, keys) do
      case body do
        {:pair, {:sym, "=>"}, {:pair, recv, :null}} ->
          apply_proc(eval(recv, env), [key])

        :null ->
          raise(Error, reason: {:bad_special_form, "case"})

        _ ->
          eval_sequence(body, env)
      end
    else
      eval_case_clauses(key, rest, env)
    end
  end

  defp eval_case_clauses(_key, _, _env), do: raise(Error, reason: {:bad_special_form, "case"})

  defp case_match?(_key, :null), do: false

  defp case_match?(key, {:pair, datum, rest}) do
    Value.eqv?(key, datum) or case_match?(key, rest)
  end

  defp case_match?(_key, _), do: raise(Error, reason: {:bad_special_form, "case"})

  # ---------------------------------------------------------------------------
  # let — including the named-let recursion form.
  # ---------------------------------------------------------------------------

  defp eval_let({:pair, {:sym, name}, {:pair, bindings_form, body}}, env)
       when body != :null do
    eval_named_let(name, bindings_form, body, env)
  end

  defp eval_let({:pair, bindings_form, body}, env) when body != :null do
    {names, inits} = parse_bindings(bindings_form, "let")
    values = Enum.map(inits, &eval(&1, env))
    eval_sequence(body, Env.extend(env, Enum.zip(names, values)))
  end

  defp eval_let(_, _env), do: raise(Error, reason: {:bad_special_form, "let"})

  defp eval_named_let(name, bindings_form, body, env) do
    {param_names, inits} = parse_bindings(bindings_form, "let")
    values = Enum.map(inits, &eval(&1, env))

    rec_env = Env.extend_rec(env, [name])
    closure = Value.closure({:fixed, length(param_names), param_names}, body, rec_env, name)
    Env.rec_set(rec_env, name, closure)

    apply_proc(closure, values)
  end

  defp eval_let_star({:pair, bindings_form, body}, env) when body != :null do
    {names, inits} = parse_bindings(bindings_form, "let*")

    new_env =
      names
      |> Enum.zip(inits)
      |> Enum.reduce(env, fn {name, init}, e ->
        Env.extend(e, [{name, eval(init, e)}])
      end)

    eval_sequence(body, new_env)
  end

  defp eval_let_star(_, _env), do: raise(Error, reason: {:bad_special_form, "let*"})

  # `letrec` and `letrec*` share an implementation. r7rs allows
  # `letrec` to be implemented as `letrec*`; the only difference is the
  # spec leaves init evaluation order unspecified for `letrec`.
  defp eval_letrec_star({:pair, bindings_form, body}, env) when body != :null do
    {names, inits} = parse_bindings(bindings_form, "letrec*")
    rec_env = Env.extend_rec(env, names)

    names
    |> Enum.zip(inits)
    |> Enum.each(fn {name, init} ->
      Env.rec_set(rec_env, name, eval(init, rec_env))
    end)

    eval_sequence(body, rec_env)
  end

  defp eval_letrec_star(_, _env), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  defp parse_bindings(form, ctx), do: parse_bindings(form, ctx, [], [])

  defp parse_bindings(:null, _ctx, names, inits) do
    {Enum.reverse(names), Enum.reverse(inits)}
  end

  defp parse_bindings({:pair, {:pair, {:sym, name}, {:pair, init, :null}}, rest}, ctx, ns, is) do
    parse_bindings(rest, ctx, [name | ns], [init | is])
  end

  defp parse_bindings(_, ctx, _, _), do: raise(Error, reason: {:bad_special_form, ctx})

  # ---------------------------------------------------------------------------
  # do — iteration with stepped variables and a termination test.
  # ---------------------------------------------------------------------------

  defp eval_do({:pair, bindings_form, {:pair, test_form, body}}, env) do
    {names, inits, steps} = parse_do_bindings(bindings_form)
    {test, results} = parse_do_test(test_form)

    init_values = Enum.map(inits, &eval(&1, env))
    loop_env = Env.extend(env, Enum.zip(names, init_values))
    do_loop(names, steps, test, results, body, loop_env)
  end

  defp eval_do(_, _env), do: raise(Error, reason: {:bad_special_form, "do"})

  defp do_loop(names, steps, test, results, body, env) do
    if Value.truthy?(eval(test, env)) do
      eval_sequence(results, env)
    else
      _ = eval_sequence(body, env)
      step_values = Enum.map(steps, &eval(&1, env))
      next_env = Env.extend(pop_lex(env), Enum.zip(names, step_values))
      do_loop(names, steps, test, results, body, next_env)
    end
  end

  defp pop_lex(%Env{lex: [_top | rest]} = env), do: %{env | lex: rest}

  defp parse_do_bindings(:null), do: {[], [], []}

  defp parse_do_bindings({:pair, {:pair, {:sym, name}, {:pair, init, rest_step}}, rest}) do
    {ns, is, ss} = parse_do_bindings(rest)
    step = parse_do_step(name, rest_step)
    {[name | ns], [init | is], [step | ss]}
  end

  defp parse_do_bindings(_), do: raise(Error, reason: {:bad_special_form, "do"})

  defp parse_do_step(name, :null), do: Value.symbol(name)
  defp parse_do_step(_name, {:pair, step, :null}), do: step
  defp parse_do_step(_name, _), do: raise(Error, reason: {:bad_special_form, "do"})

  defp parse_do_test({:pair, test, results}), do: {test, results}
  defp parse_do_test(_), do: raise(Error, reason: {:bad_special_form, "do"})

  # ---------------------------------------------------------------------------
  # quasiquote — recursive expansion with nested-level tracking.
  # `unquote` and `unquote-splicing` only fire at level 1; nested
  # quasiquotes raise the level, nested unquotes lower it.
  # ---------------------------------------------------------------------------

  defp eval_quasiquote_top({:pair, datum, :null}, env) do
    quasi(datum, env, 1)
  end

  defp eval_quasiquote_top(_, _env), do: raise(Error, reason: {:bad_special_form, "quasiquote"})

  defp quasi({:pair, {:sym, "unquote"}, {:pair, expr, :null}}, env, 1), do: eval(expr, env)

  defp quasi({:pair, {:sym, "unquote"}, {:pair, expr, :null}}, env, n) when n > 1 do
    Value.list([Value.symbol("unquote"), quasi(expr, env, n - 1)])
  end

  defp quasi({:pair, {:sym, "quasiquote"}, {:pair, expr, :null}}, env, n) do
    Value.list([Value.symbol("quasiquote"), quasi(expr, env, n + 1)])
  end

  defp quasi({:pair, head, tail}, env, level) do
    case head do
      {:pair, {:sym, "unquote-splicing"}, {:pair, expr, :null}} when level == 1 ->
        spliced = eval(expr, env)
        rest = quasi(tail, env, level)
        splice_append(spliced, rest, "unquote-splicing")

      _ ->
        {:pair, quasi(head, env, level), quasi(tail, env, level)}
    end
  end

  defp quasi({:vector, t}, env, level) do
    list = Value.list(Tuple.to_list(t))

    case quasi(list, env, level) do
      {:pair, _, _} = pair -> {:vector, List.to_tuple(scheme_list_to_elixir(pair))}
      :null -> {:vector, {}}
    end
  end

  defp quasi(other, _env, _level), do: other

  defp splice_append(:null, rest, _ctx), do: rest

  defp splice_append({:pair, h, t}, rest, ctx) do
    {:pair, h, splice_append(t, rest, ctx)}
  end

  defp splice_append(_, _, ctx), do: raise(Error, reason: {:bad_special_form, ctx})

  defp scheme_list_to_elixir(:null), do: []
  defp scheme_list_to_elixir({:pair, h, t}), do: [h | scheme_list_to_elixir(t)]
end

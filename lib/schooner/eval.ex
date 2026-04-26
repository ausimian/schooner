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

  def eval({:pair, head, tail}, env) do
    case head do
      {:sym, "quote"} -> eval_quote(tail)
      {:sym, "if"} -> eval_if(tail, env)
      {:sym, "lambda"} -> eval_lambda(tail, env)
      {:sym, "define"} -> eval_define(tail, env)
      {:sym, "begin"} -> eval_sequence(tail, env)
      _ -> eval_apply(head, tail, env)
    end
  end

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
end
